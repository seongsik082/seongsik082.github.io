---
title: "OpenTelemetry 비동기 Executor에서 trace가 끊기면 원인 찾기가 어려워지는 이유"
date: 2026-07-03 08:52:00 +0900
tags: [Observability, OpenTelemetry, Backend]
excerpt: "OpenTelemetry의 Context는 현재 스레드 범위에 묶여 있으므로, 비동기 Executor나 CompletableFuture 경계에서 전파를 놓치면 span, 로그, 메트릭의 상관관계가 끊어져 장애 원인 추적이 급격히 어려워집니다."
---

## 문제 상황

HTTP 요청 하나가 들어와서 DB 조회, 캐시 조회, 외부 API 호출을 거친 뒤 응답하는 서비스는 요즘 흔합니다. 처음에는 자동 계측 덕분에 컨트롤러 span, JDBC span, HTTP client span이 꽤 잘 보입니다. 그래서 "이제 trace는 충분히 연결됐다"라고 생각하기 쉽습니다.

문제는 비동기 경계에서 생깁니다. `CompletableFuture`, 커스텀 `ExecutorService`, 비동기 이벤트 핸들러를 도입한 뒤부터 특정 구간 span이 갑자기 새 trace로 보이거나, 로그에는 trace ID가 비어 있고, 메트릭과 trace를 같은 요청으로 묶지 못하는 현상이 나타납니다. 장애가 났을 때도 원인 요청과 후속 작업을 한 화면에서 이어서 보지 못합니다.

이 상황이 까다로운 이유는 기능 자체는 정상 동작하기 때문입니다. 비즈니스 결과는 맞는데 관측성 연결만 끊어집니다. 그래서 성능 저하나 중복 호출 같은 실질 장애가 같이 터지기 전까지는 "trace가 예쁘게 안 보이는 문제"처럼 가볍게 넘어가기 쉽습니다.

## 핵심 개념

OpenTelemetry 공식 문서는 context propagation이 traces, metrics, logs를 서로 연관시키는 핵심 메커니즘이라고 설명합니다. 분산 환경에서는 `traceparent` 같은 메타데이터를 추출하고 다시 주입해서 서비스 간 인과 관계를 이어 붙입니다.

서비스 내부 비동기 경계에서도 같은 원리가 필요합니다. OpenTelemetry Java의 `Context` 소스는 Context가 현재 thread에 bound된 scope를 형성한다고 설명합니다. 즉 현재 요청의 trace 문맥은 자동으로 "모든 스레드"에 퍼지는 것이 아니라, 현재 scope가 유지되는 실행 흐름 안에서만 자연스럽게 이어집니다.

그래서 스레드 풀에 작업을 넘기는 순간이 위험 지점입니다. OpenTelemetry Java는 이런 경우를 위해 `Context.taskWrapping(Executor)`와 `wrap(Runnable)` 같은 API를 제공합니다. 공식 소스 설명 그대로, 이 API는 작업을 다른 thread에서 실행할 때 현재 context를 함께 전달하도록 래핑합니다.

반대로 이 전파를 빼먹으면, 비동기 작업은 "새 요청처럼" 실행되거나 상위 span과 연결되지 않은 orphan span처럼 보일 수 있습니다. W3C Trace Context 명세가 `traceparent`를 받아서 같은 trace를 이어 가는 규칙을 정의하듯, 프로세스 내부에서도 결국 같은 trace 문맥을 명시적으로 이어 줘야 합니다.

## 코드로 보기

문제가 있는 예시는 보통 아래처럼 단순합니다.

```java
ExecutorService executor = Executors.newFixedThreadPool(16);

public CompletableFuture<Product> loadProduct(String productId) {
    return CompletableFuture.supplyAsync(() -> productClient.fetch(productId), executor);
}
```

이 코드는 비즈니스 기능은 수행하지만, 현재 요청의 Context를 executor 쪽으로 같이 넘긴다는 보장이 없습니다. 자동 계측이 일부 구간을 잡아 주더라도, 커스텀 비동기 경계에서는 trace 연결이 빠질 수 있습니다.

OpenTelemetry Java가 제공하는 래핑을 적용하면 의도가 분명해집니다.

```java
ExecutorService rawExecutor = Executors.newFixedThreadPool(16);
ExecutorService tracedExecutor = Context.taskWrapping(rawExecutor);

public CompletableFuture<Product> loadProduct(String productId) {
    return CompletableFuture.supplyAsync(
        () -> productClient.fetch(productId),
        tracedExecutor
    );
}
```

필요하면 개별 작업 단위로도 현재 Context를 감쌀 수 있습니다.

```java
Context context = Context.current();
executor.execute(context.wrap(() -> auditPublisher.publish(event)));
```

이 방식의 장점은 "어디서 문맥을 넘기는지"가 코드에 드러난다는 점입니다. 관측성 문제는 대개 숨은 전역 상태 때문에 추적이 어렵기 때문에, 비동기 경계를 코드에서 명시하는 편이 운영에도 유리합니다.

## 자주 하는 실수

첫 번째 실수는 MDC만 있으면 충분하다고 생각하는 것입니다. 로깅 문맥과 tracing 문맥은 겹칠 수 있지만 동일하지 않습니다. 로그 한 줄에 trace ID가 찍혀도 span parent-child 관계가 올바르다는 보장은 없습니다.

두 번째 실수는 `makeCurrent()`를 열어 놓고 `Scope.close()`를 확실히 닫지 않는 것입니다. OpenTelemetry Java 소스도 이 규칙을 어기면 잘못된 scoping과 메모리 누수로 이어질 수 있다고 경고합니다.

세 번째 실수는 주기 작업까지 모두 같은 방식으로 전파된다고 가정하는 것입니다. 공식 소스는 `ScheduledExecutorService.taskWrapping(...)`를 써도 `scheduleAtFixedRate`와 `scheduleWithFixedDelay`에는 context가 전파되지 않는다고 명시합니다. 주기 실행 작업은 요청 문맥과 별개로 설계하는 편이 안전합니다.

네 번째 실수는 자동 계측이 있으니 커스텀 executor도 알아서 처리된다고 믿는 것입니다. 라이브러리 지원 범위를 벗어나는 순간에는 직접 경계를 잡아 줘야 합니다.

## 언제 쓰면 좋은가

비동기 executor, `CompletableFuture`, 별도 워커 스레드, 내부 이벤트 디스패처를 쓰는 서비스라면 거의 항상 점검 대상입니다. 특히 외부 API 호출, 캐시 재계산, 감사 로그 발행처럼 "요청과 연결은 되지만 다른 스레드에서 수행되는 일"은 trace 문맥이 자주 끊깁니다.

반대로 배치 스케줄러나 독립 소비자처럼 애초에 "새 루트 작업"으로 보는 편이 맞는 흐름도 있습니다. 이런 경우에는 억지로 상위 요청 문맥을 들고 가기보다 새 trace를 시작하고, 필요한 비즈니스 식별자만 명시적으로 태그로 남기는 편이 더 낫습니다.

실무 판단 기준은 단순합니다. 장애 분석 시 "이 비동기 작업이 어떤 사용자 요청 때문에 실행됐는지"를 한 번에 알아야 하는가? 그렇다면 context propagation을 붙여야 합니다. 반대로 독립 잡이라면 새 trace로 시작하는 편이 더 명확합니다.

## 운영에서 볼 것

- 비동기 경계 뒤 span이 새 trace ID로 갈라지는지
- 같은 요청인데 로그의 trace ID가 비거나 갑자기 바뀌는지
- orphan span 비율이나 parent 없는 span 비율이 특정 릴리스 뒤 늘어났는지
- 커스텀 executor, `CompletableFuture`, 스케줄러 코드 경계가 어디인지
- strict context 검사 옵션을 테스트나 스테이징에서 켤 수 있는지

OpenTelemetry Java 소스는 strict context 검사를 위한 JVM 옵션도 제공합니다. 운영 상시 적용은 비용을 봐야 하지만, 최소한 테스트나 스테이징에서는 이런 검사를 활용해 잘못 닫힌 scope와 잘못된 스레드 사용을 빨리 잡는 편이 좋습니다.

## 정리

OpenTelemetry에서 context propagation은 보기 좋은 trace를 만드는 부가 기능이 아니라, 비동기 시스템의 원인 추적성을 유지하는 핵심 장치입니다. Context가 현재 스레드 범위에 묶여 있다는 사실을 잊으면 executor 경계에서 trace가 조용히 끊어지고, 그 순간부터 로그, 메트릭, span을 같은 요청으로 엮는 비용이 급격히 커집니다. 커스텀 비동기 코드를 쓰는 팀이라면 기능 코드만큼 context 전파 경계도 명시적으로 관리해야 합니다.

## 참고한 공식 문서

- [OpenTelemetry Docs: Context propagation](https://opentelemetry.io/docs/concepts/context-propagation/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [OpenTelemetry Java `Context` source](https://github.com/open-telemetry/opentelemetry-java/blob/main/context/src/main/java/io/opentelemetry/context/Context.java)
