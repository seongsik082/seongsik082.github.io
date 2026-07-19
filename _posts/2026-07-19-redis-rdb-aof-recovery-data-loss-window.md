---
title: "가져오기 작업 상태를 Redis에만 두면 복구가 어려운 이유"
date: 2026-07-19 08:52:00 +0900
tags: [Redis, PostgreSQL, Operations, Backend]
excerpt: "JD Proof의 import_job을 원본 상태로 두고 Redis 진행률·lease를 캐시로 분리합니다. RDB·AOF의 RPO와 복구 검증 계획을 통해 작업 상태를 다시 판단하는 기준을 정리합니다."
---

## 문제 상황: 화면은 끝났는데 작업 기록이 없다

JD Proof는 채용 공고를 가져와 저장하고 처리 상태를 보여 주는 서비스라고 가정한다. 사용자의 요청으로 작업이 만들어지고, 작업자는 외부 공고를 읽어 `job_post`에 반영한다. 화면에는 `37%`, `완료`, `실패`를 빨리 보여 주고 싶다. 이때 Redis 하나에 진행률과 최종 상태를 함께 넣으면 구현은 단순해 보인다.

하지만 Redis 재시작, TTL 만료, 잘못된 삭제 뒤 `job:{id}:status`가 사라지면 그 작업이 공고를 저장했는지, 중간에 멈췄는지, 다시 실행해도 되는지를 알 수 없다. 진행률 유실은 화면을 다시 만들 문제지만, 최종 상태 유실은 중복 import로 이어진다. 결제·정산·공고 import의 최종 상태처럼 재생성할 수 없는 업무 판단을 Redis의 유일한 원본에 두면 안 되는 이유다.

이 글의 **사례 상태: 설계 시나리오**다. 측정한 장애·성능 결과는 없다. 대신 작은 데이터셋에서 snapshot, Redis 재시작, `import_job` 상태와 key 수 대조를 수행할 복구 실험을 계획한다. 목표는 Redis 파일의 존재가 아니라, 재시작 뒤 다음 행동을 PostgreSQL 기록으로 결정할 수 있는지다.

## 원본 상태는 PostgreSQL에 남긴다

JD Proof에서 PostgreSQL의 `import_job`이 내구성 있는 원본 상태다. 요청 트랜잭션에서 행을 먼저 만들고 `requested`를 기록한다. 작업 시작에는 `started_at`과 `status`를, 완료에는 공고 저장 결과와 완료 상태를 서비스의 트랜잭션 경계에 맞춰 확정한다. 작업자가 죽어도 다음 점검자는 이 행으로 미완료 작업을 찾는다. `idempotency_key`는 같은 요청의 중복 생성을 막는 업무 키다.

아래 SQL은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```sql
CREATE TABLE import_job (
  id UUID PRIMARY KEY,
  job_post_id UUID NOT NULL,
  status VARCHAR(20) NOT NULL,
  requested_at TIMESTAMPTZ NOT NULL,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  failure_code VARCHAR(80),
  idempotency_key VARCHAR(100) NOT NULL UNIQUE
);
```

`status`는 `requested`, `running`, `completed`, `failed`처럼 업무 의미를 가진 값이다. 화면이 진행률을 찾지 못하는 일과 DB가 `completed`를 보장하는 일은 다르다. 최종 성공은 Redis 쓰기 여부가 아니라 DB 행과 공고 저장 결과로 판단한다. Redis가 비어도 DB에서 상태를 읽어 화면을 만들고, 캐시와 DB가 다르면 DB를 우선한다.

## Redis key 계약: 진행률과 lease만 맡긴다

Redis에는 사라져도 되는 빠른 보조 상태만 둔다. TTL은 값이 사라져도 DB로 회복할 수 있다는 계약이다.

아래 Redis 키 계약은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```text
job:{id}:progress  → 화면 표시용 진행률, TTL 10분
job:{id}:lease     → 작업자 중복 실행 방지용 lease, TTL과 갱신 규칙 필요
원본 상태          → PostgreSQL import_job
```

`progress`에는 처리 공고 수와 마지막 갱신 시각처럼 기다리는 동안만 필요한 값을 둔다. 10분 뒤 없어져도 완료 여부는 `import_job`에서 읽는다. 진행률을 다시 계산하지 못하면 화면은 갱신 중으로 표시할 수 있지만, 이미 끝난 import를 다시 시작해서는 안 된다.

`lease`는 같은 `id`를 동시에 실행하지 않게 하는 짧은 소유권이다. 작업자는 worker ID를 값으로 하여 먼저 60초 lease를 얻는다.

아래 Redis 명령은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```redis
SET job:{id}:lease {workerId} NX EX 60
```

그 뒤 20초마다 저장된 값이 자신의 `{workerId}`와 같을 때만 TTL을 60초로 되돌리는 compare-and-expire Lua 연산을 호출한다.

아래 Lua 연산은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```lua
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("EXPIRE", KEYS[1], ARGV[2])
end
return 0
```

호출 값은 `KEYS[1]=job:{id}:lease`, `ARGV[1]={workerId}`, `ARGV[2]=60`이다. 반환값이 `0`이면 작업자는 즉시 처리를 멈추고 PostgreSQL의 `import_job`과 공고 저장 결과를 대조해 재개·실패·정리 여부를 결정한다. 단순 `DEL`은 만료 뒤 다른 작업자가 얻은 lease를 이전 작업자가 지울 수 있으므로 쓰지 않는다. 60초 TTL과 20초 갱신은 실제 job 처리 시간, 지연, 장애 감지 시간을 보고 검증·조정할 시작 계약일 뿐 측정 근거가 아니다.

DB 상태 변경과 Redis lease 획득은 한 저장소의 원자 연산으로 묶을 수 없다. 따라서 lease를 얻어도 현재 DB 상태와 `idempotency_key`를 확인하고 공고 저장을 멱등하게 만든다. Redis를 비웠을 때 잠시 경쟁하더라도 DB 제약과 상태 전이가 최종 중복을 막는다.

## RDB와 AOF가 돕는 범위

Redis persistence는 Redis 메모리 데이터를 디스크에 남기는 기능이다. RDB는 지정 시점의 dataset을 저장하는 snapshot 기반 방식이다. 마지막 snapshot 뒤의 `progress`나 `lease`는 비정상 종료 뒤 사라질 수 있다. 이 설계에서는 그 값이 사라져도 DB에서 작업을 판단하므로 RDB의 복구 시점이 import 완료 시점이 되지 않는다.

AOF는 받은 write 명령을 기록하고 재시작 때 재생한다. `appendfsync everysec`은 재난에서 최근 약 1초의 write를 잃을 수 있다. 이는 전체 시스템의 내구성 보장이 아니다. 디스크·호스트·파일시스템 손상이나 잘못된 명령을 없애지 않으며, PostgreSQL의 백업이나 replica를 대신하지도 않는다. JD Proof에서 AOF는 보조 Redis 상태의 손실 창을 줄이는 선택일 뿐 `import_job`의 내구성을 위임하는 근거가 아니다.

RDB와 AOF를 함께 켜면 재시작 때 더 완전한 AOF로 dataset을 재구성할 수 있고, RDB는 snapshot 복구와 별도 보관에 유용하다. 그러나 둘을 켰다는 사실은 원본 DB를 복구할 수 있다는 뜻이 아니다. PostgreSQL은 별도 백업 정책, 복구 지점 목표, replica 또는 고가용성 설계를 가져야 한다. Redis 파일도 같은 인스턴스·볼륨에만 두지 말고 필요하면 외부 보관과 리허설 대상으로 다룬다.

## RPO 비교: 무엇을 잃어도 되는가

RPO는 장애 때 허용할 수 있는 데이터 손실 시점이다. 아래 표는 설계 판단용이며 특정 서버의 측정 결과가 아니다. “파일이 있는가”보다 “잃은 값을 다시 만들 수 있는가”를 먼저 본다.

| 선택 | 잃어도 되는 정보 | 복구 기준 | 운영 비용 |
| --- | --- | --- | --- |
| RDB만 사용 | 마지막 snapshot 뒤의 `progress`, 만료된 lease 같은 보조 값 | snapshot 뒤 `import_job`의 `requested`·`running`을 조회해 재개 또는 실패 처리 | snapshot 주기, 외부 RDB 보관, fork·재시작 검증 |
| AOF `everysec` | 재난 시 최근 약 1초의 Redis write와 재생성 가능한 보조 값 | AOF가 로드돼도 DB 상태를 정답으로 삼아 key를 다시 채우고 lease를 새로 판단 | AOF 파일 크기, fsync 지연, rewrite 상태, 디스크 여유 |
| Redis를 캐시로만 사용 | 모든 `progress`, lease, 캐시된 상태 표현 | Redis를 비운 뒤 `import_job`과 공고 저장 결과로 화면·재시도 대상을 재생성 | cache warm-up, TTL, 멱등 처리, DB 조회 부하 |

공고 import의 `completed`는 어느 행의 유실 허용값도 아니다. `completed_at`, `failure_code`, `idempotency_key`와 저장 결과는 PostgreSQL의 백업·복제·복구 절차로 보호한다. 이 표는 Redis 보조 데이터의 손실 범위만 설명한다.

## persistence 비용과 운영 확인

RDB snapshot과 AOF rewrite는 `fork()`를 사용한다. dataset이 크면 fork가 응답 지연을 만들고, copy-on-write 때문에 쓰기가 많은 동안 메모리 비용이 커질 수 있다. AOF의 write와 `fdatasync`도 지연 원인이다. `everysec`에서 fsync가 길어지면 write가 지연될 수 있다. AOF는 같은 dataset의 RDB보다 파일이 대체로 크고 fsync 정책에 따라 더 느릴 수 있다. 그래서 최종 상태를 지키려는 이유만으로 Redis persistence 비용을 선택하지 않는다.

운영에서는 다음을 확인한다.

아래 Redis 확인 명령과 항목은 이 설계 시나리오의 제안 예시이며, 현재 구현이나 측정된 운영 결과가 아니다.

```text
INFO persistence

rdb_last_bgsave_status
aof_last_bgrewrite_status
aof_pending_bio_fsync
```

`INFO persistence`는 snapshot·rewrite·AOF 상태의 출발점이다. `rdb_last_bgsave_status`는 마지막 RDB 생성 실패 방치 여부를, `aof_last_bgrewrite_status`는 rewrite 성공 여부를 본다. `aof_pending_bio_fsync`는 대기 중인 백그라운드 fsync를 보여 준다. 값이 계속 쌓이는지와 요청 지연, 디스크 여유를 같은 시점에 기록한다. 단일 임계값은 아직 정하지 않는다.

## 아직 실행하지 않은 복구 리허설 계획

작은 데이터셋과 별도 테스트 Redis에서만 다음을 실행할 계획이다. production Redis나 실제 공고 데이터를 멈추지 않는다.

1. PostgreSQL에 `requested`, `running`, `completed`, `failed` 작업과 `idempotency_key`, 공고 저장 결과를 만든다. Redis에는 일부 progress와 lease를 넣는다.
2. RDB snapshot 경우와 AOF `everysec` 경우를 준비하고 snapshot 전후·AOF write 직후 key를 기록한다. 측정하지 않은 손실 시간이나 latency 수치는 쓰지 않는다.
3. Redis를 중지·재시작한 뒤 `INFO persistence`, `rdb_last_bgsave_status`, `aof_last_bgrewrite_status`, `aof_pending_bio_fsync`, rewrite 상태를 확인한다.
4. 재시작 전후 Redis key 수와 progress·lease 존재를 비교하고, PostgreSQL의 행 수·상태·완료 시각·실패 코드·공고 저장 결과와 대조한다.
5. Redis를 비운 캐시 전용 경우에도 DB로 화면을 다시 만들고, 오래된 `running`을 정책대로 처리하며 동일 멱등 키가 중복 import를 만들지 않는지 확인한다.

외부 백업은 DB 백업과 Redis 보관본의 위치·무결성을 확인하고 격리 환경에 복원한 뒤 DB 상태 대조와 재시도를 검증한다. Redis persistence는 원본 DB 백업이나 replica의 대체물이 아니다.

## 대안, 제외 범위, 주니어 확인

Redis를 작업 큐와 영구 상태 저장소로 설계하는 대안은 소비 확인·재처리·보존 기간·장애 조치를 별도로 설계해야 한다. 모든 진행 상태를 DB에만 두는 대안은 단순하지만 잦은 갱신이 DB 부하를 늘릴 수 있다. 이번 범위에서는 Redis Cluster, Sentinel, 관리형 서비스 설정, 완전한 분산 합의 증명은 다루지 않는다. 확정한 경계는 `import_job`은 PostgreSQL, 진행률과 짧은 실행 조율은 Redis라는 것이다.

코드 리뷰에서는 네 가지만 먼저 묻는다. 값이 사라져도 다시 만들 수 있는가? “공고를 저장했다”를 이 값으로 결정하는가? lease 만료 뒤 이전 작업자가 아직 실행 중일 수 있는가? 재시작 뒤 어떤 DB 행으로 재개·종료를 정하는가? 마지막 두 질문에는 worker ID 비교 갱신, 갱신 실패 시 중단, 멱등 키, DB 상태 대조가 함께 답이 되어야 한다.

실무 규칙은 간단하다. **Redis가 전부 사라진 뒤에도 PostgreSQL `import_job`만으로 다음 행동을 결정할 수 있어야 한다.** 가능하다면 RDB와 AOF는 보조 상태의 복구 편의와 손실 창을 조절한다. 불가능하다면 persistence 옵션보다 원본 상태의 위치와 DB 백업·replica·복구 리허설부터 다시 설계한다.

## 참고한 공식 문서

- [Redis persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/)
- [Redis latency troubleshooting](https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/latency/)
