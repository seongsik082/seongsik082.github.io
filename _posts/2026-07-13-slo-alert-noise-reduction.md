---
title: "SLO 알림이 너무 시끄러울 때 줄여야 하는 노이즈"
date: 2026-07-13 08:52:00 +0900
tags: [Observability, SLO, Prometheus, Operations, Backend]
excerpt: "SLO 알림은 가능한 모든 원인을 잡는 규칙이 아니라 사용자가 겪는 나쁜 이벤트가 error budget을 얼마나 빠르게 소모하는지 알려주는 신호여야 합니다. burn rate와 여러 시간 창, 낮은 트래픽 예외를 함께 설계하면 page 노이즈를 줄이면서 중요한 장애를 놓치지 않을 수 있습니다."
---

## 문제 상황

온콜 채널에 알림이 너무 많이 옵니다. 특정 Pod의 CPU가 잠깐 높아졌다는 알림, DB connection pool이 80% 찼다는 알림, API 5xx가 늘었다는 알림이 거의 동시에 들어옵니다. 실제로는 사용자가 실패한 요청을 거의 경험하지 않았는데도 여러 명이 같은 원인을 확인합니다. 반대로 짧은 오류 폭주가 지나간 뒤에는 긴 시간 동안 아무 알림도 오지 않아, 이미 error budget을 많이 쓴 사실을 늦게 알게 됩니다.

알림 노이즈를 줄이기 위해 임계값을 높이거나 모든 규칙에 `for: 10m`을 붙이는 방식은 빠른 장애를 놓칠 수 있습니다. 핵심은 알림이 무엇을 감지해야 하는지를 먼저 정하는 것입니다. Prometheus 공식 가이드도 원인 목록을 모두 page하는 대신 최종 사용자의 증상에 가까운 신호를 알리고, 페이지가 왔을 때 실제로 사람이 할 일이 있어야 한다고 권장합니다.

## SLO, error budget, burn rate

SLO는 일정 기간 동안 좋은 이벤트가 차지해야 하는 비율입니다. 예를 들어 “30일 동안 성공적인 API 요청 비율 99.9%”를 정하면 허용되는 나쁜 요청 비율, 즉 error budget은 0.1%입니다. 100만 건의 요청을 기준으로 보면 약 1,000건의 bad event를 허용하는 셈입니다.

burn rate는 관측된 bad event 비율이 허용 비율보다 몇 배 빠른지를 나타냅니다.

```text
burn rate = 관측된 error ratio / (1 - SLO)
```

99.9% SLO에서 error ratio가 0.1%면 burn rate는 1입니다. 이 속도가 30일 내내 유지되면 기간이 끝날 때 budget을 모두 사용합니다. error ratio가 1%라면 burn rate는 10이고, 같은 속도가 지속되면 약 3일 안에 budget을 소모합니다. 따라서 “5분 동안 1% 에러”처럼 원시 임계값만 보는 것보다 “이 속도가 계속되면 budget을 얼마나 빨리 태우는가”가 대응 우선순위를 정하는 데 더 유용합니다.

## `for` 하나로는 충분하지 않다

Prometheus alerting rule의 `for`는 조건이 일정 시간 계속 참일 때 firing으로 바꾸는 기능입니다. 순간적인 값 튐을 줄이는 데 유용하지만, 주기적으로 반복되는 짧은 오류나 긴 window의 평균에 묻히는 장애를 완전히 해결하지는 못합니다.

SLO 알림에서는 보통 긴 시간 창과 짧은 시간 창을 함께 봅니다. 긴 창은 실제로 의미 있는 budget을 썼는지 확인하고, 짧은 창은 지금도 문제가 지속되는지 확인합니다. 두 조건을 `and`로 묶으면 이미 끝난 짧은 장애가 긴 창에 남아 있다는 이유만으로 page하는 일을 줄일 수 있습니다.

## PromQL로 보기

먼저 애플리케이션이 전체 요청과 실패 요청을 counter로 내보낸다고 가정합니다. label은 `job`과 서비스에 의미 있는 낮은 cardinality 차원만 남기고, 사용자 id나 request id를 넣지 않습니다.

```yaml
groups:
- name: checkout-slo-recording
  rules:
  - record: job:checkout_error_ratio:rate5m
    expr: |
      sum(rate(http_requests_total{job="checkout",status=~"5.."}[5m]))
      /
      sum(rate(http_requests_total{job="checkout"}[5m]))
  - record: job:checkout_error_ratio:rate1h
    expr: |
      sum(rate(http_requests_total{job="checkout",status=~"5.."}[1h]))
      /
      sum(rate(http_requests_total{job="checkout"}[1h]))
```

99.9% SLO의 page 규칙을 간단히 표현하면 다음과 같습니다. Google SRE Workbook은 1시간·5분 창에서 14.4배, 6시간·30분 창에서 6배를 page 기준의 출발점으로 제시합니다. 아래 숫자는 모든 서비스에 그대로 복사하는 정답이 아니라, SLO 기간과 온콜 대응 시간을 기준으로 조정할 시작값입니다.

```yaml
- alert: CheckoutSLOBurnRatePage
  expr: |
    (
      job:checkout_error_ratio:rate1h > (14.4 * 0.001)
      and
      job:checkout_error_ratio:rate5m > (14.4 * 0.001)
    )
    or
    (
      job:checkout_error_ratio:rate6h > (6 * 0.001)
      and
      job:checkout_error_ratio:rate30m > (6 * 0.001)
    )
  labels:
    severity: page
    service: checkout
  annotations:
    summary: "checkout API is consuming error budget quickly"
    runbook_url: "https://runbooks.example.com/checkout/slo-burn"
```

낮은 속도로 오래 지속되는 문제는 page 대신 ticket으로 보낼 수 있습니다. 예를 들어 3일 창과 6시간 창에서 burn rate 1 이상을 확인하는 규칙은 “당장 잠을 깨울 장애”보다 “다음 업무 시간에 조치해야 할 budget 소모”에 가깝습니다. Alertmanager에서 page와 ticket을 severity로 분리하고, 같은 incident가 여러 규칙을 동시에 만족할 때는 상위 page가 하위 알림을 억제하도록 구성해야 합니다.

## 노이즈를 만드는 흔한 패턴

첫 번째는 원인과 증상을 동시에 page하는 것입니다. API의 사용자 visible error가 늘었는데 API, DB, connection pool, 특정 Pod의 알림을 모두 page하면 한 장애가 네 개의 호출로 변합니다. 하위 컴포넌트는 대시보드와 ticket으로 보내고, 사람이 즉시 개입해야 하는 기준은 서비스 SLO에 두는 편이 대체로 낫습니다. 단, 돈이 사라지거나 데이터가 유실되는 등 사용자 요청 실패율로 표현되지 않는 중요한 손실은 별도 page가 필요합니다.

두 번째는 모든 endpoint를 하나의 평균으로 합치는 것입니다. 트래픽이 많은 health check가 대부분의 분모를 차지하면 결제나 로그인 같은 핵심 경로의 실패가 묻힐 수 있습니다. 반대로 모든 `route`, `user`, `request_id`를 label로 보존하면 시계열과 알림 인스턴스가 폭발합니다. SLO를 업무 기능 단위로 나누고, route는 제한된 allowlist나 recording rule로 집계하는 판단이 필요합니다.

세 번째는 낮은 트래픽 서비스에 일반적인 burn rate 기준을 그대로 적용하는 것입니다. 한 시간에 요청이 10건뿐이면 1건 실패만으로 error ratio가 10%가 됩니다. synthetic traffic을 추가하거나 관련 서비스와 함께 집계하고, 업무 영향이 큰 이벤트에 별도 기준을 두는 방법을 검토해야 합니다. 긴 window만으로 page하거나 `keep_firing_for`로 실제 장애를 숨기지 않는지도 확인합니다.

## 언제 page하고 언제 ticket으로 보낼까

page는 다음 질문에 “예”일 때 남깁니다.

- 지금 사용자 영향이 진행 중인가?
- 이 속도가 유지되면 error budget이 수 시간 안에 크게 줄어드는가?
- 온콜 담당자가 지금 실행할 명확한 runbook이 있는가?
- 알림이 이미 발생한 상위 증상의 중복이 아닌가?

하나라도 답하기 어렵다면 page 대신 ticket이나 dashboard로 내려보냅니다. 다만 데이터 손실·보안 사고·금전 손실처럼 요청 성공률로 보이지 않는 위험은 SLO와 별도 보호 규칙으로 남겨야 합니다. 지난 2주간 실제 incident로 이어진 page 비율과 acknowledgement 시간을 확인해 조치가 없었던 규칙을 합치거나 ticket으로 이동하되, detection time이 나빠지지 않는지 함께 봅니다.

## 운영에서 볼 것

SLO 알림을 운영할 때는 firing 수 외에 다음을 함께 기록합니다.

- SLI의 good event와 total event, window별 error ratio
- 현재 burn rate와 예상 budget 소진 시간
- page·ticket별 발생 수, 중복 억제 수, 실제 incident 연결 비율
- 낮은 트래픽 구간의 요청 수와 synthetic check 결과
- Prometheus rule evaluation 지연·실패와 `ALERTS{alertstate="pending|firing"}` 시계열
- Alertmanager의 group wait, group interval, repeat interval, route별 수신 성공 여부

알림이 너무 자주 울리면 먼저 실제 SLI 계산식과 분모가 맞는지 확인합니다. 그 다음 짧은 창 조건이 빠졌는지, error ratio가 특정 route나 status를 잘못 포함하는지, 같은 장애를 여러 severity가 동시에 보내는지 살핍니다. 알림 자체가 오지 않을 때는 규칙 식보다 Prometheus scrape·recording rule·Alertmanager 전달 경로를 먼저 점검해야 합니다.

## 정리

SLO 알림은 모든 원인을 잡는 감시 목록이 아니라 사용자 영향과 error budget 소모를 알려주는 대응 신호다.
burn rate는 관측 error ratio를 허용 error ratio와 비교해, 장애가 얼마나 빨리 budget을 태우는지 표현한다.
긴 창으로 의미 있는 budget 소모를 확인하고 짧은 창으로 현재 지속성을 확인하면 page 노이즈와 늦은 감지를 함께 줄일 수 있다.
낮은 트래픽, 중복 알림, 높은 cardinality, 조치 없는 page 규칙은 별도 기준으로 재설계해야 한다.

## 참고한 공식 문서

- [Google SRE Workbook - Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [Prometheus Documentation - Alerting](https://prometheus.io/docs/practices/alerting/)
- [Prometheus Documentation - Alerting rules](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/)
