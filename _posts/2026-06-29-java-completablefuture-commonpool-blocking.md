---
title: "CompletableFuture 기본 Executor를 모르면 공용 풀이 막히는 이유"
date: 2026-06-29 09:40:00 +0900
tags: [Java, Performance, Backend]
excerpt: "CompletableFuture는 편하지만, Executor를 명시하지 않은 async 체인이 공용 ForkJoinPool에 몰리면 CPU 작업과 I/O 대기가 서로를 막아 응답 지연이 커질 수 있습니다."
---

Spring 서버에서 여러 API 결과를 한 번에 모으고 싶을 때 `CompletableFuture`를 자주 씁니다.
처음에는 코드가 깔끔해 보여서 만족스럽습니다.
그런데 어느 날부터 "CPU는 크게 안 바쁜데 응답이 자꾸 늦다", "비동기 처리로 바꿨는데 처리량이 안 는다" 같은 문제가 보일 수 있습니다.

이때 자주 놓치는 포인트가 `Executor`입니다.
`CompletableFuture`는 비동기 문법을 제공하지만, 실제로는 어떤 스레드 풀에서 돌아가느냐가 성능을 좌우합니다.
Java 공식 문서는 `supplyAsync`와 `runAsync`가 `Executor`를 따로 주지 않으면 기본적으로 `ForkJoinPool.commonPool()`을 사용한다고 설명합니다.
즉 아무 생각 없이 async 메서드를 늘리면, 여러 작업이 같은 공용 풀에 같이 쌓일 수 있습니다.

## 왜 문제인가

공용 풀은 짧은 계산 작업에는 잘 맞습니다.
문제는 실무 코드의 비동기 작업이 계산만 하는 경우보다, 외부 API를 기다리거나 DB 결과를 기다리는 경우가 더 많다는 점입니다.
이런 작업은 "비동기"처럼 보여도 실제로는 스레드를 오래 붙잡고 있을 수 있습니다.

예를 들어 가격 API를 호출하고, 재고 정보를 읽고, 결과를 합치는 코드를 생각해보겠습니다.

```java
CompletableFuture<OrderSummary> future =
    CompletableFuture.supplyAsync(() -> orderRepository.findSummary(orderId))
        .thenApplyAsync(this::enrichWithInventory)
        .thenApplyAsync(this::callPricingService);
```

겉보기에는 세 단계가 자연스럽게 이어지지만, `Executor`를 지정하지 않았다면 모두 공용 풀에서 돌 수 있습니다.
여기서 마지막 단계가 외부 HTTP 응답을 오래 기다리면, 다른 요청도 같은 공용 풀에서 줄을 설 수 있습니다.
운영에서는 이 현상이 "갑자기 응답 시간이 길어진다"는 형태로 먼저 보입니다.

## 어떻게 이해하면 좋을까

`CompletableFuture`를 볼 때 가장 먼저 할 질문은 "이 작업이 계산 위주인가, 기다림 위주인가"입니다.

- 계산 위주 작업: JSON 가공, 계산, 정렬, 집계
- 기다림 위주 작업: HTTP 호출, JDBC 대기, 파일 업로드, 캐시 응답 대기

계산 위주 작업은 공용 풀과 잘 맞을 수 있습니다.
하지만 기다림 위주 작업이 많아지면 공용 풀 하나에 몰아넣는 방식이 점점 위험해집니다.
그래서 실무에서는 "기본 공용 풀에 그냥 맡긴다"보다 "작업 성격에 맞는 풀을 따로 둔다" 쪽이 더 읽기 쉽고 운영도 편합니다.

## 가장 단순한 개선 방법

외부 I/O가 들어가는 비동기 작업에는 별도 `Executor`를 명시하는 것부터 시작하는 편이 좋습니다.

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

이렇게 하면 "가격 API 호출 때문에 느린 것인지", "애플리케이션 계산이 느린 것인지"를 더 쉽게 분리해서 볼 수 있습니다.
스레드 이름도 구분되기 때문에 스레드 덤프나 로그에서 병목을 찾기 쉬워집니다.

## 흔한 실수 패턴

첫 번째 실수는 "비동기면 자동으로 빨라진다"고 생각하는 것입니다.
`CompletableFuture`는 작업을 다른 스레드로 넘기기 쉽게 해주지만, 그 안에서 HTTP 호출이나 JDBC 대기가 일어나면 스레드는 그대로 기다립니다.

두 번째 실수는 마지막에 `join()`으로 다시 묶는 것입니다.

```java
Price price = CompletableFuture
    .supplyAsync(() -> pricingClient.fetch(productId))
    .join();
```

이 코드는 결국 현재 요청 스레드가 결과를 기다립니다.
필요한 경우도 있지만, "비동기로 바꿨는데 체감이 없다"는 상황에서 자주 보이는 패턴입니다.

세 번째 실수는 예외 처리와 타임아웃을 빼먹는 것입니다.
외부 API가 느려질수록 풀 점유 시간도 길어지므로 `orTimeout`, `completeOnTimeout`, `exceptionally` 같은 종료 조건을 함께 두는 편이 좋습니다.

## 언제 쓰고, 언제 피해야 하나

`CompletableFuture`는 다음 상황에 잘 맞습니다.

- 여러 독립 조회를 병렬로 합쳐 응답 시간을 줄일 때
- 외부 호출이 있지만 어느 풀에서 돌릴지 분리해 둘 수 있을 때
- 타임아웃과 예외 처리 정책이 이미 정해져 있을 때

반대로 다음 상황에서는 주의가 필요합니다.

- 외부 I/O가 긴데 공용 풀을 그대로 쓰는 경우
- 각 단계가 결국 바로 `join()`되는 경우
- 스레드 풀 관찰 지표 없이 체인만 빠르게 늘리는 경우
- 팀이 "이 작업이 어느 풀에서 도는지" 설명하지 못하는 경우

실무 기준으로 한 줄로 정리하면 이렇습니다.
외부 API나 DB를 기다리는 비동기 작업이라면 기본 공용 풀에 그냥 올리지 않는 편이 안전합니다.

## 운영에서 확인할 것

다음 지표와 흔적을 함께 보는 편이 좋습니다.

- 스레드 덤프에서 `ForkJoinPool.commonPool-worker-*` 대기 비율
- 외부 API 호출 타임아웃 증가 시점과 응답 지연 증가 시점
- 커스텀 풀의 활성 스레드 수, 큐 길이, 작업 거부 횟수
- `join()` 대기 시간이 긴 요청의 트레이스
- p95/p99 응답 시간과 배치/후처리 작업 시작 시점의 상관관계

스레드 풀 문제는 예외보다 지연 시간으로 먼저 보이는 경우가 많습니다.
그래서 "비동기 코드를 썼다"보다 "어느 풀이 무엇 때문에 기다리고 있는가"를 먼저 보는 편이 좋습니다.

## 정리

`CompletableFuture`의 async 메서드는 `Executor`를 지정하지 않으면 기본적으로 공용 `ForkJoinPool`을 사용합니다.
이 풀에 외부 I/O 대기와 계산 작업을 함께 올리면, 비동기화가 오히려 숨은 병목이 될 수 있습니다.
실무에서는 작업 성격별로 `Executor`를 나누고, 타임아웃을 함께 두는 것만으로도 문제를 많이 줄일 수 있습니다.
핵심은 `CompletableFuture` 문법보다 "어떤 작업을 어떤 풀에서 돌리는가"입니다.

참고한 공식 문서:
- [CompletableFuture Javadoc](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/CompletableFuture.html)
- [ForkJoinPool Javadoc](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ForkJoinPool.html)
