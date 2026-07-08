---
title: "OpenTelemetry tail sampling을 켜면 느린 요청을 더 잘 보지만 Collector 메모리부터 설계해야 하는 이유"
date: 2026-07-08 08:57:00 +0900
tags: [Observability, OpenTelemetry, Backend]
excerpt: "Tail sampling은 요청이 끝난 뒤 trace 전체를 보고 샘플링할 수 있어 오류와 느린 요청을 남기기 좋지만, decision_wait 동안 span을 Collector에 보관해야 하므로 메모리와 라우팅 설계가 먼저 필요합니다."
---

## 문제 상황

분산 추적을 처음 붙이면 모든 trace를 저장하고 싶어진다. 하지만 트래픽이 늘면 저장 비용과 조회 비용이 빠르게 커진다. 그래서 많은 팀이 head sampling을 적용한다. head sampling은 요청이 시스템에 들어오는 초기에 "이 trace를 남길지 말지"를 결정하는 방식이다.

문제는 중요한 요청이 초기에 평범해 보인다는 점이다. 주문 API가 처음 들어올 때는 성공할지, 2초 이상 걸릴지, downstream timeout을 만날지 아직 모른다. 1% head sampling을 걸어두면 대부분의 요청 비용은 줄일 수 있지만, 정작 장애 시간대의 느린 요청과 오류 trace를 놓칠 수 있다.

Tail sampling은 이 문제를 다른 방식으로 푼다. trace가 어느 정도 모인 뒤, latency, status code, span attribute 같은 조건을 보고 저장 여부를 결정한다. 예를 들어 정상 200ms 요청은 대부분 버리고, 5초 이상 걸린 요청이나 오류가 포함된 요청은 남길 수 있다. 대신 Collector가 결정 전까지 trace 데이터를 들고 있어야 한다.

## 핵심 개념

OpenTelemetry Collector의 tail sampling processor는 같은 trace id의 span을 모아 정책을 평가한다. 공식 README는 효과적인 샘플링 결정을 위해 특정 trace의 모든 span이 같은 Collector 인스턴스로 들어와야 한다고 설명한다. 여러 Collector로 span이 흩어지면 한 Collector는 trace의 일부만 보고 잘못된 결정을 할 수 있다.

핵심 설정은 `decision_wait`, `num_traces`, `expected_new_traces_per_sec`, 그리고 policies다. `decision_wait`는 trace를 얼마나 기다린 뒤 결정을 내릴지에 가깝다. 너무 짧으면 늦게 도착한 span을 못 보고, 너무 길면 메모리 사용량과 export 지연이 커진다. `num_traces`는 메모리에 보관할 trace 수의 상한을 정하는 설정이다.

정책은 단순 확률보다 운영 판단에 가까워야 한다. 오류 status code, 일정 시간 이상의 latency, 특정 endpoint, 특정 tenant, 고가치 거래 같은 기준을 조합할 수 있다. 모든 요청을 조금씩 보는 전략보다 "문제가 되는 요청을 확실히 남기는 전략"이 tail sampling의 장점이다.

## 설정으로 보기

다음 예시는 오류 trace, 2초 이상 걸린 trace, 결제 API 일부를 남기는 구성이다.

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 50000
    expected_new_traces_per_sec: 1000
    decision_cache:
      sampled_cache_size: 100000
      non_sampled_cache_size: 100000
    policies:
      [
        {
          name: errors,
          type: status_code,
          status_code: { status_codes: [ERROR] }
        },
        {
          name: slow-requests,
          type: latency,
          latency: { threshold_ms: 2000 }
        },
        {
          name: payment-sample,
          type: string_attribute,
          string_attribute: {
            key: http.route,
            values: ["/api/payments"],
            enabled_regex_matching: false
          }
        }
      ]

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [k8sattributes, tail_sampling, batch]
      exporters: [otlp]
```

processor 순서도 중요하다. tail sampling 전에 `k8sattributes`처럼 context를 활용하는 processor를 배치해야 한다. tail sampling이 span을 다시 묶어 내보내면서 원래 context가 사라질 수 있기 때문이다. 반대로 batch는 보통 sampling 뒤에 두어 저장하기로 결정된 trace만 묶어 보내는 편이 이해하기 쉽다.

## 자주 하는 실수

첫 번째 실수는 Collector를 단순 round-robin으로 늘리는 것이다. 같은 trace의 span이 Collector A와 B로 나뉘면 latency 정책이나 error 정책이 부분 정보만 보고 판단한다. tail sampling을 제대로 쓰려면 trace id 기준으로 같은 Collector에 라우팅하거나, 앞단에서 trace 단위로 묶이는 구조를 설계해야 한다.

두 번째 실수는 `decision_wait`를 무작정 크게 잡는 것이다. 긴 요청을 더 잘 잡고 싶다는 이유로 60초, 120초를 주면 Collector는 그 시간 동안 훨씬 많은 trace를 메모리에 들고 있어야 한다. 트래픽이 초당 1,000 trace이고 `decision_wait`가 30초라면, 단순 계산으로도 결정 대기 중인 trace가 수만 개가 된다. span 수가 많은 서비스라면 메모리 압박이 먼저 온다.

세 번째 실수는 tail sampling을 비용 절감 장치로만 보는 것이다. tail sampling은 저장량을 줄일 수 있지만, Collector 내부에서는 일단 span을 받아 보관하고 평가한다. 애플리케이션에서 Collector까지의 네트워크, Collector CPU, 메모리 비용은 여전히 발생한다. 저장소 비용만 줄고 수집 계층 병목이 남을 수 있다.

## 언제 쓰면 좋은가

Tail sampling은 "오류와 느린 요청을 놓치면 안 되지만 모든 trace를 저장하기는 비싼 상황"에 잘 맞는다. 장애 분석, 결제나 주문 같은 핵심 경로, 특정 고객군의 문제 재현, p99 지연 분석이 대표적이다. head sampling으로는 사후 정보가 필요한 조건을 잡기 어렵기 때문이다.

반대로 초저지연 수집이 중요하거나 Collector 메모리 여유가 작거나, trace id 기준 라우팅을 보장하기 어려운 환경에서는 조심해야 한다. 이 경우에는 head sampling과 tail sampling을 섞거나, 특정 서비스와 endpoint에만 tail sampling을 적용하는 방식이 낫다. 모든 서비스의 모든 trace에 tail sampling을 한 번에 켜는 것은 운영 리스크가 크다.

실무 판단 기준은 "샘플링 결정에 요청 결과가 필요한가"다. 오류 여부, 최종 latency, downstream 실패 여부가 결정 기준이면 tail sampling이 맞다. 단순 비용 절감이 목적이고 어떤 요청이든 균등하게 일부만 보면 된다면 head sampling이 더 단순하다.

## 운영에서 볼 것

운영 지표는 저장된 trace 수보다 Collector 상태를 먼저 봐야 한다. Collector RSS 메모리, CPU, processor queue 길이, dropped span 수, export 실패 수, sampling decision 수를 확인한다. `num_traces`에 가까워지는지, late span이 늘어나는지, 특정 정책이 지나치게 많은 trace를 sample하는지도 봐야 한다.

로그와 메트릭은 정책별로 나누어 보는 편이 좋다.

```text
tail_sampling.policy=errors sampled=120 dropped=0
tail_sampling.policy=slow-requests sampled=85 threshold_ms=2000
collector.memory.rss=1.8GiB num_traces=50000 decision_wait=10s
```

장애 때는 세 가지를 빠르게 확인한다. 첫째, 모든 span이 같은 Collector로 모이는지 확인한다. 둘째, `decision_wait`보다 늦게 도착하는 span이 많은지 본다. 셋째, tail sampling processor 앞뒤의 processor 순서가 의도와 맞는지 확인한다. 이 세 가지가 틀어지면 trace가 저장되어도 일부 span이 빠진 불완전한 그림이 될 수 있다.

## 정리

Tail sampling은 느린 요청과 오류 trace를 더 잘 남기기 위한 강력한 방법이다. 하지만 결정 전까지 trace를 Collector 메모리에 보관하고, 같은 trace의 span을 같은 Collector로 모아야 한다. `decision_wait`와 `num_traces`는 비용과 정확도의 타협점이며, 정책은 "무엇을 반드시 보고 싶은가"를 기준으로 설계해야 한다.

참고한 공식 문서:

- [OpenTelemetry Collector Contrib - Tail Sampling Processor](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor)
- [OpenTelemetry Docs - Transforming telemetry](https://opentelemetry.io/docs/collector/transforming-telemetry/)
