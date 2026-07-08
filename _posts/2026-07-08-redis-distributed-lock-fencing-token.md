---
title: "Redis 분산 락을 잡아도 fencing token 없이는 오래 걸린 작업이 값을 덮어쓸 수 있는 이유"
date: 2026-07-08 08:55:00 +0900
tags: [Redis, Distributed Systems, Backend]
excerpt: "Redis 분산 락은 동시에 같은 일을 하지 않게 도와주지만, TTL 만료 뒤 늦게 끝난 작업까지 막아주지는 않습니다. 중요한 쓰기에는 락 소유 여부보다 fencing token으로 순서를 검증해야 합니다."
---

## 문제 상황

배치 서버 두 대가 같은 정산 작업을 동시에 실행하지 않도록 Redis에 락을 걸었다고 해보자. 첫 번째 서버가 `SET settlement:2026-07-08 token-a NX PX 30000`으로 락을 잡고 정산을 시작한다. 평소에는 3초면 끝나지만, 그날은 외부 API 응답이 늦고 GC pause까지 겹쳐 40초가 걸렸다.

30초가 지나 락 TTL은 만료된다. 두 번째 서버는 같은 키에 새 락을 잡고 더 최신 데이터를 기준으로 정산 결과를 저장한다. 그런데 잠시 뒤 첫 번째 서버가 늦게 깨어나 자기 결과를 DB에 저장하면 어떻게 될까. Redis 락은 이미 사라졌지만 첫 번째 서버의 코드에는 여전히 "내가 락을 잡고 시작했다"는 기억이 남아 있다. 이때 오래된 작업이 최신 결과를 덮어쓰는 사고가 생길 수 있다.

그래서 Redis 락은 "동시에 시작하는 작업을 줄이는 장치"로는 유용하지만, "늦게 끝난 작업의 쓰기를 항상 막는 장치"로 이해하면 위험하다. 특히 결제, 정산, 재고 차감, 쿠폰 발급처럼 마지막 쓰기 순서가 중요한 작업에서는 락과 별도로 쓰기 순서를 검증해야 한다.

## 핵심 개념

Redis에서 단일 인스턴스 락을 구현할 때는 보통 `SET key value NX PX ttl` 형태를 쓴다. `NX`는 키가 없을 때만 설정한다는 뜻이고, `PX`는 밀리초 단위 TTL을 준다는 뜻이다. Redis 공식 문서도 락을 해제할 때 단순히 `DEL`을 쓰면 다른 클라이언트의 락을 지울 수 있으므로, 락을 잡을 때 넣은 임의 값을 비교한 뒤 삭제하라고 설명한다.

이 방식은 기본적인 실수를 줄인다. 예를 들어 A가 잡은 락이 만료된 뒤 B가 같은 키를 잡았는데, A가 뒤늦게 `DEL`을 실행하면 B의 락을 지울 수 있다. 그래서 해제 시에는 "키 값이 내가 넣은 값일 때만 삭제"해야 한다.

하지만 이것만으로 충분하지 않다. TTL이 지난 뒤에도 A의 비즈니스 로직은 계속 실행될 수 있기 때문이다. 락 키가 사라졌다는 사실이 이미 시작된 Java 스레드, 외부 API 요청, DB 트랜잭션을 자동으로 멈추지는 않는다. 여기서 필요한 것이 fencing token이다. fencing token은 락을 얻을 때마다 증가하는 번호이고, 실제 저장소는 더 작은 번호의 쓰기를 거부한다.

## 코드로 보기

Redis 락 값은 해제 안전성을 위한 임의 값으로 두고, 쓰기 순서는 별도의 증가 번호로 관리할 수 있다.

```text
1. token = INCR settlement:fence
2. ok = SET settlement:lock:{date} randomValue NX PX 30000
3. ok가 아니면 작업하지 않는다
4. DB에 결과를 쓸 때 token도 함께 보낸다
5. DB는 기존 token보다 큰 경우에만 갱신한다
```

DB 테이블이 다음처럼 되어 있다고 하자.

```sql
CREATE TABLE settlement_result (
    settlement_date date PRIMARY KEY,
    total_amount numeric(18, 2) NOT NULL,
    fencing_token bigint NOT NULL,
    updated_at timestamp NOT NULL
);
```

쓰기 쿼리는 단순 upsert가 아니라 token 조건을 포함해야 한다.

```sql
INSERT INTO settlement_result (
    settlement_date, total_amount, fencing_token, updated_at
) VALUES (
    DATE '2026-07-08', 1250000.00, 42, now()
)
ON CONFLICT (settlement_date)
DO UPDATE SET
    total_amount = EXCLUDED.total_amount,
    fencing_token = EXCLUDED.fencing_token,
    updated_at = EXCLUDED.updated_at
WHERE settlement_result.fencing_token < EXCLUDED.fencing_token;
```

이제 먼저 시작한 작업이 token 41을 받았고, 나중에 시작한 작업이 token 42를 받았다면 token 41의 늦은 쓰기는 거부된다. 중요한 점은 Redis가 아니라 최종 상태를 저장하는 DB가 순서를 검증한다는 것이다. 락 서버가 "누가 먼저 시작했는가"를 알려준다면, 데이터 저장소는 "누가 더 최신 권한으로 쓰는가"를 확인해야 한다.

## 자주 하는 실수

첫 번째 실수는 TTL을 아주 길게 잡으면 문제가 사라진다고 생각하는 것이다. TTL을 10분으로 늘리면 평소 지연에는 버틸 수 있지만, 장애 상황에서는 오히려 복구가 늦어진다. 작업 프로세스가 죽거나 네트워크가 끊겼을 때 다음 실행이 10분 동안 막힐 수 있다. TTL은 최대 작업 시간을 넉넉히 덮는 숫자가 아니라, 중복 실행과 복구 지연 사이의 타협값이다.

두 번째 실수는 Redis replica failover를 락 안정성으로 착각하는 것이다. Redis 공식 문서는 단순 master-replica failover에서는 복제가 비동기라서 master가 쓰기를 replica에 전달하기 전에 죽으면, 승격된 replica에서 다른 클라이언트가 같은 락을 잡을 수 있다고 설명한다. "가끔 둘이 동시에 실행되어도 괜찮은 작업"과 "절대 둘이 쓰면 안 되는 작업"은 같은 락 설계로 다루면 안 된다.

세 번째 실수는 락 해제만 안전하게 만들고 실제 쓰기에는 아무 조건을 두지 않는 것이다. Lua 스크립트나 `DELEX`로 "내 락만 지우기"를 구현해도, TTL 이후 늦게 끝난 비즈니스 쓰기는 막지 못한다. 락 해제 안전성과 데이터 쓰기 순서 안전성은 다른 문제다.

## 언제 쓰면 좋은가

Redis 락은 중복 실행 비용을 줄이는 데 잘 맞는다. 예를 들어 캐시 재생성, 주기적 리포트 생성, 중복 알림 억제처럼 같은 작업이 잠깐 겹치면 비효율은 있지만 데이터가 망가지지는 않는 경우다. 이때는 `SET NX PX`와 안전한 해제만으로도 실용적인 보호가 된다.

반대로 최종 데이터의 정합성이 중요한 쓰기라면 Redis 락만으로 끝내지 말아야 한다. DB row version, 낙관적 락, unique constraint, fencing token 같은 저장소 레벨의 조건을 같이 둬야 한다. 특히 외부 시스템 호출이 길거나, 작업 시간이 입력 크기에 따라 크게 달라지거나, 프로세스가 중간에 멈출 수 있는 배치라면 fencing token을 먼저 고려하는 편이 안전하다.

실무 기준은 간단하다. "락이 풀린 뒤 이전 작업이 계속 실행되어도 괜찮은가?"라는 질문에 아니라고 답하면, 락 외에 쓰기 검증이 필요하다. Redis 락은 문 앞의 출입 통제이고, fencing token은 최종 결재선의 도장 확인에 가깝다.

## 운영에서 볼 것

운영에서는 락 획득 실패 횟수만 보면 부족하다. 락을 잡은 뒤 실제 작업 시간이 TTL의 몇 퍼센트까지 올라가는지 봐야 한다. p95 작업 시간이 TTL의 70~80%에 가까워지면, 다음 배포나 데이터 증가 때 만료 후 쓰기가 현실적인 문제가 될 수 있다.

함께 남길 로그는 다음 정도면 충분하다.

```text
event=settlement_lock_acquired date=2026-07-08 fencing_token=42 ttl_ms=30000
event=settlement_write_skipped date=2026-07-08 fencing_token=41 reason=stale_token
event=settlement_duration date=2026-07-08 duration_ms=38210 ttl_ms=30000
```

지표로는 락 획득 실패율, 작업 시간 p95/p99, stale token으로 거부된 쓰기 수, TTL 초과 작업 수를 본다. stale token 거부가 발생했다면 fencing token이 사고를 막은 것이므로 조용히 무시하지 말고 원인을 분석해야 한다. 작업 시간이 길어진 것인지, 재시도가 과한 것인지, 락 TTL이 현실과 맞지 않는지 확인해야 한다.

## 정리

Redis 분산 락은 중복 실행을 줄이는 좋은 도구지만, TTL 이후 늦게 끝난 작업의 쓰기까지 자동으로 막아주지는 않는다. 락 해제는 임의 값을 비교해 안전하게 처리하고, 중요한 쓰기는 fencing token이나 DB 조건으로 순서를 검증해야 한다. 적용 기준은 "중복 실행이 불편한가"가 아니라 "늦은 쓰기가 데이터를 망가뜨리는가"다.

참고한 공식 문서:

- [Redis Docs - Distributed Locks with Redis](https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/)
- [Redis Docs - SET command](https://redis.io/docs/latest/commands/set/)
