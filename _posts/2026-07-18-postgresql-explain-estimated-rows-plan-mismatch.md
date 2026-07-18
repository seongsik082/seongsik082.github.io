---
title: "PostgreSQL EXPLAIN에서 estimated rows가 틀리면 인덱스가 있어도 느려지는 이유"
date: 2026-07-18 08:50:00 +0900
tags: [PostgreSQL, Database, Performance, Backend]
excerpt: "PostgreSQL 쿼리가 갑자기 느려졌을 때 인덱스 유무만 보면 원인을 놓칠 수 있습니다. EXPLAIN ANALYZE의 estimated rows와 actual rows, BUFFERS, ANALYZE 통계, 컬럼 상관관계를 함께 읽어 잘못된 실행 계획을 고치는 순서를 정리합니다."
---

## 문제 상황

운영 중인 주문 조회 API의 p95 지연 시간이 갑자기 늘었습니다. `tenant_id`, `status`, `created_at`에 맞는 인덱스도 있고, 같은 SQL이 개발 환경에서는 빠르게 실행됩니다. 그런데 운영에서는 특정 고객의 요청만 오래 걸리고, DB CPU와 디스크 읽기가 함께 올라갑니다.

이때 “인덱스가 있는데 왜 느리지?”라고 생각하기 쉽습니다. 실제 원인은 인덱스가 없는 것이 아니라 PostgreSQL planner가 읽어야 할 행의 수를 잘못 예상해 적합하지 않은 실행 계획을 고른 것일 수 있습니다. 데이터 분포가 바뀌었거나 여러 컬럼이 서로 강하게 연관되어 있는데, planner가 각 조건을 독립적인 것으로 계산하면 예상 행 수가 실제와 크게 달라집니다.

## 실행 계획에서 먼저 비교할 두 숫자

`EXPLAIN`의 `rows`는 해당 plan node가 내보낼 것으로 예상한 행 수입니다. `EXPLAIN ANALYZE`를 붙이면 쿼리를 실제로 실행하면서 `actual rows`와 실행 시간을 함께 보여줍니다. 두 값이 비슷한지 확인하는 것이 인덱스 이름을 찾는 것보다 먼저입니다.

예를 들어 다음 쿼리가 있다고 하겠습니다.

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, total_price, created_at
FROM orders
WHERE tenant_id = 42
  AND status = 'PENDING'
ORDER BY created_at DESC
LIMIT 50;
```

출력에서 다음과 같은 차이를 발견할 수 있습니다.

```text
Index Scan using idx_orders_tenant_status_created
  (cost=0.42..18.90 rows=10 width=32)
  (actual time=0.20..840.00 rows=50 loops=1)
  Buffers: shared hit=120 read=18500
```

`LIMIT 50` 때문에 최종 결과는 50개이지만, 내부적으로 많은 페이지를 읽을 수 있습니다. 숫자 차이 자체보다 조인·상위 노드에서 오차가 증폭되는지, `loops`와 `Buffers`의 디스크 read가 커지는지 확인해야 합니다. Nested Loop 안쪽 노드는 바깥 행마다 반복될 수 있습니다.

## 왜 planner의 예상이 틀리는가

PostgreSQL은 테이블 전체를 매번 세어 보지 않고 `ANALYZE`가 만든 통계 샘플을 사용합니다. 통계는 최신이어도 근사치이며, 대량 적재나 특정 값의 급격한 증가 뒤에는 실제 분포를 충분히 설명하지 못할 수 있습니다. `status = 'PENDING'`인 행이 전체의 1%라고 예상했지만 특정 tenant에는 80%가 몰려 있다면, 전체 통계만으로는 tenant별 결과를 정확히 예상하기 어렵습니다.
여러 조건의 컬럼이 연관되어 있을 때도 문제가 생깁니다. planner가 `tenant_id = 42`와 `status = 'PENDING'`를 독립적인 조건으로 보고 선택도를 곱하면 결과 행 수를 지나치게 작게 계산할 수 있습니다. 그 결과 작은 결과를 기대한 계획이 실제로는 많은 행과 페이지를 처리합니다.

## 원인을 좁히는 순서

첫째, 실제 운영 데이터와 비슷한 조건으로 `EXPLAIN (ANALYZE, BUFFERS)`를 실행합니다. `ANALYZE`는 쿼리를 실행하므로 `UPDATE`, `DELETE`는 트랜잭션 안에서 실행하고 롤백해야 합니다.

둘째, 가장 큰 오차가 시작되는 plan node를 찾습니다. 상위 노드의 `rows`만 보지 말고 아래쪽 scan, filter, join의 estimated rows와 actual rows를 위에서 아래로 비교합니다. `actual rows`는 `loops`당 평균값일 수 있으므로 반복 노드라면 `actual rows × loops` 관점으로 읽어야 합니다.

셋째, `Buffers: shared hit`와 `shared read`를 봅니다. hit가 많다고 쿼리가 싼 것은 아니며, read가 크면 디스크 I/O를 의심합니다. 실행 시간과 버퍼 수를 함께 기록해야 인덱스가 실제 읽은 페이지를 줄였는지 판단할 수 있습니다.

넷째, 통계를 갱신한 뒤 계획이 달라지는지 확인합니다.

```sql
ANALYZE orders;

SELECT attname, n_distinct, most_common_vals, histogram_bounds
FROM pg_stats
WHERE tablename = 'orders'
  AND attname IN ('tenant_id', 'status');
```

갱신 후에도 특정 컬럼 조합의 예상이 계속 틀리면 다변량 통계를 검토할 수 있습니다.

```sql
CREATE STATISTICS orders_tenant_status_stats (dependencies, mcv)
ON tenant_id, status
FROM orders;

ANALYZE orders;
```

이 설정은 모든 컬럼 조합에 추가하지 않습니다. 함께 자주 사용되는 조건에서 예상 행 수 오류가 계획을 망칠 때만 후보로 삼습니다. 통계 수집과 계획 계산 비용이 늘 수 있습니다.

## 흔한 잘못된 해결

첫 번째는 `enable_seqscan = off` 같은 설정으로 인덱스 사용을 강제하는 것입니다. 진단 중 비교에는 쓸 수 있지만 운영 기본값으로 두면 planner의 판단을 가립니다. 인덱스 사용 여부보다 실제 rows, 실행 시간, 버퍼 읽기가 줄었는지가 중요합니다.

두 번째는 한 번의 `EXPLAIN ANALYZE`만 보고 결론을 내리는 것입니다. 캐시 상태, 파라미터 값, 동시 실행, 테이블 변경량에 따라 결과가 달라질 수 있으므로 느린 값과 빠른 값을 각각 재현해야 합니다.

## 운영에서 볼 지표와 적용 기준

다음 조건이면 estimated rows 불일치를 우선 조사할 가치가 있습니다.

- 인덱스는 사용되지만 `shared read`와 p95가 함께 증가합니다.
- 특정 tenant, 상태, 날짜 범위에서만 계획이 크게 달라집니다.
- Nested Loop의 내부 노드에 큰 `loops` 값이 보입니다.
- `ANALYZE` 이후 계획과 실행 시간이 눈에 띄게 바뀝니다.

운영에서는 `pg_stat_statements`의 평균 시간만 보지 말고 호출 횟수, total time, rows와 계획 변경 시점을 함께 확인합니다. 대량 적재 이후 느려졌다면 통계 갱신과 값 분포 변화도 연결해서 봅니다.

정리하면 다음과 같습니다.

- 인덱스 존재 여부보다 planner가 예상한 행 수와 실제 행 수의 차이가 먼저입니다.
- `EXPLAIN ANALYZE`의 `loops`와 `BUFFERS`까지 봐야 반복 비용과 I/O를 알 수 있습니다.
- 통계 갱신 후에도 컬럼 조합의 상관관계가 문제라면 다변량 통계를 검토합니다.
- 강제 설정이나 인덱스 추가보다 실제 운영 조건에서 계획을 재현하고 순서대로 원인을 좁히는 편이 안전합니다.

## 참고한 공식 문서

- [PostgreSQL 18 - Using EXPLAIN](https://www.postgresql.org/docs/current/using-explain.html)
- [PostgreSQL 18 - Statistics Used by the Planner](https://www.postgresql.org/docs/current/planner-stats.html)
- [PostgreSQL 18 - CREATE STATISTICS](https://www.postgresql.org/docs/current/sql-createstatistics.html)
