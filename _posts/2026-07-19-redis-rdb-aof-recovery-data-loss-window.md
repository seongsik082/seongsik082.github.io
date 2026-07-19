---
title: "가져오기 작업 상태를 Redis에만 두면 복구가 어려운 이유"
date: 2026-07-19 08:52:00 +0900
tags: [Redis, PostgreSQL, Operations, Backend]
excerpt: "JD Proof의 import_job을 원본 상태로 두고 Redis 진행률·lease를 캐시로 분리합니다. RDB·AOF의 RPO와 복구 검증 계획을 통해 작업 상태를 다시 판단하는 기준을 정리합니다."
---

## 문제 상황: 화면은 끝났는데 작업 기록이 없다

JD Proof는 채용 공고를 가져와 저장하고 상태를 보여 주는 서비스라고 가정한다. 작업자는 외부 공고를 `job_post`에 반영하고 화면은 `37%`, `완료`, `실패`를 보여 준다. Redis 하나에 진행률과 최종 상태를 함께 넣으면 처음에는 단순해 보인다.

Redis 재시작·TTL 만료·잘못된 삭제 뒤 `job:{id}:status`가 사라지면 공고 저장 여부와 재실행 가능 여부를 알 수 없다. 진행률 유실은 화면 문제지만 최종 상태 유실은 중복 import로 이어진다. 재생성할 수 없는 업무 판단을 Redis의 유일한 원본에 두면 안 되는 이유다.

이 글의 **사례 상태: 설계 시나리오**다. 측정한 장애·성능 결과는 없다. 작은 데이터셋에서 snapshot·재시작 뒤 `import_job`과 key 수를 대조해, 다음 행동을 PostgreSQL 기록으로 정할 수 있는지 검증한다.

## 원본 상태는 PostgreSQL에 남긴다

JD Proof에서 PostgreSQL의 `import_job`이 내구성 있는 원본 상태다. 요청 시 `requested` 행을 만들고, 시작·완료 상태와 공고 저장 결과를 트랜잭션 경계에 맞춰 확정한다. 작업자가 죽어도 이 행으로 미완료 작업을 찾는다. `idempotency_key`는 같은 요청의 중복 생성을 막는 업무 키다.

아래 SQL은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```sql
CREATE TABLE import_job (
  id UUID PRIMARY KEY,
  job_post_id UUID NOT NULL,
  status VARCHAR(20) NOT NULL,
  requested_at TIMESTAMPTZ NOT NULL,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  attempt_no BIGINT NOT NULL DEFAULT 0,
  failure_code VARCHAR(80),
  idempotency_key VARCHAR(100) NOT NULL UNIQUE
);
```

`status`는 업무 상태다. 진행률을 찾지 못하는 일과 DB가 `completed`를 보장하는 일은 다르다. 최종 성공은 Redis가 아니라 DB 행과 공고 저장 결과로 판단하며, 캐시와 DB가 다르면 DB를 우선한다.

## Redis key 계약: 진행률과 lease만 맡긴다

Redis에는 사라져도 되는 빠른 보조 상태만 둔다. TTL은 값이 사라져도 DB로 회복할 수 있다는 계약이다.

아래 Redis 키 계약은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```text
job:{id}:progress  → 화면 표시용 진행률, TTL 10분
job:{id}:lease     → 작업자 중복 실행 방지용 lease, TTL과 갱신 규칙 필요
원본 상태          → PostgreSQL import_job
```

`progress`에는 처리 공고 수와 마지막 갱신 시각만 둔다. 10분 뒤 없어져도 완료 여부는 `import_job`에서 읽는다. 진행률을 못 되살려도 완료 import를 다시 시작해서는 안 된다.

`lease`는 같은 `id`를 동시에 실행하지 않게 하는 짧은 소유권이다. 작업자는 매 lease 획득마다 암호학적으로 안전한 난수로 새 `lease_token`을 만들고, 그 값을 넣어 먼저 60초 lease를 얻는다. 재시작 뒤에도 같은 worker ID를 쓰는 것은 소유권 증명이 아니다. 이전 프로세스가 멈췄다가 돌아오면 새 프로세스와 worker ID가 같을 수 있기 때문이다.

아래 Redis 명령은 lease 갱신 규칙을 설명하기 위한 제안 예시다. 현재 구현이나 측정된 운영 결과가 아니다.

```redis
SET job:{id}:lease {leaseToken} NX EX 60
```

그 뒤 20초마다 저장된 값이 자신의 `{leaseToken}`과 같을 때만 TTL을 60초로 되돌리는 compare-and-expire Lua 연산을 호출한다.

아래는 lease를 가진 시도만 갱신하게 하는 검증용 Lua 예시다.

```lua
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("EXPIRE", KEYS[1], ARGV[2])
end
return 0
```

호출 값은 `KEYS[1]=job:{id}:lease`, `ARGV[1]={leaseToken}`, `ARGV[2]=60`이다. 반환값이 `0`이면 즉시 멈추고 `import_job`과 저장 결과를 대조한다. 단순 `DEL`은 만료 뒤 다른 worker의 lease를 지울 수 있다. Redis 공식 문서도 획득마다 고유한 값을 쓰고, 값이 일치할 때만 해제하도록 설명한다. 60초 TTL과 20초 갱신은 측정 근거가 아닌 시작 계약이다.

여기서 중요한 한계가 있다. token이 맞아도 TTL이 만료된 뒤의 이전 작업자는 이미 새 작업자와 겹칠 수 있다. 그래서 lease만으로 “나는 아직 최신 작업자다”라고 판단하지 않는다. lease를 얻은 뒤 PostgreSQL transaction에서 `attempt_no`를 증가시켜 이번 실행의 버전을 받고, 최종 상태 변경은 그 버전까지 조건으로 건다.

lease를 얻은 worker는 시작 transaction에서 아래 UPDATE를 실행하고, 반환된 `attempt_no`를 해당 실행의 fencing 값으로 보관한다. `running` 작업을 다시 잡는 조건의 `stale_before`는 lease TTL보다 넉넉하게 잡는 운영 정책 값이다.

```sql
UPDATE import_job
SET status = 'running',
    started_at = now(),
    attempt_no = attempt_no + 1
WHERE id = :job_id
  AND (status = 'requested'
       OR (status = 'running' AND started_at < :stale_before))
RETURNING attempt_no;
```

아래 SQL은 이전 시도가 늦게 돌아와도 최신 시도의 완료를 덮지 못하게 하는 제안 스키마다.

```sql
UPDATE import_job
SET status = 'completed', completed_at = now()
WHERE id = :job_id
  AND status = 'running'
  AND attempt_no = :attempt_no;
```

0행이면 그 작업자는 stale worker다. 완료 처리를 하지 않고 DB 상태를 다시 읽는다. 공고 저장에는 `idempotency_key` unique 제약을 함께 둔다. 즉 Redis lease가 아니라 DB의 버전 조건이 최종 fencing(이전 시도 거부)을 맡는다.

## RDB와 AOF가 돕는 범위

Redis persistence는 메모리 데이터를 디스크에 남긴다. RDB는 시점 dataset의 snapshot이다. 마지막 snapshot 뒤 `progress`·`lease`는 비정상 종료 뒤 사라질 수 있지만, 이 설계는 DB로 작업을 판단하므로 RDB 복구 시점이 import 완료 시점은 아니다.

AOF는 write 명령을 기록해 재시작 때 재생한다. `appendfsync everysec`은 재난 때 최근 약 1초의 write를 잃을 수 있다. 이는 시스템 전체 내구성 보장이 아니며 디스크·호스트 손상, 잘못된 명령, PostgreSQL 백업·replica를 대신하지 않는다. AOF는 보조 Redis 상태의 손실 창만 줄인다.

RDB와 AOF를 함께 켜면 재시작 때 더 완전한 AOF로 dataset을 재구성하고 RDB를 snapshot 보관에 쓸 수 있다. 그래도 원본 DB 복구를 뜻하지는 않는다. PostgreSQL에는 별도 백업·복구 지점·replica 또는 고가용성 설계가 필요하며 Redis 파일도 외부 보관과 리허설 대상으로 다룬다.

## RPO 비교: 무엇을 잃어도 되는가

RPO는 장애 때 허용할 수 있는 데이터 손실 시점이다. 아래 표는 설계 판단용이며 특정 서버의 측정 결과가 아니다. “파일이 있는가”보다 “잃은 값을 다시 만들 수 있는가”를 먼저 본다.

| 선택 | 잃어도 되는 정보 | 복구 기준 | 운영 비용 |
| --- | --- | --- | --- |
| RDB만 사용 | 마지막 snapshot 뒤의 `progress`, 만료된 lease 같은 보조 값 | snapshot 뒤 `import_job`의 `requested`·`running`을 조회해 재개 또는 실패 처리 | snapshot 주기, 외부 RDB 보관, fork·재시작 검증 |
| AOF `everysec` | 재난 시 최근 약 1초의 Redis write와 재생성 가능한 보조 값 | AOF가 로드돼도 DB 상태를 정답으로 삼아 key를 다시 채우고 lease를 새로 판단 | AOF 파일 크기, fsync 지연, rewrite 상태, 디스크 여유 |
| Redis를 캐시로만 사용 | 모든 `progress`, lease, 캐시된 상태 표현 | Redis를 비운 뒤 `import_job`과 공고 저장 결과로 화면·재시도 대상을 재생성 | cache warm-up, TTL, 멱등 처리, DB 조회 부하 |

공고 import의 `completed`는 어느 행의 유실 허용값도 아니다. `completed_at`, `failure_code`, `idempotency_key`와 저장 결과는 PostgreSQL의 백업·복제·복구 절차로 보호한다. 이 표는 Redis 보조 데이터의 손실 범위만 설명한다.

## persistence 비용과 운영 확인

RDB snapshot과 AOF rewrite는 `fork()`를 쓰므로 dataset이 크거나 쓰기가 많으면 지연·copy-on-write 메모리 비용이 커질 수 있다. AOF write와 `fdatasync`도 지연 원인이다. `everysec`의 fsync가 길어지면 write가 밀리고, AOF는 RDB보다 파일과 I/O 비용이 커질 수 있다. 최종 상태를 지키겠다는 이유만으로 persistence를 고르지 않는다.

운영에서는 다음을 확인한다.

아래는 운영 확인 항목의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```text
INFO persistence

rdb_last_bgsave_status
aof_last_bgrewrite_status
aof_pending_bio_fsync
```

`INFO persistence`는 snapshot·rewrite·AOF 상태의 출발점이다. `rdb_last_bgsave_status`는 마지막 RDB 생성 실패 방치 여부를, `aof_last_bgrewrite_status`는 rewrite 성공 여부를 본다. `aof_pending_bio_fsync`는 대기 중인 백그라운드 fsync를 보여 준다. 값이 계속 쌓이는지와 요청 지연, 디스크 여유를 같은 시점에 기록한다. 단일 임계값은 아직 정하지 않는다.

## 아직 실행하지 않은 복구 리허설 계획

작은 데이터셋과 별도 테스트 Redis에서만 다음을 실행할 계획이다. production Redis나 실제 공고 데이터를 멈추지 않는다.

1. PostgreSQL에 네 상태와 `idempotency_key`·공고 저장 결과를, Redis에 일부 progress·lease를 준비한다.
2. RDB snapshot과 AOF `everysec` 각각에서 snapshot 전후·AOF write 직후 key를 기록한다. 측정하지 않은 손실 시간·latency는 쓰지 않는다.
3. Redis 재시작 뒤 persistence 지표와 Redis key 수를 기록하고, PostgreSQL의 상태·완료 시각·실패 코드·저장 결과와 대조한다.
4. Redis를 비운 경우에도 DB로 화면을 만들고, 오래된 `running`과 멱등 키 중복 import를 확인한다.
5. worker A를 TTL보다 길게 멈추고, worker B가 새 `lease_token`·더 큰 `attempt_no`로 완료한 뒤 A를 재개한다. A 갱신과 A의 최종 UPDATE는 모두 0이어야 하며 공고도 중복 저장되면 안 된다.

외부 백업은 DB 백업과 Redis 보관본의 위치·무결성을 확인하고 격리 환경에 복원한 뒤 DB 상태 대조와 재시도를 검증한다. Redis persistence는 원본 DB 백업이나 replica의 대체물이 아니다.

## 대안, 제외 범위, 주니어 확인

Redis를 영구 작업 큐로 쓰려면 소비 확인·재처리·보존·장애 조치를 별도 설계해야 한다. 모든 진행 상태를 DB에만 두면 단순하지만 잦은 갱신이 부하가 된다. Redis Cluster·Sentinel·관리형 서비스·완전한 분산 합의는 이 글의 범위 밖이다. 원본 `import_job`은 PostgreSQL, 진행률·짧은 조율은 Redis에 둔다.

코드 리뷰에서는 다섯 가지만 묻는다. 값이 사라져도 다시 만들 수 있는가? 완료를 이 값으로 결정하는가? lease 만료 뒤 이전 작업자가 남는가? 재시작 뒤 어떤 DB 행으로 재개·종료하는가? 이전 시도가 최신 완료를 덮을 수 있는가? 마지막 세 질문에는 고유 `lease_token`, token 비교 갱신, 갱신 실패 중단, `attempt_no` 조건부 UPDATE, 멱등 키가 함께 답해야 한다.

실무 규칙은 간단하다. **Redis가 전부 사라진 뒤에도 PostgreSQL `import_job`만으로 다음 행동을 결정할 수 있어야 한다.** 가능하다면 RDB와 AOF는 보조 상태의 복구 편의와 손실 창을 조절한다. 불가능하다면 persistence 옵션보다 원본 상태의 위치와 DB 백업·replica·복구 리허설부터 다시 설계한다.

## 참고한 공식 문서

- [Redis persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
- [Redis distributed locks](https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/)
- [Redis latency troubleshooting](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency/)
