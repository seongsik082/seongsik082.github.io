---
title: "ThreadPoolExecutor에 무한 큐를 두면 maxPoolSize가 거의 의미 없어지는 이유"
date: 2026-07-04 08:58:00 +0900
tags: [Java, Performance, Backend]
excerpt: "Java ThreadPoolExecutor는 corePoolSize를 넘긴 뒤 먼저 큐에 쌓고, 큐가 가득 찼을 때만 maxPoolSize까지 스레드를 늘립니다. 큐를 무한대로 두면 maxPoolSize는 설정만 있고 거의 작동하지 않습니다."
---

## 문제 상황

알림 발송, 이미지 후처리, 외부 API 호출처럼 시간이 걸리는 작업을 비동기로 넘길 때 많은 팀이 스레드 풀 크기만 크게 잡으면 안전하다고 생각합니다. `corePoolSize=16`, `maxPoolSize=64` 정도를 보고 "피크 때는 64개까지 늘겠지"라고 기대하는 식입니다.

그런데 운영 장애는 종종 다른 모양으로 옵니다. CPU는 남아 있는데 응답 시간이 길어지고, 작업은 계속 밀리는데 실제 실행 중인 스레드는 16개 근처에서 늘지 않습니다. 로그에는 오류가 많지 않은데 큐 적체가 누적되고, 몇 분 뒤에는 타임아웃이 한꺼번에 터집니다.

이 상황에서 핵심은 스레드 수보다 큐 정책입니다. `ThreadPoolExecutor`는 core를 넘겼다고 바로 max까지 스레드를 늘리지 않습니다. 먼저 큐에 넣고, 큐에 더는 못 넣을 때만 추가 스레드를 만듭니다. 따라서 `LinkedBlockingQueue`처럼 사실상 무한 큐를 쓰면 `maxPoolSize`는 기대한 보호 장치가 아니라 거의 장식이 됩니다.

## 핵심 개념

JDK 공식 문서는 `execute()` 동작 순서를 분명히 설명합니다. `corePoolSize`보다 적게 돌고 있으면 새 스레드를 만들고, 그 이상이면 우선 큐에 넣습니다. 그리고 큐에 넣을 수 없을 때만 `maximumPoolSize`까지 추가 스레드를 만듭니다.

같은 문서는 무한 큐를 쓰는 경우를 더 직접적으로 설명합니다. 용량이 정해지지 않은 `LinkedBlockingQueue`를 사용하면 새 작업은 core 스레드가 모두 바쁠 때 큐에서 기다리며, 그 결과 core보다 많은 스레드는 만들어지지 않습니다. 즉 `maximumPoolSize` 값은 영향을 주지 않습니다.

`Executors.newFixedThreadPool(n)` 역시 공식 문서상 "shared unbounded queue"를 사용합니다. 간단해 보여서 많이 쓰지만, 작업 처리 속도보다 유입 속도가 길게 높아지는 순간 큐 길이와 대기 시간이 끝없이 늘 수 있습니다.

## 코드로 보기

아래 설정은 흔히 보는 형태입니다.

```java
ExecutorService executor = new ThreadPoolExecutor(
    16,
    64,
    60L,
    TimeUnit.SECONDS,
    new LinkedBlockingQueue<>()
);
```

이 설정에서는 16개 스레드가 바빠진 뒤 들어오는 작업이 큐에 계속 쌓입니다. 큐가 사실상 가득 차지 않으니 17번째, 32번째, 64번째 스레드는 거의 생기지 않습니다.

부하 완충이 정말 필요하다면 보통은 큐와 스레드 수를 함께 제한해야 합니다.

```java
ExecutorService executor = new ThreadPoolExecutor(
    16,
    32,
    60L,
    TimeUnit.SECONDS,
    new ArrayBlockingQueue<>(200),
    new ThreadPoolExecutor.CallerRunsPolicy()
);
```

이 구성의 의미는 이렇습니다.

- 평소에는 core 16개로 처리합니다.
- 순간 피크에서 큐 200개까지 완충합니다.
- 큐가 차면 32개까지 스레드를 늘립니다.
- 그래도 포화되면 `CallerRunsPolicy`로 제출 측을 늦춰 간단한 backpressure를 만듭니다.

여기서도 무조건 정답은 아닙니다. 중요한 것은 "어느 지점에서 대기시키고, 어느 지점에서 거절하거나 늦출지"를 명시했다는 점입니다.

## 자주 하는 실수

첫 번째 실수는 `maxPoolSize`만 키우는 것입니다. 큐가 무한이면 그 수치는 거의 사용되지 않습니다.

두 번째 실수는 I/O 대기 작업에 무한 큐를 두고 "나중에 처리되겠지"라고 생각하는 것입니다. 작업 시간이 긴 상태에서 큐만 늘어나면 지연이 숨겨질 뿐 없어지지 않습니다.

세 번째 실수는 거절 정책을 예외 처리 정도로만 보는 것입니다. `AbortPolicy`, `CallerRunsPolicy`, discard 계열 정책은 각각 서비스 동작을 바꿉니다. 어떤 실패를 허용할지 결정하지 않은 채 기본값을 두면 장애가 늦게 보이거나 엉뚱한 곳에서 보일 수 있습니다.

네 번째 실수는 실행 시간 분포를 보지 않고 풀 크기만 튜닝하는 것입니다. 짧은 CPU 작업과 느린 네트워크 호출이 섞인 큐는 같은 숫자로 다루기 어렵습니다. 풀을 나누는 편이 더 낫기도 합니다.

## 언제 쓰면 좋은가

무한 큐는 작업이 서로 독립적이고, 일시적 적체가 허용되며, 평균 처리 속도가 유입 속도를 충분히 따라잡는 경우에만 조심스럽게 고려할 수 있습니다. 하지만 사용자 응답 시간과 직접 연결된 비동기 작업, 외부 API 지연에 민감한 작업, 장애 때 backlog가 크게 불어나는 작업에는 보통 명시적 상한이 더 안전합니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "이 큐가 10배 길어졌을 때도 서비스가 여전히 정상인가?" 아니라면 bounded queue와 포화 정책을 설계해야 합니다.

## 운영에서 볼 것

- `getActiveCount()`, `getPoolSize()`, `getQueue().size()` 추이
- 작업 대기 시간과 실제 실행 시간 분포
- reject 횟수와 `CallerRuns` 발생 비율
- 비동기 작업 때문에 앞단 HTTP p95, p99가 같이 상승하는지
- 특정 작업 유형이 큐 대부분을 점유하는지

장애 때는 현재 스레드 수보다 큐 길이와 oldest queued task age를 먼저 보는 편이 빠릅니다. 스레드가 부족한 문제인지, 느린 작업이 큐를 잠식한 문제인지 구분해야 대응이 달라집니다.

## 정리

`ThreadPoolExecutor`에서 `maxPoolSize`는 큐가 포화될 때만 의미가 있습니다. 무한 큐를 두면 작업은 core 스레드 뒤에서 끝없이 기다리고, `maxPoolSize`는 기대와 달리 거의 동작하지 않습니다. 비동기 실행 설계에서는 스레드 수보다 큐 상한, 포화 시 행동, 작업 분리 기준을 먼저 정하는 편이 운영에 훨씬 안전합니다.

## 참고한 공식 문서

- [Java SE 21 `ThreadPoolExecutor` API](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ThreadPoolExecutor.html)
- [Java SE 21 `Executors.newFixedThreadPool` API](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/Executors.html)
