---
title: "JVM 스레드 덤프를 어디부터 읽어야 하는가"
date: 2026-07-14 08:50:00 +0900
tags: [Java, JVM, Performance, Operations, Backend]
excerpt: "JVM 스레드 덤프는 파일을 열어 모든 스택을 읽는 자료가 아니라, 지연이 늘어난 순간 어떤 스레드가 실행·락·외부 자원을 기다리는지 좁히는 진단 도구입니다. 상태 분포, 반복되는 stack trace, 여러 시점의 변화부터 읽어야 원인을 빠르게 구분할 수 있습니다."
---

## 문제 상황

새 배포 뒤 API p99가 300ms에서 4초로 뛰었습니다. CPU는 40% 정도이고 GC pause도 평소와 비슷합니다. 애플리케이션 로그에는 특별한 예외가 없지만, 요청 처리 스레드가 계속 쌓이면서 결국 gateway timeout이 발생합니다. 이때 thread dump를 한 번 받아 파일의 첫 줄만 보고 “스레드가 전부 WAITING이라 CPU 문제는 아니다”라고 결론 내리면 원인을 놓치기 쉽습니다.

스레드 덤프는 장애 순간의 JVM을 한 장 찍은 사진에 가깝습니다. 사진 한 장만으로 동영상을 해석할 수 없듯이, 한 번의 상태보다 여러 시점에 같은 stack trace가 반복되는지와 어떤 스레드가 다른 스레드를 막고 있는지를 함께 봐야 합니다. 먼저 상태를 분류하고, 그 다음 이름·호출 위치·대기 대상을 연결하는 순서가 실무에서 가장 빠릅니다.

## Thread.State를 먼저 분류하기

Java의 `Thread.State`는 운영체제 스레드 상태와 같은 값이 아니라 JVM이 관찰하는 가상 상태입니다. `RUNNABLE`은 JVM에서 실행 가능한 상태이지만 실제 CPU를 계속 쓰고 있다는 뜻으로 한정되지 않습니다. `BLOCKED`는 `synchronized` 모니터 락을 얻지 못해 기다리는 상태이고, `WAITING`과 `TIMED_WAITING`은 다른 스레드의 동작이나 특정 시간이 지나기를 기다리는 상태입니다.

상태 이름만으로 원인을 확정하지 말고 다음 질문을 붙여 읽습니다.

- `RUNNABLE`이 많은가? 같은 계산 stack이 반복되면 CPU 또는 busy loop를 의심한다.
- `BLOCKED`가 많은가? 어떤 모니터를 기다리는지와 락을 가진 스레드를 찾는다.
- `WAITING`이 많은가? queue, `Future`, `CountDownLatch`, connection pool 등 대기 대상을 확인한다.
- `TIMED_WAITING`이 많은가? sleep, timeout, socket read, pool 대기가 정상 범위를 넘었는지 본다.

즉 `WAITING`이 많다는 사실보다 “무엇을 기다리느라 기다리는가”가 더 중요합니다. DB 커넥션을 기다리는 요청과 작업 큐에서 정상적으로 대기하는 worker는 같은 상태로 보일 수 있지만 장애 의미는 다릅니다.

## 덤프를 안전하게 얻는 방법

JDK 21 환경에서는 먼저 같은 호스트에서 JVM PID를 확인합니다.

```bash
jcmd -l
jcmd 18421 Thread.print -l > /tmp/checkout-thread-01.txt
sleep 5
jcmd 18421 Thread.print -l > /tmp/checkout-thread-02.txt
sleep 5
jcmd 18421 Thread.print -l > /tmp/checkout-thread-03.txt
```

`Thread.print`는 모든 스레드와 stack trace를 출력하고 `-l`은 `java.util.concurrent` 락 정보를 더 보여줍니다. `jcmd`는 대상 JVM과 같은 머신에서 실행해야 하고, 같은 유효 사용자·그룹 권한이 필요합니다. 컨테이너 안의 JVM이라면 호스트 PID와 컨테이너 PID를 혼동하지 말고, 실제 프로세스가 보이는 위치에서 명령을 실행해야 합니다.

덤프를 너무 자주 받으면 큰 JVM에서 진단 작업 자체가 부담이 될 수 있습니다. 보통 5~10초 간격의 세 장으로 충분하며, 요청 timeout이 수십 초인 장애라면 간격을 증상에 맞춰 조정합니다. 운영 환경에서는 임시 파일에 민감한 요청 파라미터나 내부 경로가 남을 수 있으므로 접근 권한과 보관 기간도 정해야 합니다.

## 첫 판독 순서

### 1. 스레드 이름과 상태를 묶어 본다

`http-nio-8080-exec`, `HikariPool`, `ForkJoinPool`, `kafka-consumer`처럼 이름의 접두어를 기준으로 그룹을 만듭니다. 요청 스레드 대부분이 `HikariPool.getConnection` 주변에서 대기한다면 DB 커넥션 획득 대기를 확인해야 합니다. 반대로 `ForkJoinPool`에서 외부 API 호출 stack이 반복되면 공용 executor에 blocking 작업을 넣었는지 봅니다.

### 2. 같은 stack trace가 반복되는지 비교한다

한 장에서 같은 위치가 많이 보이는 것은 후보를 줄이는 단서입니다. 세 장 모두 같은 `BLOCKED` stack이 유지되면 락 소유 스레드가 오래 살아 있는지 확인하고, 첫 장에는 보이지 않던 stack이 뒤에서 늘어나면 queue나 timeout이 누적되는 흐름일 수 있습니다. 단순히 스레드 수를 세는 것보다 “같은 그룹이 계속 늘어나는가”를 봅니다.

### 3. 락을 기다리는 스레드와 가진 스레드를 연결한다

`BLOCKED` 스레드의 stack만 읽으면 기다리는 쪽의 위치만 알 수 있습니다. dump에 표시된 monitor 주소나 `-l`의 `java.util.concurrent` lock 정보를 따라가서 해당 락을 오래 가진 스레드를 찾아야 합니다. 락 소유자가 외부 API, 파일 I/O, DB 호출 안에서 멈춰 있다면 synchronized 블록 안에 느린 작업을 넣은 것이 병목일 수 있습니다.

### 4. 운영 지표와 대조한다

덤프에서 DB 대기가 보였다고 바로 DB 장애로 단정하지 않습니다. 같은 시각의 connection pool pending, DB active connection, query latency, 외부 HTTP client pool, CPU와 GC를 함께 비교합니다. 스레드 덤프는 원인을 보여주는 증거 중 하나이지, 메트릭·로그·trace를 대체하는 단일 진실이 아닙니다.

여러 인스턴스 중 한 곳에서만 같은 stack이 반복된다면 코드나 특정 입력보다 해당 인스턴스의 연결 상태와 배포 차이를 먼저 비교합니다. 모든 인스턴스에서 같은 위치가 늘어난다면 공통 downstream이나 전역 락, 트래픽 패턴을 의심할 수 있습니다. 반대로 특정 worker 그룹만 멈췄다면 전체 JVM 장애로 확대 해석하지 말고 그 executor의 queue와 reject 정책을 확인합니다.

## 자주 하는 실수

첫 번째는 `RUNNABLE`을 곧바로 CPU 100%로 해석하는 것입니다. Java 문서의 `RUNNABLE`은 OS 스케줄러에서 실제 실행 중인지까지 보장하지 않습니다. CPU 사용률과 반복 stack을 같이 보고, CPU가 낮은데 `RUNNABLE`이 많다면 native I/O나 다른 자원 대기를 확인해야 합니다.

두 번째는 한 장의 dump로 deadlock을 확정하는 것입니다. 락 그래프가 명확하지 않다면 세 장의 변화와 애플리케이션 로그를 함께 봅니다. JVM이 deadlock을 탐지할 수 있는 상황과 DB lock wait, 외부 API timeout은 서로 다른 문제이므로 “락이 보였다”는 이유만으로 같은 해결책을 적용하면 안 됩니다.

세 번째는 모든 스레드 이름을 기본값으로 두는 것입니다. `pool-3-thread-17`보다 `order-worker-17`처럼 역할을 넣으면 장애 시 그룹별 대기와 처리량을 연결하기 쉽습니다. executor별 active count, queue size, rejection count도 메트릭으로 남겨 dump를 받기 전부터 범위를 좁히는 편이 좋습니다.

## 언제 쓰고 언제 다른 도구를 쓸까

thread dump는 요청 timeout, 스레드 풀 고갈, monitor contention, deadlock 의심처럼 “지금 JVM 안에서 스레드가 어디에 머무는가”가 질문일 때 유용합니다. 반대로 heap이 계속 커지는 문제가 질문이면 heap dump나 JFR, GC pause 원인이 질문이면 GC 로그와 JFR을 우선 봅니다. dump가 원인을 설명하지 못한다면 도구가 틀린 것이 아니라 질문과 자료가 맞지 않는 것일 수 있습니다.

판단 기준은 간단합니다. CPU가 높고 동일한 계산 stack이 반복되면 profiling을 우선하고, CPU는 낮은데 요청 스레드가 같은 pool·lock·외부 호출에서 대기하면 thread dump를 우선합니다. 어느 경우든 진단 명령을 반복 실행하기 전에 수집 영향과 민감 정보 노출을 확인해야 합니다.

## 운영에서 볼 것

- executor별 active thread, queue depth, rejection 수
- HTTP 요청 in-flight와 timeout, DB connection acquisition 대기
- CPU, load average, GC pause, heap 사용량
- `BLOCKED`·`WAITING` 스레드 수와 반복 stack trace
- thread dump 수집 시각, 배포 버전, instance·pod 이름

장애 보고서에는 dump 파일만 첨부하지 말고 “09:01에 p99가 증가했고, 09:02~09:03 세 장에서 `order-worker` 40개가 같은 외부 HTTP client stack에 머물렀으며, 외부 API p99도 함께 증가했다”처럼 시간과 그룹을 적습니다. 이 정도의 요약이 있어야 다음 사람이 파일 전체를 다시 읽지 않고도 가설을 검증할 수 있습니다.

## 정리

JVM 스레드 덤프는 상태 이름을 읽는 자료가 아니라 대기 대상과 반복 stack을 연결하는 장애 증거다.
`RUNNABLE`, `BLOCKED`, `WAITING`을 CPU·락·pool·외부 I/O 지표와 함께 해석해야 한다.
한 장보다 짧은 간격의 세 장을 비교하고, 같은 스레드 그룹의 변화와 락 소유자를 먼저 찾는다.
질문이 heap·GC·CPU profiling이라면 thread dump만 반복하지 말고 목적에 맞는 도구로 전환한다.

## 참고한 공식 문서

- [Oracle JDK 21 - The jcmd Command](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jcmd.html)
- [Java SE API - Thread.State](https://docs.oracle.com/en/java/javase/25/docs/api/java.base/java/lang/Thread.State.html)
- [Oracle Java SE 21 Troubleshooting Guide](https://docs.oracle.com/en/java/javase/21/troubleshoot/troubleshooting-guide.pdf)
