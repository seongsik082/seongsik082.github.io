---
title: "CompletableFuture 기본 Executor를 모르면 공용 풀이 막히는 이유"
date: 2026-06-29 09:40:00 +0900
tags: [Java, Performance, Backend]
excerpt: "CompletableFuture는 편하지만, Executor를 명시하지 않은 async 체인이 공용 ForkJoinPool에 몰리면 CPU 작업과 I/O 대기가 서로를 막아 응답 지연이 커질 수 있습니다."
---

Java 백엔드에서 `CompletableFuture`는 비동기 흐름을 비교적 간결하게 표현할 수 있게 해줍니다.
문제는 코드가 간결해질수록 실행 환경을 잊기 쉽다는 점입니다.
`supplyAsync`, `runAsync`, `thenApplyAsync`를 이어 붙이면 비동기처럼 보이지만, 실제로는 어떤 스레드 풀에서 돌고 있는지에 따라 응답 시간과 장애 양상이 크게 달라집니다.

운영에서 자주 보는 패턴은 이렇습니다.
초기에는 가벼운 비동기 후처리 몇 개만 `CompletableFuture`로 감쌌고 문제가 없습니다.
그런데 시간이 지나면서 외부 API 호출, DB 조회, 파일 업로드, 캐시 재계산이 같은 방식으로 늘어나고, 어느 순간부터 p95 지연 시간과 타임아웃이 함께 올라갑니다.
로그에는 예외가 많지 않은데 스레드 덤프를 보면 `ForkJoinPool.commonPool-worker-*`가 대기 상태로 몰려 있습니다.

핵심은 `Executor`를 지정하지 않은 `CompletableFuture`의 기본 동작입니다.
Java 공식 문서는 `supplyAsync`와 `runAsync`가 기본적으로 `ForkJoinPool.commonPool()`에서 작업을 실행한다고 설명합니다.
또한 `defaultExecutor()` 역시 별도 `Executor`를 지정하지 않은 async 메서드가 기본적으로 공용 풀을 쓴다고 명시합니다.
즉 "잠깐 편하게 비동기 하나만"이라는 코드가 프로젝트 전체에서 누적되면, 서로 다른 성격의 작업이 같은 공용 풀을 두고 경쟁하게 됩니다.

## 공용 풀은 CPU 작업에 더 가깝게 설계되어 있다

`ForkJoinPool`은 작업 분할과 훔치기(work-stealing)에 강점이 있는 풀입니다.
짧고 계산 중심인 태스크를 병렬로 처리할 때 잘 맞습니다.
반대로 원격 API 호출, JDBC 대기, 파일 I/O처럼 오래 블로킹될 수 있는 작업을 공용 풀에 섞으면, 실제로 일을 하는 스레드 수가 부족해질 수 있습니다.

```java
CompletableFuture<OrderSummary> future =
    CompletableFuture.supplyAsync(() -> orderRepository.findSummary(orderId))
        .thenApplyAsync(this::enrichWithInventory)
        .thenApplyAsync(this::callPricingService);
```

겉보기에는 각 단계가 "비동기"라 빠를 것 같지만, `Executor`를 하나도 넘기지 않았다면 모두 기본 풀에 올라갑니다.
여기서 `callPricingService`가 HTTP 대기로 오래 막히면 다음 작업들이 같은 공용 풀의 워커를 기다리게 됩니다.
특히 여러 요청이 한꺼번에 이 패턴을 타면 공용 풀이 사실상 숨은 병목이 됩니다.

Java 공식 문서의 `ForkJoinPool`은 `ManagedBlocker`를 통해 블로킹 작업을 일부 보완할 수 있다고 설명합니다.
다만 이건 "ForkJoinPool 안에서 블로킹이 불가피할 때 병렬성을 관리하기 위한 고급 장치"에 가깝습니다.
실무 애플리케이션에서 HTTP 호출이나 JDBC 같은 일반적인 I/O를 대량으로 태울 때는, 공용 풀에 기대기보다 애초에 별도 `Executor`를 나누는 편이 훨씬 단순하고 안전합니다.

## CPU 풀과 I/O 풀을 분리해야 하는 이유

운영 관점에서 중요한 건 작업의 성격입니다.

- CPU 계산: 짧고 코어 수에 비례하게 돌고 끝나는 작업
- I/O 대기: 스레드는 잡고 있지만 원격 응답을 기다리는 작업
- 혼합 작업: 계산과 원격 호출이 섞여 있어 관찰 없이는 병목이 안 보이는 작업

이 셋을 같은 풀에 넣으면 장애가 섞입니다.
외부 API가 느려졌는데 CPU 계산도 같이 밀리고, 반대로 배치 계산이 몰렸는데 API 응답도 늦어집니다.
그래서 최소한 "CPU 중심 비동기"와 "대기 시간이 긴 I/O"는 풀을 분리하는 편이 좋습니다.

```java
@Bean
public Executor pricingExecutor() {
    ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
    executor.setCorePoolSize(16);
    executor.setMaxPoolSize(32);
    executor.setQueueCapacity(200);
    executor.setThreadNamePrefix("pricing-io-");
    executor.initialize();
    return executor;
}
```

```java
CompletableFuture<Price> future =
    CompletableFuture.supplyAsync(() -> pricingClient.fetch(productId), pricingExecutor)
        .orTimeout(800, TimeUnit.MILLISECONDS);
```

이렇게 하면 적어도 어떤 종류의 작업이 어느 풀을 점유하는지 분리해서 관찰할 수 있습니다.
장애 시에도 `pricing-io-*`가 막혔는지, 애플리케이션의 계산용 풀이 막혔는지 로그와 스레드 덤프에서 더 빨리 좁힐 수 있습니다.

## 흔한 실수 패턴

첫 번째 실수는 "비동기면 논블로킹"이라고 착각하는 것입니다.
`CompletableFuture`는 논블로킹 프레임워크가 아니라, 별도 스레드에서 작업을 이어 붙이기 쉬운 도구입니다.
그 안에서 `RestTemplate`, JDBC, 파일 읽기, `Thread.sleep`을 호출하면 여전히 스레드는 블로킹됩니다.

두 번째 실수는 마지막에 `join()`으로 다시 묶는 것입니다.

```java
Price price = CompletableFuture
    .supplyAsync(() -> pricingClient.fetch(productId))
    .join();
```

이 코드는 결국 현재 요청 스레드가 결과를 기다립니다.
필요한 경우가 있지만, "비동기로 바꿨는데 왜 처리량이 안 늘지?"라는 질문의 상당수는 여기서 나옵니다.
요청 스레드와 공용 풀이 모두 대기하면, 비동기 도입 비용만 늘고 병목은 그대로 남습니다.

세 번째 실수는 예외 처리와 타임아웃을 빼먹는 것입니다.
외부 API가 늦을수록 공용 풀 점유 시간이 길어지므로 `orTimeout`, `completeOnTimeout`, `exceptionally` 같은 종료 조건이 중요합니다.
비동기 체인은 실패를 숨기기 쉬워서, 타임아웃 없이 붙인 체인은 운영에서 가장 늦게 드러나는 병목이 됩니다.

## 언제 쓰고, 언제 피해야 하나

`CompletableFuture`는 다음 상황에 잘 맞습니다.

- 여러 독립 조회를 병렬로 합쳐 응답 시간을 줄일 때
- CPU 계산과 후처리를 명확히 단계화할 때
- 별도 `Executor`, 타임아웃, 예외 처리 정책이 이미 정해져 있을 때

반대로 다음 상황에서는 주의가 필요합니다.

- 외부 I/O가 긴데 공용 풀을 그대로 쓰는 경우
- 각 단계가 결국 바로 `join()`되는 경우
- 스레드 풀 관찰 지표 없이 체인만 빠르게 늘리는 경우
- 팀이 "이 작업이 어느 풀에서 도는지" 설명하지 못하는 경우

즉 `CompletableFuture`를 쓴다는 사실보다, 어떤 `Executor`에서 어떤 비용의 작업을 돌리는지가 더 중요합니다.

## 운영에서 확인할 것

다음 지표와 흔적을 함께 보는 편이 좋습니다.

- 스레드 덤프에서 `ForkJoinPool.commonPool-worker-*` 대기 비율
- 외부 API 호출 타임아웃 증가 시점과 응답 지연 증가 시점
- 커스텀 풀의 활성 스레드 수, 큐 길이, 작업 거부 횟수
- `join()` 대기 시간이 긴 요청의 트레이스
- p95/p99 응답 시간과 배치/후처리 작업 시작 시점의 상관관계

스레드 풀 문제는 예외보다 지연 시간으로 먼저 보이는 경우가 많습니다.
그래서 "비동기 코드가 늘었다"보다 "기본 공용 풀이 어떤 작업에 소비되고 있는가"를 먼저 물어야 합니다.

## 정리

`CompletableFuture`의 async 메서드는 `Executor`를 지정하지 않으면 기본적으로 공용 `ForkJoinPool`을 사용합니다.
이 풀에 블로킹 I/O와 CPU 작업을 함께 올리면, 비동기화가 오히려 숨은 경합을 만들 수 있습니다.
실무에서는 공용 풀을 무심코 공유하기보다 작업 성격별 `Executor`를 분리하고, 타임아웃과 예외 처리까지 함께 설계하는 편이 안전합니다.
비동기 성능 문제의 출발점은 문법이 아니라 실행 컨텍스트입니다.

참고한 공식 문서:
- [CompletableFuture Javadoc](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/CompletableFuture.html)
- [ForkJoinPool Javadoc](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ForkJoinPool.html)
