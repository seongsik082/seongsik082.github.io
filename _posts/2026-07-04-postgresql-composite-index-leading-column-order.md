---
title: "복합 인덱스 선두 컬럼 순서를 잘못 잡으면 조건은 맞는데도 느려지는 이유"
date: 2026-07-04 08:57:00 +0900
tags: [PostgreSQL, Database, Backend]
excerpt: "PostgreSQL 복합 인덱스는 컬럼을 많이 넣는다고 좋아지지 않습니다. 선두 컬럼의 equality 조건과 ORDER BY 방향이 실제 쿼리와 어긋나면 인덱스가 있어도 긴 스캔과 불필요한 정렬이 남습니다."
---

## 문제 상황

주문 목록 API를 운영하다 보면 `tenant_id`, `status`, `created_at` 같은 컬럼으로 검색하고 최신순 `LIMIT 50`을 붙이는 쿼리가 자주 나옵니다. 그래서 많은 팀이 "자주 쓰는 컬럼을 다 넣자"는 생각으로 복합 인덱스를 하나 크게 만듭니다.

문제는 복합 인덱스가 단순히 "포함된 컬럼 집합"으로 동작하지 않는다는 점입니다. 예를 들어 `WHERE tenant_id = ? AND status = 'PAID' ORDER BY created_at DESC LIMIT 50`가 핵심 쿼리인데 인덱스를 `(tenant_id, created_at DESC, status)`로 만들면, 겉보기에는 필요한 컬럼이 모두 들어 있어도 실제로는 `status`를 늦게 적용하게 됩니다. 그러면 같은 tenant의 최근 주문을 넓게 스캔한 뒤 그중에서 `PAID`만 걸러내는 식으로 비용이 커질 수 있습니다.

운영에서는 이런 문제가 더 헷갈립니다. `EXPLAIN`에 인덱스 이름이 찍히니 "인덱스를 잘 탔다"고 착각하기 쉽기 때문입니다. 하지만 중요한 것은 인덱스를 사용했는가가 아니라, 어디까지 인덱스가 스캔 범위를 줄였는가와 정렬을 대신했는가입니다.

## 핵심 개념

PostgreSQL 공식 문서는 B-tree 복합 인덱스가 선두, 즉 왼쪽 컬럼 조건에 가장 민감하다고 설명합니다. 선두 컬럼들에 대한 equality 조건과, 그다음 첫 비-equality 컬럼의 범위 조건이 인덱스 스캔 범위를 실제로 줄입니다. 그 오른쪽 컬럼 조건은 인덱스 안에서 검사되어 테이블 방문을 줄일 수는 있어도, 스캔 범위를 충분히 줄이지 못할 수 있습니다.

또 PostgreSQL은 `ORDER BY`를 인덱스로 바로 만족할 수 있으면 별도 sort를 생략할 수 있습니다. 특히 `LIMIT`가 붙은 조회에서는 이 차이가 큽니다. 필요한 앞쪽 몇 건만 바로 읽고 끝낼 수 있기 때문입니다.

최근 PostgreSQL 문서는 skip scan 최적화도 설명합니다. 선두 컬럼 equality가 없어도 뒤쪽 조건을 활용해 반복 검색으로 일부를 건너뛸 수 있다는 뜻입니다. 다만 이는 선두 컬럼의 distinct 값이 적을 때만 유리할 수 있는 예외적 최적화에 가깝습니다. "어차피 skip scan이 알아서 해주겠지"라고 기대하고 컬럼 순서를 대충 정하면 안 됩니다.

## SQL로 보기

핵심 쿼리가 아래와 같다고 가정해 보겠습니다.

```sql
SELECT id, created_at, amount
FROM orders
WHERE tenant_id = 42
  AND status = 'PAID'
ORDER BY created_at DESC
LIMIT 50;
```

이 경우 실무에서 먼저 검토할 인덱스는 보통 이런 형태입니다.

```sql
CREATE INDEX idx_orders_tenant_status_created_at
    ON orders (tenant_id, status, created_at DESC);
```

이 순서의 장점은 분명합니다.

- `tenant_id = 42`로 큰 범위를 먼저 줄입니다.
- `status = 'PAID'`로 그 안을 한 번 더 줄입니다.
- 남은 집합을 `created_at DESC` 순서로 바로 읽으며 `LIMIT 50`을 빠르게 만족할 수 있습니다.

반대로 `(tenant_id, created_at DESC, status)`는 최신순 정렬에는 도움이 될 수 있어도, `status`가 뒤에 밀려 있어서 최근 데이터 중 많은 행을 읽고 버리는 상황이 생길 수 있습니다. 인덱스 컬럼이 많아질수록 "다 들어 있으니 좋다"가 아니라 "실제 WHERE와 ORDER BY가 왼쪽부터 어떤 순서로 적용되는가"를 따져야 합니다.

## 자주 하는 실수

첫 번째 실수는 조회 조건에 나오는 컬럼을 사용 빈도 순으로만 나열하는 것입니다. 복합 인덱스는 체크리스트가 아니라 경로입니다.

두 번째 실수는 범위 조건을 너무 앞에 두는 것입니다. 예를 들어 `created_at >= now() - interval '7 days'` 같은 조건이 선두에 오면, 그 뒤의 equality 컬럼들이 스캔 범위를 충분히 줄이지 못할 수 있습니다.

세 번째 실수는 `ORDER BY` 방향을 무시하는 것입니다. PostgreSQL 문서가 설명하듯 B-tree는 정렬을 만족할 수 있지만, 다중 컬럼에서 혼합 방향이 필요하면 인덱스 정의도 그에 맞춰야 합니다.

네 번째 실수는 컬럼을 4개, 5개씩 계속 붙이는 것입니다. PostgreSQL 공식 문서도 3개를 넘는 인덱스는 테이블 사용 패턴이 아주 고정적이지 않으면 도움이 적을 수 있다고 경고합니다. 인덱스가 커지면 쓰기 비용과 메모리 압박도 함께 늘어납니다.

## 언제 쓰면 좋은가

복합 인덱스는 다음 조건이 함께 있을 때 특히 가치가 큽니다.

- equality 필터가 반복적으로 같이 등장할 때
- 그 뒤에 정렬 또는 범위 조건이 자주 따라올 때
- `LIMIT`가 붙어 앞쪽 일부만 빨리 읽는 것이 중요할 때

반대로 화면마다 조건 조합이 제각각이고, 선두 컬럼이 거의 선택도를 만들지 못한다면 단일 인덱스 여러 개나 아예 다른 쿼리 구조가 나을 수 있습니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "복합 인덱스의 왼쪽부터 읽었을 때, 실제 쿼리가 데이터 양을 단계적으로 줄이는가?" 이 질문에 자신 있게 답하지 못하면 인덱스 정의를 다시 보는 편이 안전합니다.

## 운영에서 볼 것

- `EXPLAIN (ANALYZE, BUFFERS)`에서 rows estimate와 actual rows 차이가 큰지
- sort node가 남아 있는지
- `LIMIT` 조회인데도 shared read가 과하게 큰지
- 같은 API에서 `Rows Removed by Filter`가 많이 찍히는지
- 인덱스 추가 후 쓰기 지연과 인덱스 크기가 감당 가능한지

장애 대응에서는 "인덱스가 있다"보다 "불필요하게 몇 행을 읽고 몇 행을 버렸는가"를 먼저 봐야 합니다. 복합 인덱스는 존재 자체보다 컬럼 순서가 성능을 결정합니다.

## 정리

PostgreSQL 복합 인덱스는 필요한 컬럼을 많이 넣는 기술이 아니라, 자주 쓰는 `WHERE`와 `ORDER BY` 흐름을 왼쪽부터 맞추는 기술입니다. 선두 equality 조건, 그다음 범위 조건, 마지막 정렬 요구가 실제 쿼리와 맞아야 스캔 범위와 sort 비용이 함께 줄어듭니다. 인덱스 이름이 실행 계획에 보인다고 안심하지 말고, 어떤 컬럼 순서가 진짜로 읽을 데이터를 줄였는지까지 확인해야 합니다.

## 참고한 공식 문서

- [PostgreSQL 18 Docs: Multicolumn Indexes](https://www.postgresql.org/docs/current/indexes-multicolumn.html)
- [PostgreSQL 18 Docs: Indexes and `ORDER BY`](https://www.postgresql.org/docs/current/indexes-ordering.html)
