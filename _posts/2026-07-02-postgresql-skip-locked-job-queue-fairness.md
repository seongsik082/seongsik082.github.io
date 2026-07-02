---
title: "PostgreSQL SKIP LOCKED로 작업 큐를 만들 때 공정성과 재시도 규칙이 필요한 이유"
date: 2026-07-02 08:58:00 +0900
tags: [PostgreSQL, Database, Backend]
excerpt: "PostgreSQL의 SKIP LOCKED는 여러 워커가 같은 작업 테이블을 병렬 처리할 때 유용하지만, 잠긴 행을 건너뛴다는 특성 때문에 공정성, 재시도, 장애 복구 규칙을 함께 설계해야 합니다."
---

## 문제 상황

작은 서비스에서는 별도 메시지 브로커 없이 PostgreSQL 테이블을 작업 큐처럼 쓰는 경우가 많습니다. `jobs` 테이블에 작업을 넣고 여러 워커가 가져가 처리하면 구조가 단순하고, 비즈니스 데이터와 같은 트랜잭션 안에서 작업을 등록하기도 쉽습니다. 그래서 처음에는 `SELECT ... FOR UPDATE SKIP LOCKED`만 붙이면 꽤 잘 굴러가는 것처럼 보입니다.

문제는 운영에서 나타납니다. 어떤 작업은 오래 붙잡혀 있고, 어떤 워커는 계속 최신 작업만 집어 가며, 실패한 작업은 다시 잡히지 않거나 반대로 너무 빨리 재시도됩니다. DB는 멀쩡하고 워커 수도 충분한데 "큐가 비어 있지 않은데도 특정 작업이 오래 밀린다"는 현상이 생깁니다.

핵심은 `SKIP LOCKED`가 잠긴 행을 기다리지 않고 건너뛴다는 점입니다. 이 동작은 처리량을 올리는 데는 유리하지만, "먼저 들어온 작업을 먼저 처리한다" 같은 공정성까지 보장해 주지는 않습니다. 그래서 실무에서는 단순히 락 경합을 줄이는 문법이 아니라, 큐의 선택 규칙을 바꾸는 기능으로 봐야 합니다.

## 핵심 개념

PostgreSQL 공식 문서는 `SKIP LOCKED`가 즉시 잠글 수 없는 행을 건너뛰며, 이런 방식은 일반적인 조회에는 맞지 않지만 여러 소비자가 큐 형태의 테이블에 접근할 때 lock contention을 피하는 데 쓸 수 있다고 설명합니다. 동시에 "inconsistent view"를 만든다고도 명시합니다. 즉, 이 쿼리는 테이블의 현재 상태를 공정하게 대표하는 읽기가 아니라, "지금 당장 집을 수 있는 작업"만 고르는 읽기입니다.

이 특성 때문에 큐 테이블에서는 `status = 'READY'` 조건만으로 충분하지 않습니다. 워커가 작업을 집은 뒤 프로세스가 죽으면 그 행은 여전히 `RUNNING` 상태이면서 다른 워커에게는 계속 보이지 않을 수 있습니다. `SKIP LOCKED`는 충돌을 줄여 주지만, 작업 소유권을 영구히 관리해 주지는 않습니다.

또 하나 중요한 점은 PostgreSQL 공식 문서가 `ORDER BY` 없이 결과 순서를 보장하지 않는다고 분명히 적고 있다는 것입니다. `LIMIT 10`만 붙여 작업을 가져오면 실행할 때마다 다른 묶음이 선택될 수 있습니다. 따라서 "오래 기다린 작업부터 처리"가 목표라면 `ORDER BY available_at, id` 같은 기준을 명시해야 합니다.

## SQL로 보기

실무에서는 조회와 상태 변경을 분리하지 말고, 한 트랜잭션 안에서 "집기"와 "소유권 표시"를 함께 처리하는 편이 안전합니다.

```sql
WITH picked AS (
    SELECT id
    FROM jobs
    WHERE status = 'READY'
      AND available_at <= now()
    ORDER BY available_at, id
    FOR UPDATE SKIP LOCKED
    LIMIT 10
)
UPDATE jobs j
SET status = 'RUNNING',
    locked_at = now(),
    worker_id = 'worker-a',
    attempt_count = attempt_count + 1
FROM picked
WHERE j.id = picked.id
RETURNING j.id, j.payload, j.attempt_count;
```

이 패턴의 장점은 분명합니다. 여러 워커가 동시에 실행해도 이미 다른 워커가 잡은 행은 건너뛰므로 대기 시간이 줄어듭니다. 하지만 이 쿼리만으로는 워커 장애 복구가 끝나지 않습니다. `locked_at`이 너무 오래된 `RUNNING` 작업을 다시 `READY`로 되돌리는 lease 회수 작업이 따로 필요합니다.

예를 들면 아래처럼 "30분 넘게 붙잡힌 작업은 워커가 죽은 것으로 간주한다"는 운영 규칙을 둘 수 있습니다.

```sql
UPDATE jobs
SET status = 'READY',
    worker_id = NULL,
    available_at = now() + interval '5 minutes'
WHERE status = 'RUNNING'
  AND locked_at < now() - interval '30 minutes';
```

이 값은 감으로 넣으면 안 됩니다. 평균 처리 시간, p99 처리 시간, 외부 API timeout, 재시도 비용을 보고 정해야 합니다. 너무 짧으면 정상 처리 중인 작업을 다시 집어 중복 실행하고, 너무 길면 죽은 작업이 오래 방치됩니다.

## 자주 하는 실수

첫 번째 실수는 `SKIP LOCKED`를 넣고도 정렬 기준을 빼는 것입니다. 이렇게 하면 처리량은 나와도 어떤 작업이 먼저 잡힐지 예측하기 어렵고, 오래된 작업이 뒤로 밀릴 수 있습니다. 큐처럼 쓸 거라면 최소한 `available_at`, `priority`, `id` 같은 우선순위를 명시해야 합니다.

두 번째 실수는 `RUNNING` 상태 복구 규칙 없이 워커 생존을 낙관하는 것입니다. 프로세스 강제 종료, 노드 재시작, 배포 중단은 현실에서 자주 일어납니다. 이때 lease 만료와 재할당 규칙이 없으면 작업은 "실패"가 아니라 "영구 대기" 상태가 됩니다.

세 번째 실수는 재시도 횟수와 마지막 오류를 기록하지 않는 것입니다. `attempt_count`, `last_error`, `available_at`이 없으면 실패한 작업을 언제 다시 넣을지, 어디서 반복 실패하는지 판단하기 어렵습니다. 큐가 단순할수록 오히려 메타데이터는 더 명확해야 합니다.

## 언제 쓰면 좋은가

`SKIP LOCKED` 기반 큐는 다음 조건에서 잘 맞습니다.

- 작업 등록을 비즈니스 DB 트랜잭션과 함께 묶고 싶을 때
- 처리량이 아주 크지 않고, 별도 Kafka/RabbitMQ 운영 복잡도를 피하고 싶을 때
- 작업 순서보다 "중복 없이 병렬 처리"가 더 중요한 배치성 업무일 때

반대로 아래 상황이면 별도 메시징 시스템을 먼저 검토하는 편이 낫습니다.

- 엄격한 순서 보장이 중요할 때
- 큐 적체가 수시간 이상 지속될 수 있을 때
- 재시도, DLQ, 지연 큐, 소비자 그룹 분리 같은 기능이 이미 필요할 때

실무 판단 기준을 하나만 고르면 이렇습니다. "지금 필요한 것은 브로커 기능인가, 아니면 DB 안에서 안전하게 작업을 집는 최소 규칙인가?" 후자라면 `SKIP LOCKED`가 좋은 출발점이지만, 전자라면 처음부터 큐 전용 시스템이 더 싸게 먹힐 수 있습니다.

## 운영에서 볼 것

- `READY` 상태 작업의 oldest age
- `RUNNING` 상태에서 lease timeout을 넘긴 작업 수
- `attempt_count` 상위 작업과 마지막 오류 유형
- 워커별 처리 시간 p95/p99
- 같은 작업이 재할당된 횟수

로그에는 최소한 `job_id`, `worker_id`, `attempt_count`, `locked_at`, `finished_at`, `error_code` 정도를 남기는 편이 좋습니다. 그래야 "왜 이 작업만 계속 늦는가"를 DB와 애플리케이션 로그 양쪽에서 좁힐 수 있습니다.

## 정리

PostgreSQL의 `SKIP LOCKED`는 간단한 작업 큐를 병렬화하는 데 매우 실용적입니다. 하지만 잠긴 행을 건너뛴다는 특성 때문에 공정한 조회나 자동 복구까지 보장하지는 않습니다. 운영에서 안전하게 쓰려면 정렬 기준, lease 회수, 재시도 간격, 시도 횟수 기록을 함께 설계해야 합니다. `SKIP LOCKED`는 큐의 완성품이 아니라, 큐를 만들 때 쓰는 핵심 부품에 가깝습니다.

## 참고한 공식 문서

- PostgreSQL 18 Documentation, `SELECT`: https://www.postgresql.org/docs/current/sql-select.html
