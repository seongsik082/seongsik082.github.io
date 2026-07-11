---
title: "PostgreSQL advisory lock을 커넥션 풀과 함께 쓰면 작업 중복이 다시 생기는 이유"
date: 2026-07-11 08:50:00 +0900
tags: [PostgreSQL, Database, Distributed Systems, Backend]
excerpt: "PostgreSQL advisory lock은 세션 수준과 트랜잭션 수준의 수명이 다릅니다. 커넥션 풀에서 세션 락을 대충 사용하면 락이 예상보다 오래 남거나, 반대로 다른 연결에서 작업을 시작해 중복 처리가 생길 수 있습니다."
---

## 문제 상황

정산 배치를 여러 인스턴스에서 동시에 실행하지 않기 위해 PostgreSQL advisory lock을 붙였다고 하자. 로컬에서는 한 번에 하나의 작업만 실행되고, SQL도 정상적으로 동작한다. 그런데 운영 배포 뒤에는 특정 날짜의 정산이 두 번 실행되거나, 반대로 아무도 락을 잡지 못해 작업이 오래 대기하는 일이 생긴다.

처음에는 PostgreSQL 락이 불안정하다고 의심하기 쉽다. 실제 원인은 락의 수명과 애플리케이션의 커넥션 수명을 혼동한 경우가 많다. 특히 세션 수준 advisory lock은 트랜잭션이 끝났다고 자동으로 풀리지 않는다. JDBC나 HikariCP 같은 커넥션 풀은 물리 DB 연결을 재사용하므로, 반환한 연결에 남은 세션 락이 다음 요청의 동작에 영향을 줄 수 있다.

반대로 락을 얻은 연결과 실제 작업을 수행하는 연결이 달라지면 advisory lock은 작업을 보호하지 못한다. 애플리케이션 스레드가 락을 얻은 뒤 커넥션을 반납하고, 서비스 메서드 안에서 새 커넥션으로 데이터를 변경하는 식의 구현이 대표적인 예다. 락 획득은 성공했지만 보호해야 할 SQL은 락과 무관한 세션에서 실행된다.

## 핵심 개념

Advisory lock은 PostgreSQL이 의미를 해석하지 않는 애플리케이션용 잠금이다. 예를 들어 `billing:2026-07-11`이라는 작업 이름을 하나의 정수 키로 정해 두고, 같은 키를 요청한 세션끼리만 서로 기다리게 만들 수 있다. 테이블의 특정 행에 자동으로 걸리는 row lock과 달리, 어떤 작업을 보호할지와 키를 어떻게 만들지는 애플리케이션의 책임이다.

가장 먼저 구분해야 할 것은 수명이다.

- 세션 수준 락은 `pg_advisory_lock`으로 얻고 명시적으로 unlock하거나 DB 세션이 끝날 때까지 유지된다.
- 트랜잭션 수준 락은 `pg_advisory_xact_lock`으로 얻고 현재 트랜잭션이 끝나면 자동으로 해제된다.
- `pg_try_advisory_lock`과 `pg_try_advisory_xact_lock`은 기다리지 않고 즉시 성공 여부를 반환한다.

웹 요청이나 짧은 배치처럼 “이 트랜잭션이 끝나면 보호도 끝난다”는 요구라면 트랜잭션 수준 락이 기본 선택이다. 세션 락은 여러 트랜잭션에 걸쳐 같은 DB 세션을 유지해야 하는 특별한 작업에서만 선택하고, 해제와 연결 소유권을 더 엄격하게 관리해야 한다.

또한 락 키는 전역 규칙이어야 한다. 한 코드에서는 주문 ID `42`를 사용하고 다른 코드에서는 사용자 ID `42`를 같은 락 키로 쓰면 서로 관련 없는 작업이 불필요하게 직렬화된다. 반대로 같은 리소스를 서로 다른 키로 표현하면 락이 있어도 동시에 실행된다. 키에 리소스 종류를 포함하거나, 두 개의 정수 키를 사용하는 규칙을 팀 차원에서 고정하는 편이 안전하다.

## 코드로 보기

정산 날짜별로 한 워커만 실행하려면 락 획득과 보호할 변경을 같은 트랜잭션 안에 둔다.

```sql
BEGIN;

-- 같은 날짜를 처리하는 다른 트랜잭션은 여기서 대기한다.
SELECT pg_advisory_xact_lock(20260711);

-- 락을 잡은 트랜잭션의 같은 연결에서 실행해야 한다.
INSERT INTO billing_run(run_date, started_at)
VALUES (DATE '2026-07-11', now())
ON CONFLICT (run_date) DO NOTHING;

-- 정산 대상 조회와 상태 변경도 이 트랜잭션의 경계 안에서 수행한다.
COMMIT;
```

작업이 이미 실행 중이면 기다리지 않고 이번 실행을 건너뛰고 싶을 때는 `try` 버전을 사용한다.

```sql
BEGIN;

SELECT pg_try_advisory_xact_lock(20260711) AS acquired;
-- acquired = false면 작업을 시작하지 않고 ROLLBACK

-- acquired = true인 경우에만 정산 처리
COMMIT;
```

Spring에서는 락 획득과 실제 작업을 하나의 `@Transactional` 메서드에 묶는 구조가 이해하기 쉽다. 다만 프록시 경계, `REQUIRES_NEW`, 비동기 실행을 섞으면 실제 트랜잭션과 연결이 달라질 수 있다. 락을 얻는 메서드와 작업 메서드를 서로 다른 트랜잭션으로 나누지 말고, SQL 로그와 트랜잭션 경계를 함께 확인해야 한다.

세션 수준 락을 꼭 써야 한다면 연결을 직접 소유하는 코드가 명확해야 한다.

```java
try (Connection connection = dataSource.getConnection()) {
    connection.setAutoCommit(false);
    try (PreparedStatement lock = connection.prepareStatement(
            "select pg_advisory_lock(?)")) {
        lock.setLong(1, jobKey);
        lock.execute();
    }

    runJobUsingSameConnection(connection);

    try (PreparedStatement unlock = connection.prepareStatement(
            "select pg_advisory_unlock(?)")) {
        unlock.setLong(1, jobKey);
        unlock.execute();
    }
    connection.commit();
} // 풀에 반환되기 전에 성공·실패 경로 모두 정리해야 한다.
```

이 코드는 예시일 뿐이며, 예외 경로에서 unlock과 rollback을 빠뜨리면 안 된다. 일반적인 서비스 코드라면 이런 수동 관리보다 트랜잭션 수준 함수를 사용하는 편이 실수할 지점이 적다.

## 자주 하는 실수

첫 번째 실수는 `pg_advisory_lock`을 실행한 뒤 트랜잭션이 끝났으니 락도 풀렸다고 생각하는 것이다. 세션 락은 트랜잭션과 무관하다. 풀에 반환된 물리 연결이 계속 살아 있으면 락도 남아 있을 수 있고, 다음 요청이 같은 연결을 받아 예상치 못한 대기를 만들 수 있다.

두 번째 실수는 락을 얻는 SQL과 작업 SQL 사이에서 커넥션을 반납하는 것이다. 애플리케이션 코드가 `acquireLock()`과 `process()`를 별도 메서드로 나누는 것 자체가 문제는 아니지만, 두 메서드가 같은 트랜잭션과 같은 DB 연결을 사용한다는 보장이 있어야 한다. 비동기 이벤트나 별도 스레드로 작업을 넘기면 그 보장은 사라진다.

세 번째 실수는 모든 경합을 기다리게 만드는 것이다. 대기 시간이 사용자 요청 timeout보다 길면 애플리케이션 스레드와 DB 연결이 동시에 묶인다. 사용자 요청에서 독점 작업을 수행해야 하는 상황이 아니라면 `pg_try_advisory_xact_lock`으로 즉시 409나 재시도 응답을 주거나, 작업을 큐로 넘기는 편이 낫다.

네 번째 실수는 advisory lock을 데이터 정합성 제약 조건으로 착각하는 것이다. 락을 거치지 않는 다른 SQL이나 운영 스크립트는 보호되지 않는다. 중복을 절대 허용하면 안 되는 값에는 unique constraint나 조건부 UPDATE를 함께 둬야 한다. advisory lock은 협력하는 코드 경로 사이의 실행 순서를 조정하는 도구에 가깝다.

## 언제 쓰면 좋은가

advisory lock은 리소스가 테이블의 한 행으로 자연스럽게 표현되지 않거나, 여러 SQL을 하나의 논리 작업으로 직렬화해야 할 때 유용하다. 특정 고객의 일괄 설정 변경, 같은 테넌트의 스키마 마이그레이션, 날짜별 집계처럼 “같은 키의 작업만 겹치지 않으면 된다”는 요구에 잘 맞는다.

판단 기준은 보호 범위를 먼저 적는 것이다. 보호할 SQL이 하나의 DB 트랜잭션 안에 있고 트랜잭션 종료 시 락도 풀려야 한다면 `pg_advisory_xact_lock`을 선택한다. 기다리면 안 되는 사용자 요청이나 재실행 가능한 배치라면 `pg_try_advisory_xact_lock`을 선택한다. 여러 트랜잭션을 가로질러 락을 유지해야 한다면 세션 락을 검토하되, 연결 풀과 예외 정리 테스트를 먼저 만든다.

반대로 DB 밖의 외부 API 호출을 수십 초 동안 보호하려는 용도로는 주의해야 한다. 트랜잭션을 오래 열어 두면 DB 연결과 잠금 대기가 함께 늘어난다. 외부 작업은 작업 상태를 DB에 기록하고, 큐·idempotency key·짧은 상태 전이로 중복 실행을 제어하는 구조가 더 적합한 경우가 많다.

## 운영에서 볼 것

락 대기가 발생하면 애플리케이션 로그만 보지 말고 `pg_locks`와 `pg_stat_activity`를 함께 확인한다. 세션 락인지 트랜잭션 락인지, 어떤 PID가 기다리고 어떤 PID가 보유하는지, 해당 세션의 마지막 쿼리와 트랜잭션 시작 시각을 맞춰 봐야 한다.

```sql
SELECT
    a.pid,
    a.state,
    a.wait_event_type,
    a.wait_event,
    a.xact_start,
    l.locktype,
    l.mode,
    l.granted,
    l.classid,
    l.objid,
    a.query
FROM pg_locks l
JOIN pg_stat_activity a ON a.pid = l.pid
WHERE l.locktype = 'advisory'
ORDER BY l.granted, a.xact_start;
```

지표는 락 획득 대기 시간, 획득 실패 수, 작업 처리 시간, DB connection pool active와 pending 수를 함께 남기는 것이 좋다. 락 대기만 늘고 DB CPU가 낮다면 같은 키에 작업이 몰렸거나, 세션 락이 풀리지 않은 상태일 수 있다. 반대로 풀의 pending 수와 트랜잭션 시간이 같이 늘면 락의 문제라기보다 보호 구간이 너무 넓은 것이다.

로그에는 사람이 읽을 수 있는 작업 이름과 숫자 키를 모두 기록한다.

```text
advisory_lock acquire key=tenant:42 hash=918273 waitMs=12 acquired=true
advisory_lock release key=tenant:42 durationMs=840
advisory_lock skip key=tenant:42 reason=already_running
```

장애 대응 때는 “락이 걸렸다”에서 멈추지 말고 세 가지를 순서대로 확인한다. 첫째, 같은 리소스가 모든 경로에서 같은 키로 변환되는가. 둘째, 락과 작업이 같은 트랜잭션·같은 커넥션에서 실행되는가. 셋째, 작업이 실패한 뒤 세션 락이 풀렸는가. 이 세 가지를 확인하면 PostgreSQL 자체의 문제와 애플리케이션 경계 문제를 빠르게 나눌 수 있다.

## 정리

PostgreSQL advisory lock은 세션 수준과 트랜잭션 수준의 수명이 다르다.
커넥션 풀을 쓰는 일반적인 서비스 작업에는 트랜잭션 수준 락이 더 안전한 기본값이다.
락을 얻는 연결과 실제 작업을 수행하는 연결이 달라지면 보호 효과가 사라진다.
운영에서는 락 대기 시간, `pg_locks`, 트랜잭션 시간, connection pool 대기를 함께 확인하자.

## 참고한 공식 문서

- [PostgreSQL 18 System Administration Functions - Advisory Lock Functions](https://www.postgresql.org/docs/current/functions-admin.html)
