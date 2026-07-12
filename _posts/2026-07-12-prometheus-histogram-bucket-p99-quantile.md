---
title: "Prometheus histogram bucket을 대충 잡으면 p99가 현실과 어긋나는 이유"
date: 2026-07-12 08:51:00 +0900
tags: [Observability, Prometheus, Performance, Backend]
excerpt: "Prometheus classic histogram의 p99는 원본 요청 시간을 그대로 읽는 값이 아니라 bucket 경계에서 계산한 추정치입니다. SLO 주변의 bucket을 촘촘히 설계하고 집계 범위·트래픽 양·histogram 유형을 함께 확인해야 지연 시간 대시보드를 올바르게 해석할 수 있습니다."
---

## 문제 상황

API 대시보드에는 p99 응답 시간이 1.2초라고 나오는데, 장애 당시 trace를 몇 개 열어 보면 1.8초 이상 걸린 요청이 많다. 반대로 애플리케이션 로그에는 300ms를 넘은 요청이 거의 없는데 Prometheus p99는 500ms를 가리키기도 한다. 어느 쪽이 틀린 것인지부터 논쟁이 시작된다.

이때 histogram을 단순히 “응답 시간을 저장하는 메트릭”으로 이해하면 원인을 찾기 어렵다. classic histogram은 모든 요청의 원본 시간을 저장하지 않고, 미리 정한 구간(bucket)에 관측값이 몇 개 들어왔는지를 누적한다. Prometheus는 이 구간 정보로 quantile을 계산하므로 bucket 경계를 어떻게 정했는지가 결과의 정확도를 결정한다.

p99를 더 자주 보이게 만드는 것이 목적이 아니라, “우리 서비스가 정한 SLO 주변에서 얼마나 정확하게 판단할 수 있는가”가 설계 기준이어야 한다.

## 핵심 개념

classic histogram은 보통 다음과 같은 시계열을 만든다.

```text
http_request_duration_seconds_bucket{le="0.1"}  1200
http_request_duration_seconds_bucket{le="0.3"}  9800
http_request_duration_seconds_bucket{le="0.5"}  15000
http_request_duration_seconds_bucket{le="1"}    19800
http_request_duration_seconds_bucket{le="+Inf"} 20000
http_request_duration_seconds_sum                 4300
http_request_duration_seconds_count               20000
```

`_bucket` 값은 각 경계 이하에 들어온 관측값의 누적 개수다. `_count`는 전체 관측 수이고 `_sum`은 관측값의 합이다. Prometheus에서는 counter인 bucket을 시간 구간의 `rate()`로 바꾼 뒤 `histogram_quantile()`을 사용해 p95나 p99를 계산한다.

```promql
histogram_quantile(
  0.99,
  sum by (le) (
    rate(http_request_duration_seconds_bucket{job="checkout-api"}[5m])
  )
)
```

이 식의 핵심은 `le`다. classic histogram의 bucket을 서비스 전체로 합치려면 경계 정보를 유지한 채 `sum by (le)`를 해야 한다. 경로별 p99가 필요하면 `sum by (le, route)`처럼 필요한 집계 차원을 남긴다. `le`를 빼고 합치면 quantile을 계산할 bucket 구조가 사라진다.

## bucket 경계가 오차를 만든다

예를 들어 bucket이 `0.1, 0.3, 0.5, 1, 2, 5`초뿐이라고 하자. p99에 해당하는 관측값이 1초와 2초 사이에 있으면 Prometheus는 그 구간 내부의 분포를 추정한다. 실제 요청이 대부분 1.05초에 몰려 있어도, 구간이 넓으면 결과는 1.2초나 1.8초처럼 경계 사이의 값으로 계산될 수 있다.

따라서 SLO가 300ms라면 300ms 주변에 판단에 필요한 경계를 둬야 한다. 예를 들면 `0.1, 0.2, 0.25, 0.3, 0.35, 0.5, 1, 2`처럼 SLO 전후를 촘촘히 나누는 방식이다. 전체 범위를 같은 간격으로 잘게 자르는 것보다, 장애 판단이 필요한 구간에 bucket을 배치하는 편이 비용 대비 효과가 좋다.

다만 bucket을 추가하면 모든 label 조합마다 시계열 수가 늘어난다. route, method, status, tenant 같은 label이 많다면 경계 하나를 추가하는 비용도 커진다. 정확도를 높이기 위해 무조건 bucket을 늘리기보다, 실제로 대시보드와 알림이 사용하는 SLO 경계를 먼저 정해야 한다.

Prometheus 공식 문서는 classic histogram 외에 native histogram도 설명하며, 가능하다면 native histogram을 우선하는 방향을 안내한다. native histogram은 classic histogram처럼 애플리케이션이 모든 경계를 미리 고르는 부담을 줄일 수 있지만, 클라이언트 라이브러리·수집 경로·저장소가 지원하는지 확인해야 한다. 기존 시스템이 classic histogram이라면 먼저 bucket 설계와 PromQL을 바로잡는 것이 현실적인 순서다.

## 자주 하는 실수

첫 번째 실수는 p99를 원본 요청 하나의 정확한 값으로 보는 것이다. histogram quantile은 bucket 안의 분포를 추정한 값이다. bucket이 넓거나 트래픽이 적으면 결과가 실제 개별 trace와 크게 달라질 수 있다.

두 번째 실수는 애플리케이션마다 다른 bucket 경계를 만들어 놓고 전체 서비스 p99를 합치는 것이다. classic histogram을 합산하려면 같은 의미의 bucket 경계를 사용해야 한다. 서비스 A가 `0.1, 0.3, 1`을 쓰고 서비스 B가 `0.2, 0.5, 2`를 쓰면 단순히 합쳐도 일관된 분포가 되지 않는다.

세 번째 실수는 5분 p99와 하루 trace의 최댓값을 비교하는 것이다. PromQL의 `rate(...[5m])`는 최근 5분의 관측을 사용한다. 로그·trace·대시보드가 같은 시간 범위와 같은 endpoint 필터를 쓰는지 확인해야 한다.

네 번째 실수는 요청 수가 적은데 p99 알림을 너무 민감하게 설정하는 것이다. 1분 동안 요청이 몇 개뿐이면 한 건의 느린 요청이 quantile을 크게 움직인다. p99와 함께 `rate(..._count[5m])`로 관측량을 확인하고, 트래픽이 적은 구간에는 p95·평균·최대 또는 synthetic check를 보조 지표로 사용할 수 있다.

다섯 번째 실수는 bucket과 일반 gauge를 혼동하는 것이다. `_bucket`, `_count`, `_sum`은 관측 누적을 나타내므로 보통 `rate()`나 `increase()`를 적용한다. 현재 누적 숫자만 보고 “지금 1초를 넘은 요청이 몇 건인가”라고 해석하면 시간 범위가 빠진다.

## 언제 쓰면 좋은가

histogram은 서비스 전체나 여러 인스턴스의 응답 시간을 집계하고, p95·p99·SLO 달성률을 대시보드와 알림으로 만들 때 적합하다. bucket 데이터는 Prometheus 서버에서 quantile을 계산하므로, 나중에 p90에서 p99로 관심 구간을 바꾸거나 여러 인스턴스를 합칠 수 있다.

반대로 집계가 필요 없고 instrumentation 단계에서 정한 특정 quantile만 보면 되는 경우에는 summary가 선택지가 될 수 있다. 하지만 summary의 quantile은 인스턴스 간에 단순히 합칠 수 없다는 제약이 있다. 여러 Pod를 하나의 서비스 p99로 보고 싶다면 histogram 또는 지원되는 native histogram을 우선 검토한다.

실무 판단 기준은 두 가지다. 첫째, 알림의 기준이 되는 SLO 경계 주변에서 충분한 해상도가 있는가. 둘째, 모든 label과 bucket을 곱했을 때 저장·쿼리 비용을 감당할 수 있는가. 두 답이 모두 “예”일 때만 bucket을 늘린다.

## 운영에서 볼 것

대시보드에는 p99 하나만 두지 말고 다음을 함께 배치한다.

- p50, p95, p99 응답 시간
- `http_request_duration_seconds_count`의 초당 관측 수
- 상태 코드별 error rate
- SLO 경계 이하와 초과 bucket의 비율
- route별 시계열 수와 Prometheus query 실행 시간

알림이 발생하면 먼저 query의 집계 범위를 확인한다. `sum by (le)`가 서비스 전체를 합치는지, `route` label이 의도치 않게 남아 시계열이 쪼개지는지, `rate` 윈도우가 트래픽 변화에 맞는지 본다. 그 다음 bucket별 증가량을 그려 p99가 어느 경계 사이에서 계산되는지 확인하면 “실제로 느려진 것”과 “경계가 거친 것”을 구분할 수 있다.

bucket 설계를 바꿀 때는 기존 시계열과 새 시계열이 한 대시보드에서 섞이지 않게 recording rule과 배포 시점을 계획해야 한다. 경계가 바뀌면 같은 이름의 메트릭이라도 과거와 현재의 해상도가 달라진다. SLO 알림이 새 bucket을 기다리는 동안 빈 값이 되지 않는지도 확인해야 한다.

## 정리

Prometheus classic histogram의 p99는 원본 요청 시간을 그대로 읽은 값이 아니라 bucket 분포에서 계산한 추정치다.
SLO 주변에 적절한 경계를 두고 `rate()`와 `histogram_quantile()`을 올바른 집계 차원으로 사용해야 한다.
여러 인스턴스를 합칠 때는 같은 bucket 경계를 유지하고, 낮은 트래픽에서는 quantile의 흔들림을 함께 봐야 한다.
새 시스템에서는 native histogram 지원 여부도 확인하되, 기존 classic histogram의 설계를 먼저 점검하자.

## 참고한 공식 문서

- [Prometheus: Histograms and summaries](https://prometheus.io/docs/practices/histograms/)
- [Prometheus: Metric types](https://prometheus.io/docs/concepts/metric_types/)
- [Prometheus: histogram_quantile()](https://prometheus.io/docs/prometheus/latest/querying/functions/#histogram_quantile)
