---
title: "Lock wait timeout이 났을 때 어디부터 봐야 하는가"
date: 2026-07-14 08:51:00 +0900
tags: [PostgreSQL, Database, Transaction, Operations, Backend]
excerpt: "PostgreSQL의 lock_timeout은 잠금 획득을 기다린 시간이 기준을 넘었을 때 문장을 중단할 뿐, 누가 잠금을 잡고 있는지까지 알려주지 않습니다. 대기 세션, blocking PID, 트랜잭션 시작 시각, wait event를 순서대로 확인해야 timeout을 재시도로만 덮지 않고 원인을 줄일 수 있습니다."
---

## 문제 상황

주문 상태를 갱신하는 API에서 갑자기 `canceling statement due to lock timeout`이 늘었습니다. 애플리케이션은 같은 요청을 바로 재시도하지만, 재시도할 때마다 다시 기다리고 connection pool의 pending 수가 커집니다. DB를 재시작하면 잠시 조용해지지만, 다음 배포나 대량 작업 때 같은 문제가 반복됩니다.

lock wait timeout은 “이 문장이 잠금을 기다리다 정해진 시간을 넘었다”는 결과입니다. 그 자체가 원인인 것은 아닙니다. 원인은 긴 트랜잭션, `idle in transaction` 세션, DDL과 쓰기 작업의 충돌, 잠금 순서 불일치처럼 다른 세션이 잠금을 오래 보유한 데 있을 수 있습니다. 따라서 오류 메시지를 본 즉시 timeout 값을 늘리거나 재시도 횟수를 늘리는 것은 조사 순서가 아닙니다.

## timeout 종류부터 구분하기

PostgreSQL의 `lock_timeout`은 테이블·인덱스·행·기타 DB 객체의 잠금 획득을 기다린 시간이 기준을 넘으면 문장을 중단합니다. 각 잠금 획득 시도에 별도로 적용되며, 문장 전체 실행 시간이 아닙니다. `statement_timeout`은 문장 전체 실행 시간에 대한 제한이므로 두 설정을 같은 의미로 보면 안 됩니다.

`deadlock_timeout`도 별도 역할을 합니다. 서버가 잠금을 기다린 뒤 deadlock 검사를 시작하기까지 기다리는 시간이며, `log_lock_waits`가 켜져 있을 때 lock wait 로그가 남기기까지의 기준으로도 사용됩니다. 따라서 lock timeout이 발생했다고 해서 항상 deadlock인 것은 아닙니다. 실제 deadlock은 PostgreSQL이 그래프를 검사해 `deadlock detected`로 별도 보고하고 한 트랜잭션을 중단합니다.

## 세션과 대기 대상을 먼저 본다

장애가 진행 중일 때는 먼저 어떤 세션이 Lock 이벤트를 기다리는지 확인합니다.

```sql
SELECT pid,
       usename,
       application_name,
       client_addr,
       state,
       wait_event_type,
       wait_event,
       xact_start,
       query_start,
       now() - query_start AS query_age,
       left(query, 160) AS query
FROM pg_stat_activity
WHERE wait_event_type = 'Lock'
ORDER BY query_start;
```

`pg_stat_activity`는 서버 프로세스별 현재 활동을 보여줍니다. `wait_event_type = 'Lock'`인 세션은 현재 heavyweight lock을 기다리고 있을 가능성이 큽니다. `state`가 `idle in transaction`인 세션은 SQL 실행은 끝났지만 트랜잭션을 닫지 않아 이전에 잡은 잠금을 계속 보유할 수 있으므로 특히 먼저 봐야 합니다.

그 다음 대기 세션이 어떤 PID에 막혔는지 `pg_blocking_pids()`로 연결합니다.

```sql
SELECT blocked.pid AS blocked_pid,
       blocked.application_name AS blocked_app,
       now() - blocked.query_start AS blocked_for,
       blocking.pid AS blocking_pid,
       blocking.application_name AS blocking_app,
       blocking.state AS blocking_state,
       blocking.xact_start AS blocking_xact_start,
       left(blocking.query, 160) AS blocking_query
FROM pg_stat_activity AS blocked
CROSS JOIN LATERAL unnest(pg_blocking_pids(blocked.pid)) AS b(pid)
JOIN pg_stat_activity AS blocking ON blocking.pid = b.pid
WHERE blocked.wait_event_type = 'Lock';
```

`pg_locks`를 직접 볼 때는 `granted = false`가 잠금을 기다리는 행이라는 점을 기억합니다. 다만 어떤 프로세스가 어떤 프로세스를 막는지 직접 self join으로 추론하는 것은 lock mode 충돌 규칙 때문에 실수하기 쉽습니다. PostgreSQL 공식 문서도 blocking PID를 찾을 때 `pg_blocking_pids()`를 사용하는 편이 낫다고 설명합니다.

## blocking 세션의 원인을 분류하기

### 긴 트랜잭션

`xact_start`가 오래됐고 query는 짧거나 `idle in transaction`이면 애플리케이션이 트랜잭션을 연 뒤 외부 API 호출·파일 처리·사용자 입력을 기다리고 있는지 확인합니다. 트랜잭션 안에서 느린 작업을 수행하면 SQL 한 줄의 실행 시간보다 잠금 보유 시간이 길어집니다. 외부 호출을 트랜잭션 밖으로 빼거나, DB 변경을 짧은 경계로 분리하는 것이 우선입니다.

### DDL과 온라인 요청의 충돌

인덱스 생성, 컬럼 변경, 테이블 재작성 같은 작업은 일반 DML과 다른 lock mode를 요구할 수 있습니다. 마이그레이션이 업무 시간에 시작됐는지, 대기 세션이 특정 테이블을 공통으로 가리키는지 확인합니다. 운영 DDL은 예상 lock 획득 시각과 취소 조건을 함께 정하고, `lock_timeout`을 세션 단위로 제한해 무한 대기를 피하는 것이 안전합니다.

### 애플리케이션의 접근 순서

두 트랜잭션이 여러 행을 서로 다른 순서로 잠그면 deadlock 또는 긴 lock wait가 생길 수 있습니다. 주문과 재고처럼 함께 갱신하는 테이블이 있다면 모든 코드 경로에서 같은 순서로 읽고 갱신하는지 확인합니다. 이때 단순히 재시도만 넣으면 같은 충돌을 반복하므로 접근 순서와 트랜잭션 범위를 먼저 정리합니다.

대기 시간이 짧은데도 timeout이 반복된다면 한 번의 긴 blocker보다 동시 요청이 잠금을 짧게 여러 번 점유하는 패턴일 수 있습니다. 이 경우 특정 PID를 종료하는 것보다 쿼리별 실행 시간과 트랜잭션 경계를 비교해야 합니다. 반대로 blocker 하나의 `xact_start`가 수십 분 전이라면 재시도 횟수를 늘릴 이유가 없고, 해당 세션이 왜 열린 채 남았는지 애플리케이션 흐름과 배치 작업을 확인해야 합니다.

## 코드와 설정에 적용하기

장시간 대기를 허용하지 않는 특정 작업에는 전역 설정을 바꾸기보다 트랜잭션 안에서 `SET LOCAL`을 적용할 수 있습니다.

```sql
BEGIN;
SET LOCAL lock_timeout = '2s';
SET LOCAL statement_timeout = '10s';

UPDATE orders
SET status = 'CANCELLED'
WHERE id = 1004 AND status = 'PAID';

COMMIT;
```

`lock_timeout`은 실패를 없애는 설정이 아니라 빠르게 실패해 상위 계층이 판단할 수 있게 하는 안전장치입니다. 재시도한다면 동일 요청이 다시 실행되어도 안전한지, 최대 횟수·backoff·전체 deadline이 있는지 함께 정의해야 합니다. 트랜잭션이 오류 상태로 남는 드라이버라면 즉시 rollback한 뒤 새 트랜잭션에서 재시도해야 합니다.

조사 기간에는 `log_lock_waits`를 켜고 `deadlock_timeout`을 평소보다 짧게 조정할 수 있지만, 모든 세션에 무작정 적용하지 말고 변경 범위와 로그량을 확인합니다. 로그에는 PID, application name, transaction id와 같은 상관 키를 남기되 SQL parameter에 비밀값이 들어가지 않도록 합니다.

## 자주 하는 실수

첫 번째는 blocking PID를 확인하지 않고 기다리는 세션만 종료하는 것입니다. waiter를 죽이면 현재 요청 하나는 끝나지만, 다음 요청은 같은 blocker를 다시 만납니다. blocker가 정상적인 대량 배치인지, 오래 열린 트랜잭션인지, 이미 실패한 세션인지 확인한 뒤 취소·종료 여부를 결정해야 합니다.

두 번째는 `lock_timeout`을 너무 작게 전역 설정하는 것입니다. 정상적인 짧은 경합도 모두 오류가 되어 retry storm을 만들 수 있습니다. 업무별 latency와 트랜잭션 특성이 다르면 `SET LOCAL`이나 connection 초기화 정책으로 범위를 나누는 편이 낫습니다.

세 번째는 DB에서 보이는 wait만 보고 애플리케이션 connection pool을 보지 않는 것입니다. DB의 blocked 세션 수가 줄어도 애플리케이션 안에 timeout된 요청과 재시도 작업이 쌓이면 서비스는 계속 느릴 수 있습니다. DB wait와 pool pending, HTTP timeout을 같은 시간축으로 비교해야 합니다.

## 운영에서 볼 것

- `pg_stat_activity`의 `wait_event_type`, `state`, `xact_start`, `query_start`
- blocking PID별 트랜잭션 age와 `idle in transaction` 수
- lock timeout·deadlock·`log_lock_waits` 발생률
- endpoint별 재시도 횟수와 최종 실패율
- DB connection pool pending, active, acquisition latency
- 배치·마이그레이션 시작 시각과 잠금 대기 증가 시각

장애 대응 기록에는 waiter query만 남기지 말고 blocker의 PID, 애플리케이션 이름, transaction 시작 시각, 대상 테이블, 최초 관측 시각을 함께 남깁니다. 그래야 다음에 같은 오류가 발생했을 때 “쿼리가 느리다”와 “다른 트랜잭션이 잠금을 놓지 않는다”를 빠르게 구분할 수 있습니다.
재시도 성공 여부와 blocker가 사라진 시각도 함께 기록하면 임시 완화와 근본 해결을 분리해 평가할 수 있습니다.

## 정리

lock wait timeout은 원인이 아니라 잠금 대기가 한도를 넘었다는 결과다.
`pg_stat_activity`에서 waiter와 transaction age를 확인하고 `pg_blocking_pids()`로 blocker를 연결한다.
긴 트랜잭션·DDL 충돌·잠금 순서·idle in transaction을 분류한 뒤 timeout과 재시도 정책을 조정한다.
운영에서는 DB lock wait만 보지 말고 connection pool pending과 애플리케이션 retry storm을 같은 시간축으로 본다.

## 참고한 공식 문서

- [PostgreSQL 18 - Client Connection Defaults: lock_timeout](https://www.postgresql.org/docs/current/runtime-config-client.html#GUC-LOCK-TIMEOUT)
- [PostgreSQL 18 - Lock Management: deadlock_timeout](https://www.postgresql.org/docs/current/runtime-config-locks.html#GUC-DEADLOCK-TIMEOUT)
- [PostgreSQL 18 - pg_locks](https://www.postgresql.org/docs/current/view-pg-locks.html)
- [PostgreSQL 18 - pg_stat_activity and wait events](https://www.postgresql.org/docs/current/monitoring-stats.html#MONITORING-PG-STAT-ACTIVITY-VIEW)
