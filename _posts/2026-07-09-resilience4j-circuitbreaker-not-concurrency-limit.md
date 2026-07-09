---
title: "Circuit Breaker를 동시 실행 제한 장치로 쓰면 느린 외부 API 앞에서 큐가 먼저 터지는 이유"
date: 2026-07-09 08:56:00 +0900
tags: [Distributed Systems, Performance, Backend]
excerpt: "Resilience4j CircuitBreaker는 실패율과 느린 호출 비율을 보고 호출을 차단하는 장치지만, 동시에 실행되는 요청 수를 제한하지는 않습니다. 외부 API 보호에는 timeout, bulkhead, retry 정책을 함께 설계해야 합니다."
---

## 문제 상황

결제 승인 API가 가끔 5초 이상 늦어진다고 하자. 백엔드 팀은 장애 전파를 막으려고 Circuit Breaker를 붙였다. 실패가 늘면 회로가 열리고, 외부 API 호출을 바로 거절하니 전체 장애를 막을 수 있을 것처럼 보인다.

하지만 실제 장애에서는 애플리케이션 thread pool이 먼저 찬다. 외부 API가 느려진 순간 수십 개 요청이 동시에 결제 승인 호출에 들어가고, 각각 timeout까지 기다린다. Circuit Breaker는 아직 minimum call 수를 채우는 중이거나, failure rate 계산 전이라 CLOSED 상태일 수 있다. 그 사이 내부 worker thread와 HTTP connection pool이 고갈된다.

이때 "Circuit Breaker를 달았는데 왜 동시 호출이 줄지 않았지?"라는 질문이 나온다. 답은 단순하다. Circuit Breaker는 기본적으로 동시 실행 수 제한 장치가 아니다. 실패 결과를 기록하고 상태를 바꾸는 장치다. 동시에 몇 개의 호출이 외부 API로 나갈 수 있는지는 Bulkhead, connection pool, executor, timeout이 담당해야 한다.

## 핵심 개념

Resilience4j CircuitBreaker는 CLOSED, OPEN, HALF_OPEN 같은 상태를 가진다. CLOSED에서는 호출을 허용하면서 결과를 기록한다. 실패율이나 느린 호출 비율이 설정한 임계값 이상이 되면 OPEN으로 바뀌고, 이때부터는 실제 함수를 호출하지 않고 `CallNotPermittedException`으로 빠르게 거절한다. 일정 시간이 지나면 HALF_OPEN으로 일부 호출만 허용해 회복 여부를 본다.

중요한 부분은 sliding window다. CircuitBreaker는 최근 호출 결과를 count-based 또는 time-based window에 집계하고, failure rate와 slow call rate를 계산한다. 하지만 최소 호출 수가 쌓이기 전에는 비율을 계산하지 않는다. 예를 들어 `minimumNumberOfCalls=50`이면 처음 49개가 모두 실패해도 그 값만으로는 아직 OPEN 전환 조건을 판단하지 않을 수 있다.

또 하나의 경계는 동시성이다. Resilience4j 문서는 CircuitBreaker가 함수 호출 자체를 synchronized 블록 안에 넣지 않는다고 설명한다. 그래서 CLOSED 상태에서 100개 thread가 동시에 permission을 얻으면 100개 호출이 외부 API로 나갈 수 있다. sliding window size가 50이라고 해서 동시에 50개만 실행된다는 뜻이 아니다.

## 코드로 보기

다음 설정은 느린 호출을 빨리 감지하려는 의도는 있지만, 동시 실행 수를 제한하지 않는다.

```java
CircuitBreakerConfig config = CircuitBreakerConfig.custom()
    .failureRateThreshold(50)
    .slowCallRateThreshold(50)
    .slowCallDurationThreshold(Duration.ofSeconds(2))
    .minimumNumberOfCalls(20)
    .slidingWindowType(SlidingWindowType.TIME_BASED)
    .slidingWindowSize(10)
    .waitDurationInOpenState(Duration.ofSeconds(30))
    .permittedNumberOfCallsInHalfOpenState(5)
    .recordExceptions(IOException.class, TimeoutException.class)
    .build();
```

이 설정에서 외부 API가 10초씩 멈추면, 처음 들어온 요청들은 여전히 외부 API로 나간다. slow call로 기록되는 시점은 호출이 끝난 뒤다. 즉 느린 호출이 아직 진행 중인 동안에는 결과가 window에 충분히 쌓이지 않았을 수 있다.

동시 호출 수를 제한하려면 Bulkhead를 같이 둔다.

```java
BulkheadConfig bulkheadConfig = BulkheadConfig.custom()
    .maxConcurrentCalls(20)
    .maxWaitDuration(Duration.ofMillis(100))
    .build();

Supplier<PaymentResult> guarded = CircuitBreaker
    .decorateSupplier(circuitBreaker, () -> paymentClient.approve(command));

Supplier<PaymentResult> limited = Bulkhead
    .decorateSupplier(bulkhead, guarded);
```

실무에서는 여기에 HTTP client timeout도 반드시 들어가야 한다. CircuitBreaker는 오래 걸리는 호출을 관찰할 수 있지만, timeout 자체를 대신 걸어주지는 않는다. timeout이 너무 길면 slow call rate가 열리기 전에 thread가 오래 묶인다.

## 자주 하는 실수

첫 번째 실수는 failure rate만 보고 timeout을 길게 두는 것이다. 외부 API가 실패 응답을 빠르게 주는 장애보다, 응답을 주지 않고 느려지는 장애가 더 자주 thread 고갈을 만든다. 이 경우 slow call threshold와 client timeout이 failure rate만큼 중요하다.

두 번째 실수는 HALF_OPEN을 회복 확인 단계가 아니라 대기열 해제 단계처럼 쓰는 것이다. OPEN 뒤에 모든 요청을 HALF_OPEN에서 한꺼번에 흘려보내면 외부 시스템이 다시 눌릴 수 있다. `permittedNumberOfCallsInHalfOpenState`는 작게 시작하고, 실패 시 다시 OPEN으로 돌아가는 흐름을 명확히 해야 한다.

세 번째 실수는 모든 예외를 실패로 기록하는 것이다. 사용자의 잔액 부족, 유효하지 않은 요청, 권한 없음 같은 비즈니스 실패는 외부 시스템 장애가 아니다. 이런 예외까지 failure rate에 넣으면 정상 트래픽에서도 회로가 열린다. 반대로 timeout, connection refused, 5xx 응답은 장애 신호로 기록하는 편이 자연스럽다.

## 언제 쓰면 좋은가

Circuit Breaker는 호출 대상이 일시적으로 불안정할 때 빠르게 실패해 내부 자원을 보호하고, 사용자가 오래 기다리지 않게 하는 데 적합하다. 외부 결제사, 사내 공통 API, 검색 서비스, 추천 서비스처럼 장애가 전파되기 쉬운 dependency 앞에 두면 효과가 크다.

하지만 단순히 트래픽이 많아서 외부 API의 QPS를 줄이고 싶은 문제라면 rate limiter가 더 직접적이다. 동시에 실행되는 요청 수를 제한하고 싶다면 bulkhead가 맞다. 재시도를 안전하게 하고 싶다면 retry와 idempotency를 같이 설계해야 한다. Circuit Breaker 하나로 timeout, 동시성, 재시도, rate limit를 모두 해결하려고 하면 장애가 더 복잡해진다.

판단 기준은 이렇게 잡을 수 있다. 실패한 dependency를 일정 시간 빠르게 차단하고 싶으면 Circuit Breaker를 둔다. 느린 dependency 때문에 내 thread가 묶이는 것이 걱정이면 timeout과 Bulkhead를 먼저 확인한다. 호출량 자체를 줄여야 하면 RateLimiter를 본다.

## 운영에서 볼 것

운영 지표는 상태 전환만 보면 부족하다. 최소한 CircuitBreaker state, failure rate, slow call rate, not permitted call 수를 함께 본다. OPEN이 자주 발생하는데도 thread pool queue가 계속 늘면, 회로가 열리기 전의 동시 호출이 너무 많거나 timeout이 너무 길 가능성이 크다.

로그는 상태 전환 이벤트와 외부 호출 결과를 연결할 수 있어야 한다.

```text
payment.circuit state_transition CLOSED_TO_OPEN failureRate=63 slowCallRate=72
payment.call rejected reason=CallNotPermittedException orderId=9312
payment.call timeout elapsedMs=3000 provider=pay-gateway
payment.bulkhead rejected maxConcurrentCalls=20
```

알림도 나눠야 한다. `CallNotPermittedException` 증가는 이미 보호 장치가 작동했다는 신호다. 반면 thread pool active count, queue size, HTTP connection pending이 같이 오르면 보호 장치가 늦게 작동하고 있다는 뜻이다.

설정값을 정할 때는 외부 API의 정상 지연 시간부터 확인한다. 정상 p95가 300ms인 API에 slow threshold를 5초로 두면, 실제로 사용자가 느끼는 장애를 너무 늦게 감지한다. 반대로 정상 p99가 이미 2초인 API에 threshold를 1초로 두면 평상시에도 회로가 흔들린다. 보통은 정상 지연 분포, 사용자 timeout, 상위 호출자의 timeout을 함께 놓고 "이 시간이 넘으면 성공해도 이미 쓸모가 줄어든다"는 값을 slow threshold로 잡는다.

또한 재시도와 같이 쓸 때는 순서가 중요하다. 실패마다 즉시 세 번 재시도하고 그 전체를 CircuitBreaker가 한 번의 호출로 기록하면 외부 API에는 세 배 부하가 간다. 반대로 각 재시도를 모두 실패로 기록하면 회로가 너무 빨리 열릴 수 있다. 팀은 "어떤 예외를 재시도할지", "재시도 한 번의 timeout은 얼마인지", "최종 실패를 회로에 어떻게 기록할지"를 문서로 남겨야 한다. 이 기준이 없으면 설정값은 있어도 장애 때마다 해석이 달라진다.

서비스별 기본값을 복사해서 쓰는 것도 조심해야 한다. 결제 승인처럼 실패가 사용자 행동을 멈추게 하는 호출과, 추천 배너처럼 실패해도 기본값을 보여줄 수 있는 호출은 회로가 열렸을 때의 응답 전략이 다르다. 전자는 명확한 실패 응답과 보상 처리 안내가 필요하고, 후자는 fallback 데이터나 빈 목록이 더 나을 수 있다. Circuit Breaker 설정은 임계값만의 문제가 아니라 실패를 사용자 경험과 데이터 정합성에 어떻게 연결할지의 문제다.

배포 직후에는 `minimumNumberOfCalls` 때문에 회로가 예상보다 늦게 열릴 수 있다는 점도 기억해야 한다. 트래픽이 낮은 야간 배치나 관리자 기능은 호출 수가 적어 비율 계산이 늦다. 이런 기능은 작은 window를 쓰거나, 별도의 timeout과 알림으로 보완해야 한다. 반대로 트래픽이 매우 큰 API는 window가 너무 작으면 순간적인 흔들림만 보고 자주 OPEN이 될 수 있으므로 지연 분포와 에러율을 며칠치 기준으로 보고 조정하는 편이 안전하다.

## 정리

Circuit Breaker는 장애가 난 외부 호출을 빠르게 끊는 장치이지, 동시 실행 수 제한 장치가 아니다.
느린 장애에는 failure rate뿐 아니라 slow call rate, timeout, Bulkhead가 함께 필요하다.
비즈니스 예외와 시스템 예외를 구분하지 않으면 정상 요청도 회로를 열 수 있다.
운영에서는 state transition보다 thread, queue, connection pool 지표와 함께 봐야 한다.

## 참고한 공식 문서

- [Resilience4j CircuitBreaker documentation](https://resilience4j.readme.io/docs/circuitbreaker)
