---
title: "PostgreSQL autovacuum가 큰 테이블에서 늦게 따라오는 이유와 조정 기준"
date: 2026-06-30 08:59:00 +0900
tags: [PostgreSQL, Database, Backend]
excerpt: "PostgreSQL autovacuum는 켜져 있기만 하면 끝나는 기능이 아니라, 큰 테이블에서는 기본 threshold와 scale factor 때문에 너무 늦게 반응할 수 있습니다."
---

## 문제 상황

운영 중인 PostgreSQL에서 테이블 크기가 계속 늘고, 인덱스 효율이 떨어지고, 특정 쿼리만 갑자기 느려졌는데도 "autovacuum는 켜져 있다"는 답만 돌아오는 경우가 있습니다. 설정이 켜져 있으면 자동으로 잘 관리될 것 같지만, 실제로는 갱신량이 큰 테이블이나 파티션 구조, 특정 업데이트 패턴에서는 autovacuum가 늦게 반응할 수 있습니다.

이때 흔한 오해는 두 가지입니다. 첫째, autovacuum가 켜져 있으면 테이블 bloat가 저절로 줄어든다고 생각하는 것입니다. 둘째, 느려졌으니 바로 `VACUUM FULL`을 해야 한다고 생각하는 것입니다. PostgreSQL 공식 문서는 일반적인 목표가 자주 실행되는 표준 `VACUUM`으로 steady state를 유지하는 것이라고 설명하고, `VACUUM FULL`은 `ACCESS EXCLUSIVE` 락이 필요하므로 가능한 피하라고 권장합니다.

실무에서 더 중요한 질문은 "왜 이 테이블은 autovacuum가 늦게 잡는가"입니다. 많은 경우 원인은 autovacuum 자체가 꺼져서가 아니라, 테이블 크기와 변경량 대비 기본 기준이 너무 느슨해서 트리거가 늦게 걸리는 데 있습니다.

## 핵심 개념

PostgreSQL 공식 문서에 따르면 autovacuum의 기본 `autovacuum_vacuum_threshold`는 50이고, `autovacuum_vacuum_scale_factor`는 0.2입니다. 의미를 풀면, 테이블에서 업데이트되거나 삭제된 튜플 수가 "기본값 + 테이블 크기의 20%" 수준에 도달해야 vacuum 대상이 됩니다. 작은 테이블에서는 충분히 빠를 수 있지만, 수천만 행 테이블에서는 20% 자체가 너무 큽니다.

예를 들어 5천만 행 테이블이라면 기본 계산만으로도 대략 천만 행 규모의 변경이 쌓여야 autovacuum가 적극적으로 반응할 수 있습니다. 이 시점이면 dead tuple이 이미 많이 누적되어 인덱스 효율, 디스크 사용량, 쿼리 계획 품질에 영향을 줄 수 있습니다. 여기서 "기본값이면 적당하겠지"라고 생각하면 늦습니다.

PostgreSQL 공식 문서는 vacuum의 목적을 네 가지로 설명합니다. dead tuple 공간 재사용, planner statistics 갱신, visibility map 갱신, 그리고 transaction ID wraparound 방지입니다. 즉 autovacuum는 단지 용량 정리 작업이 아니라, 실행 계획과 장기 안정성까지 연결된 유지보수 작업입니다.

또 하나 중요한 점은 autovacuum를 꺼도 wraparound 방지를 위한 vacuum은 강제로 돌 수 있다는 사실입니다. 문서는 `autovacuum`이 비활성화되어도 transaction ID wraparound를 막기 위한 autovacuum 프로세스는 필요 시 실행된다고 설명합니다. 그래서 "시끄러우니 끄자"는 접근은 대개 문제를 숨길 뿐 해결하지 못합니다.

## 코드로 보기

운영에서 먼저 볼 만한 쿼리는 `pg_stat_user_tables` 기준 통계입니다.

```sql
select
  relname,
  n_live_tup,
  n_dead_tup,
  last_autovacuum,
  last_autoanalyze,
  vacuum_count,
  autovacuum_count
from pg_stat_user_tables
order by n_dead_tup desc
limit 20;
```

특정 대형 테이블이 dead tuple을 빠르게 쌓는다면 per-table storage parameter로 기준을 낮출 수 있습니다.

```sql
alter table orders
set (
  autovacuum_vacuum_scale_factor = 0.02,
  autovacuum_analyze_scale_factor = 0.01,
  autovacuum_vacuum_threshold = 1000
);
```

핵심은 모든 테이블에 같은 값을 넣는 것이 아니라, 변경이 많은 큰 테이블만 따로 다루는 것입니다. PostgreSQL 문서도 많은 autovacuum 설정이 per-table override 가능하다고 설명합니다.

## 자주 하는 실수

첫 번째 실수는 dead tuple이 많아졌다고 바로 `VACUUM FULL`부터 실행하는 것입니다. 공식 문서에 따르면 `VACUUM FULL`은 더 많은 공간을 회수할 수 있지만 훨씬 느리고 `ACCESS EXCLUSIVE` 락이 필요합니다. 운영 트래픽이 있는 테이블에서는 장애를 더 키울 수 있습니다.

두 번째 실수는 큰 테이블과 작은 테이블에 같은 scale factor를 적용하는 것입니다. 20%는 작은 테이블에는 무난할 수 있어도, 대형 주문 테이블이나 이벤트 로그 테이블에는 너무 늦습니다.

세 번째 실수는 vacuum만 보고 analyze를 잊는 것입니다. PostgreSQL 문서는 planner statistics가 부정확하면 나쁜 실행 계획이 성능을 떨어뜨릴 수 있다고 설명합니다. dead tuple은 줄었는데도 쿼리가 느리다면 `last_autoanalyze`와 통계 갱신 주기를 함께 봐야 합니다.

## 언제 쓰면 좋은가

autovacuum 조정을 적극적으로 해야 하는 경우는 업데이트/삭제가 꾸준히 발생하는 대형 테이블, 배치로 한꺼번에 상태를 바꾸는 테이블, 인덱스 스캔 성능이 갑자기 흔들리는 테이블입니다. 이런 곳은 global 기본값만으로 관리하기보다 테이블 단위 기준을 별도로 잡는 편이 안전합니다.

반대로 데이터가 거의 append-only이고 수정이 드문 테이블은 기본값으로도 충분할 수 있습니다. 중요한 것은 "모든 테이블을 세게 돌리자"가 아니라 "변경 패턴이 다른 테이블을 같은 규칙으로 보지 말자"입니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "dead tuple이 의미 있게 쌓이는데 last_autovacuum가 기대보다 늦다면, 전체 서버보다 그 테이블의 scale factor부터 의심한다." 이 순서가 대체로 비용 대비 효과가 좋습니다.

## 운영에서 볼 것

- `pg_stat_user_tables.n_dead_tup`
- `last_autovacuum`, `last_autoanalyze`
- 특정 테이블 크기 증가 속도
- index-only scan 비율 변화와 heap fetch 증가
- wraparound 경고 로그 여부

가능하면 아래 질문으로 묶어서 보는 편이 좋습니다.

- dead tuple이 쌓이는 속도보다 autovacuum가 느린가
- analyze가 늦어서 실행 계획이 흔들리는가
- 특정 테이블만 유독 느린가, 아니면 전체 DB 설정 문제인가

이렇게 봐야 "PostgreSQL이 느리다"가 아니라 "어느 테이블의 유지보수 기준이 workload와 안 맞는가"로 문제를 좁힐 수 있습니다.

## 정리

PostgreSQL autovacuum는 켜져 있기만 하면 충분한 기능이 아닙니다. 큰 테이블에서는 기본 threshold와 scale factor 때문에 vacuum과 analyze가 너무 늦게 실행될 수 있습니다. 운영에서는 `VACUUM FULL`부터 떠올리기보다 dead tuple, analyze 시점, 테이블별 workload를 보고 per-table 기준을 조정하는 편이 더 안전합니다.

## 참고한 공식 문서

- PostgreSQL Routine Vacuuming: https://www.postgresql.org/docs/current/routine-vacuuming.html
- PostgreSQL Vacuuming Configuration: https://www.postgresql.org/docs/current/runtime-config-vacuum.html
