---
title: "PostgreSQL partial index는 조건이 조금만 달라도 실행 계획에서 사라지는 이유"
date: 2026-07-10 09:55:00 +0900
tags: [PostgreSQL, Database, Backend]
excerpt: "PostgreSQL partial index는 특정 조건을 만족하는 행만 인덱싱해 작고 빠른 인덱스를 만들 수 있지만, 쿼리의 WHERE 조건이 인덱스 predicate를 명확히 함의하지 못하면 planner가 인덱스를 사용할 수 없습니다."
---

## 문제 상황

주문 테이블에서 아직 결제되지 않은 주문만 자주 조회한다고 가정해 보자. 전체 주문은 수천만 건이지만 `paid = false`인 행은 1%도 되지 않는다. 그래서 DBA나 백엔드 개발자는 전체 테이블에 큰 인덱스를 하나 더 붙이는 대신, 미결제 주문만 담는 partial index를 만든다.

처음에는 잘 동작한다. `WHERE paid is not true` 조건을 붙인 배치 조회가 빨라지고, 인덱스 크기도 작아서 쓰기 부담이 덜하다. 그런데 어느 날 애플리케이션 코드가 `WHERE paid = false` 또는 `WHERE coalesce(paid, false) = false`로 바뀐 뒤 같은 기능이 갑자기 느려진다. 인덱스는 그대로 있는데 `EXPLAIN`에는 sequential scan이 보인다.

partial index는 "작은 인덱스"라기보다 "조건이 맞을 때만 존재하는 인덱스"에 가깝다. PostgreSQL planner가 이 쿼리는 partial index에 들어 있는 행만 읽어도 된다고 판단하지 못하면, 인덱스가 있어도 안전하게 사용할 수 없다.

## 핵심 개념

partial index는 테이블 전체가 아니라 predicate, 즉 조건식을 만족하는 일부 행에 대해서만 인덱스 항목을 만든다.

```sql
CREATE INDEX orders_unpaid_idx
ON orders (created_at, id)
WHERE paid is not true;
```

이 인덱스에는 `paid is not true`인 주문만 들어 있다. 따라서 아래 쿼리는 이 인덱스를 사용할 가능성이 있다.

```sql
SELECT id, created_at, amount
FROM orders
WHERE paid is not true
ORDER BY created_at
LIMIT 100;
```

반대로 아래 쿼리는 사람 눈에는 비슷해 보여도 planner 입장에서는 더 조심스럽다.

```sql
SELECT id, created_at, amount
FROM orders
WHERE coalesce(paid, false) = false
ORDER BY created_at
LIMIT 100;
```

PostgreSQL 공식 문서는 partial index가 사용되려면 쿼리의 `WHERE` 조건이 인덱스 predicate를 수학적으로 함의한다고 시스템이 인식할 수 있어야 한다고 설명한다. 여기서 중요한 부분은 "인식할 수 있어야 한다"는 점이다. PostgreSQL은 모든 동치 표현을 증명하는 일반 정리 증명기를 갖고 있지 않다. 단순한 부등식 함의 정도는 알아볼 수 있지만, 대부분은 쿼리 조건이 인덱스 predicate와 명확히 맞아야 한다.

## 코드로 보기

운영에서 흔한 패턴은 상태 컬럼이 많은 테이블이다.

```sql
CREATE TABLE payment_requests (
  id bigint primary key,
  user_id bigint not null,
  status text not null,
  requested_at timestamptz not null,
  processed_at timestamptz
);

CREATE INDEX payment_requests_pending_idx
ON payment_requests (requested_at, id)
WHERE status = 'PENDING';
```

이 인덱스는 대기 중인 요청을 오래된 순서로 처리하는 워커에 잘 맞는다.

```sql
SELECT id
FROM payment_requests
WHERE status = 'PENDING'
ORDER BY requested_at, id
LIMIT 100;
```

하지만 애플리케이션에서 상태 목록을 공통 함수로 조립하다가 다음처럼 바뀌면 문제가 생길 수 있다.

```sql
SELECT id
FROM payment_requests
WHERE status IN ('PENDING')
ORDER BY requested_at, id
LIMIT 100;
```

이 표현이 언제나 같은 결과를 낸다고 개발자가 생각해도, planner가 partial index predicate와 충분히 잘 연결하지 못하면 기대한 계획이 나오지 않을 수 있다. 특히 prepared statement에서 파라미터를 쓰는 경우가 더 위험하다.

```sql
PREPARE find_requests(text) AS
SELECT id
FROM payment_requests
WHERE status = $1
ORDER BY requested_at, id
LIMIT 100;
```

`$1`에 항상 `PENDING`만 넣는다고 애플리케이션이 약속해도, 계획 시점에는 모든 값에 대해 인덱스 predicate를 만족한다고 볼 수 없다. 공식 문서도 parameterized query clause는 partial index와 잘 맞지 않는다고 경고한다.

## 자주 하는 실수

첫 번째 실수는 partial index를 일반 인덱스의 작은 버전으로 생각하는 것이다. partial index는 특정 workload를 위한 선택지다. 조건 밖의 행을 조회하는 쿼리에는 도움이 되지 않는다. 같은 컬럼을 조회하더라도 `status = 'DONE'` 요청에는 `payment_requests_pending_idx`가 없다.

두 번째 실수는 조건 표현을 여러 코드 경로에서 제각각 만드는 것이다. Repository A는 `status = 'PENDING'`, Repository B는 `status in (...)`, Batch C는 `processed_at is null`을 사용하면 인덱스 하나를 만들어 놓고도 어떤 쿼리가 혜택을 받는지 예측하기 어렵다. partial index를 쓰는 조건은 가능하면 쿼리 상수처럼 다루는 편이 좋다.

세 번째 실수는 데이터 분포가 바뀌어도 인덱스를 방치하는 것이다. partial index는 "적은 비율의 뜨거운 행"에 특히 유용하다. `PENDING`이 전체의 1%일 때는 좋았지만 장애로 처리 지연이 쌓여 40%가 되면 인덱스 크기와 조회 이점이 달라진다. 이때는 원인을 해결하거나 인덱스 전략을 다시 봐야 한다.

네 번째 실수는 많은 partial index로 partitioning을 흉내 내는 것이다. 예를 들어 카테고리마다 `WHERE category = 1`, `WHERE category = 2` 같은 인덱스를 수십 개 만들면 planner는 매번 적용 가능성을 따져야 한다. PostgreSQL 문서는 이런 사용을 피하고, 테이블이 충분히 크면 partitioning을 검토하라고 안내한다.

## 언제 쓰면 좋은가

partial index는 다음 조건이 함께 맞을 때 좋다.

- 관심 있는 행의 비율이 작고 자주 조회된다.
- 조건이 안정적이며 쿼리에서도 같은 형태로 반복된다.
- 전체 인덱스를 만들면 쓰기 비용이나 저장 공간 부담이 크다.
- `EXPLAIN (ANALYZE, BUFFERS)`로 실제 계획과 버퍼 사용량 개선을 확인할 수 있다.

반대로 조건이 자주 바뀌거나, 조회 조건이 화면 필터처럼 동적으로 조합되거나, 파라미터화된 쿼리가 대부분이면 신중해야 한다. 이 경우 일반 복합 인덱스가 더 예측 가능할 수 있다.

실무 판단 기준은 단순하다. partial index를 만들기 전에 "이 인덱스를 써야 하는 대표 SQL 3개"를 먼저 적고, 그 SQL의 `WHERE` 조건이 인덱스 predicate와 거의 같은 형태로 유지될 수 있는지 확인한다. 유지할 수 없다면 인덱스가 아니라 쿼리 표준화부터 해야 한다.

## 운영에서 볼 것

운영에서는 인덱스 존재 여부보다 실행 계획을 봐야 한다.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id
FROM payment_requests
WHERE status = 'PENDING'
ORDER BY requested_at, id
LIMIT 100;
```

확인할 항목은 세 가지다. 첫째, `Index Scan` 또는 `Index Only Scan`이 기대한 partial index 이름으로 나오는가. 둘째, 실제 읽은 row 수와 buffer hit/read가 줄었는가. 셋째, 애플리케이션에서 사용하는 prepared statement 또는 ORM이 같은 조건식을 유지하는가.

PostgreSQL 통계도 같이 봐야 한다. `pg_stat_user_indexes`에서 `idx_scan`이 계속 0이면 인덱스가 만들어졌지만 쓰이지 않는다는 신호다. `pg_stat_user_tables`의 update, delete 양이 큰 테이블이라면 partial index가 작더라도 쓰기 경로에 추가 비용을 만든다는 점도 고려해야 한다.

## 정리

partial index는 특정 조건의 작은 행 집합을 빠르게 찾기 위한 강한 도구다. 하지만 쿼리 조건이 predicate를 명확히 만족한다고 planner가 판단해야만 사용할 수 있다.

따라서 partial index를 만들 때는 인덱스 DDL만 리뷰하지 말고, 실제 애플리케이션 SQL과 prepared statement 형태까지 같이 리뷰해야 한다. 운영에서는 `EXPLAIN`, `pg_stat_user_indexes`, 데이터 분포 변화를 함께 확인해야 한다.

참고한 공식 문서:

- [PostgreSQL Documentation: Partial Indexes](https://www.postgresql.org/docs/current/indexes-partial.html)
