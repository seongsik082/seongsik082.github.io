---
title: "야간 정산 배치로 정리하는 프로세스와 스레드, start()와 run()의 차이"
date: 2026-10-05 08:55:00 +0900
tags: [Java, Thread, Backend]
excerpt: "정산 파일 변환 배치를 예로 프로세스와 스레드의 공유 범위, start()와 run()의 차이, ExecutorService와 종료 처리, 스레드 이름과 jcmd로 확인하는 법을 정리한다."
redirect_from:
  - /posts/java-thread-start-vs-run-file-upload/
  - /posts/java-process-thread-profile-request/
---

야간 정산 배치는 보통 하루치 거래를 집계한 뒤 지점이나 거래처별 정산 결과를 파일로 만들어 공유 위치에 내려놓는다. 집계는 대부분 DB가 처리하지만, 파일 변환은 애플리케이션이 행을 읽어 한 줄씩 써야 해서 시간이 오래 걸린다. 그래서 "지점별 변환을 스레드로 나눠 동시에 돌리자"는 생각이 자연스럽게 나온다. 이 생각을 코드로 옮기려면 세 가지를 정확히 알아야 한다. 프로세스와 스레드가 무엇을 공유하는지, `start()`와 `run()`이 어떻게 다른지, 그리고 배치가 끝날 때 스레드가 어떻게 정리되는지다. 이 글은 정산 파일 변환 하나를 따라가며 세 가지를 정리하고, 어떤 스레드에서 무엇이 실행되는지 로그와 `jcmd`로 확인하는 방법까지 다룬다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 병렬로 바꿨는데 아무것도 달라지지 않는 배치

다음 장면을 가정해 보자. 정산 배치는 매일 새벽 스케줄러가 `java -jar settlement-batch.jar`로 실행하는 독립 프로그램이다. 지점 수만큼 변환 작업이 있고, 개발자는 지점마다 `Thread`를 하나씩 만들어 변환을 맡겼다. 코드 리뷰에도 "지점별로 스레드를 나눴다"는 설명이 붙었다. 그런데 배치 소요 시간은 이전과 거의 같고, 변환 로그는 모두 `[main]` 스레드에서 지점 순서대로 찍혀 있다.

원인은 한 단어다. `worker.start()`가 아니라 `worker.run()`을 호출했다. 이것을 `start()`로 고치면 이번에는 다른 문제가 보인다. 메인 스레드가 변환 완료를 기다리지 않고 "정산 배치 종료" 로그를 먼저 남기고, 어떤 지점 변환에서 예외가 나도 배치의 종료 코드는 정상으로 남는다. 누군가 "배치 프로세스가 안 내려간다"며 스레드를 데몬으로 바꾸면, 이제는 JVM이 파일을 다 쓰기 전에 내려가 반쯤 쓰인 파일이 남을 수 있다.

세 문제는 서로 다른 버그처럼 보이지만 뿌리는 같다. 어떤 코드가 어느 실행 흐름에서 돌고, 그 흐름이 언제 끝나며, 끝났다는 사실을 누가 확인하는지를 정하지 않았다.

## 프로세스와 스레드는 무엇을 함께 쓰는가

운영체제가 프로그램을 실행하면 프로세스가 하나 생긴다. `java -jar`로 띄운 JVM 하나가 프로세스 하나다. 같은 서버에서 웹 애플리케이션이 다른 JVM으로 돌고 있다면 그것은 별개의 프로세스다. 프로세스마다 주소 공간이 분리되어 있으므로, 정산 배치가 메모리에 올린 집계 결과를 WAS가 직접 읽을 수는 없다. 두 프로세스가 데이터를 주고받으려면 DB, 파일, 네트워크처럼 프로세스 바깥의 통로가 필요하다.

스레드는 한 프로세스 안의 실행 흐름이다. JVM 안의 스레드들은 같은 힙을 공유한다. `new`로 만든 객체, `static` 필드, Spring 싱글톤 빈의 필드는 모든 스레드가 볼 수 있다. 반면 각 스레드는 자기만의 호출 스택을 가진다. 메서드의 지역 변수와 파라미터는 그 스택 프레임에 있으므로 호출한 스레드만 쓴다.

| 구분 | 프로세스 (JVM 하나) | 스레드 (JVM 안의 실행 흐름) |
|---|---|---|
| 메모리 | 프로세스마다 주소 공간이 분리된다 | 힙, `static` 필드, 열린 파일을 함께 쓴다 |
| 각자 가지는 것 | PID, 힙, 로딩된 클래스 | 호출 스택, 지역 변수, 이름과 상태 |
| 한쪽이 실패하면 | 다른 프로세스는 영향을 받지 않는다 | 잡히지 않은 예외는 그 스레드만 끝내지만, 공유 객체가 어중간한 상태로 남을 수 있다 |
| 데이터 전달 | DB, 파일, 소켓 | 공유 객체(동기화 필요), `Future` 같은 결과 객체 |

이 구분이 배치 코드에서 중요한 이유는 공유 범위 때문이다. 지점별 변환을 여러 스레드로 나누면서 처리 건수를 필드에 둔 `HashMap`에 모으면, 여러 스레드가 동기화 없이 같은 객체를 고친다. 반대로 변환에 필요한 값은 파라미터로 받고 결과는 각 작업이 반환하게 만들면 공유할 상태 자체가 사라진다. 뒤에서 `Callable`과 `Future`로 결과를 모으는 이유가 여기에 있다.

현재 프로세스와 스레드는 코드에서 바로 읽을 수 있다. `ProcessHandle.current().pid()`는 운영체제가 붙인 프로세스 ID를, `Thread.currentThread().getName()`은 지금 이 줄을 실행하는 스레드의 이름을 돌려준다. 둘 다 재시작하면 바뀌는 값이므로 업무 데이터로 저장하지 않는다. "어느 JVM의 어느 실행 흐름에서 나온 로그인가"를 좁히는 진단 정보로만 쓴다.

## start()는 실행 흐름을 만들고, run()은 메서드를 호출할 뿐이다

`Thread` 객체를 만드는 것과 스레드가 실행되는 것은 다른 일이다. `new Thread(task)`는 실행할 준비만 된 객체이고, `start()`를 호출해야 JVM이 새 실행 흐름에서 `run()`을 실행하도록 예약한다. Java 문서는 새로 시작된 스레드가 그것을 시작시킨 스레드와 동시에 실행된다고 설명한다. 반면 `run()`을 직접 호출하면 평범한 메서드 호출이다. 지금 실행 중인 스레드가 `run()` 본문을 끝까지 처리한 뒤 다음 줄로 넘어가며, 새 스레드는 생기지 않는다.

차이는 스레드 이름을 찍어 보면 바로 보인다.

```java
public class StartVersusRunDemo {

    public static void main(String[] args) throws InterruptedException {
        Runnable convertBranch = () -> System.out.printf(
                "[%s] 지점 A001 정산 파일 변환%n", Thread.currentThread().getName());

        Thread viaRun = new Thread(convertBranch, "settle-convert-run");
        viaRun.run();     // main 스레드가 그대로 실행한다
        System.out.printf("[%s] run() 호출 다음 줄%n", Thread.currentThread().getName());

        Thread viaStart = new Thread(convertBranch, "settle-convert-start");
        viaStart.start(); // 새 스레드에서 실행하도록 예약한다
        System.out.printf("[%s] start() 호출 다음 줄%n", Thread.currentThread().getName());

        viaStart.join();  // 변환이 끝날 때까지 기다린다
    }
}
```

실행 결과의 한 예는 다음과 같다.

```text
[main] 지점 A001 정산 파일 변환
[main] run() 호출 다음 줄
[main] start() 호출 다음 줄
[settle-convert-start] 지점 A001 정산 파일 변환
```

첫 줄의 스레드 이름이 `settle-convert-run`이 아니라 `main`이라는 점이 핵심이다. 스레드 객체에 이름을 붙였어도 `run()`을 직접 부르면 그 이름의 실행 흐름은 존재하지 않는다. 아래 두 줄의 순서는 실행할 때마다 바뀔 수 있다. `start()` 이후에는 두 스레드가 함께 움직이므로 어느 출력이 먼저인지 코드가 보장하지 않는다. 결과가 필요하면 순서를 기대하지 말고 `join()`이나 `Future.get()`처럼 완료를 기다리는 장치를 명시해야 한다.

함께 기억해 둘 규칙이 몇 가지 있다.

- 스레드는 한 번만 시작할 수 있다. 같은 객체에 `start()`를 두 번 부르면 `IllegalThreadStateException`이 나고, 끝난 스레드를 다시 시작할 수도 없다.
- 이름을 주지 않은 플랫폼 스레드는 `Thread-0`, `Thread-1` 같은 자동 이름을 받는다. 로그만 봐서는 무슨 작업인지 알 수 없으므로 역할이 드러나는 이름을 붙인다.
- `run()`을 직접 호출해야 하는 경우는 거의 없다. 같은 스레드에서 실행하려는 의도라면 `Runnable`을 바로 호출하는 편이 읽는 사람을 헷갈리게 하지 않는다.

## 로그에 스레드 이름을 남기는 설정

데모처럼 `printf`로 이름을 찍는 것은 학습용이다. 실제 배치에서는 로깅 패턴에 스레드 이름을 넣어 두면 모든 로그 줄이 실행 흐름을 드러낸다. Spring Boot의 기본 콘솔 패턴에는 이미 스레드 이름이 들어 있지만, 팀에서 패턴을 바꿔 쓰는 경우가 많으니 직접 확인한다. Logback에서는 `%thread`가 스레드 이름이다.

```yaml
logging:
  pattern:
    console: "%d{HH:mm:ss.SSS} [%thread] %-5level %logger{36} - %msg%n"
```

이 패턴에서 병렬 변환이 제대로 돌면 로그는 다음과 같은 모양이 된다.

```text
02:00:03.114 [main] INFO  c.e.s.SettlementFileBatch - 정산 파일 변환 시작: branches=4
02:00:03.120 [settle-convert-1] INFO  c.e.s.SettlementFileConverter - 변환 시작: branch=A001
02:00:03.121 [settle-convert-2] INFO  c.e.s.SettlementFileConverter - 변환 시작: branch=A002
02:00:05.402 [settle-convert-1] INFO  c.e.s.SettlementFileConverter - 변환 완료: branch=A001
02:00:05.977 [main] INFO  c.e.s.SettlementFileBatch - 정산 파일 변환 종료: succeeded=4, failed=0
```

변환 로그에 `[main]`만 보인다면 변환이 전혀 갈라지지 않았다는 뜻이다. `[Thread-7]` 같은 이름이 보이면 이름 없는 스레드를 직접 만드는 코드가 어딘가 있다. 스레드 이름은 "누가 이 일을 했는가"를 알려 주는 가장 값싼 진단 정보다.

## 직접 만든 Thread 대신 ExecutorService를 쓰는 이유

`start()`로 고치면 병렬 실행은 된다. 하지만 지점마다 `new Thread(...).start()`를 하는 구조에는 세 가지 빈칸이 남는다.

첫째, 스레드 수에 상한이 없다. 지점이 수백 개면 스레드도 수백 개가 된다. 스레드마다 스택이 잡히고, 변환 작업마다 파일 핸들과 버퍼가 열린다. 작업이 DB 커넥션까지 쓴다면 커넥션 풀이 먼저 바닥난다. 병렬도는 CPU 코어, 디스크, DB가 감당할 수 있는 수준으로 제한해야 한다.

둘째, 결과와 예외가 메인 스레드로 돌아오지 않는다. `run()` 안에서 던진 예외는 그 스레드만 끝내고, 기본 처리기가 표준 에러에 스택 트레이스를 남길 뿐이다. 메인 스레드는 어느 지점이 실패했는지 모른 채 정상 종료한다. 스케줄러가 종료 코드로 성공 여부를 판단한다면 실패가 그대로 묻힌다.

셋째, 종료 시점을 관리하는 코드가 없다. 모든 스레드에 `join()`을 거는 코드를 손으로 써야 하고, 하나라도 빠뜨리면 순서가 꼬인다.

`ExecutorService`는 이 빈칸을 채우는 표준 도구다. 고정 크기 풀로 병렬도를 제한하고, `Callable`이 반환한 결과와 던진 예외를 `Future`로 돌려받고, `shutdown()`과 `awaitTermination()`으로 종료를 명시한다.

```java
public class SettlementFileBatch {

    private static final Logger log = LoggerFactory.getLogger(SettlementFileBatch.class);

    private final SettlementFileConverter converter;
    private final int parallelism;

    public SettlementFileBatch(SettlementFileConverter converter, int parallelism) {
        this.converter = converter;
        this.parallelism = parallelism;
    }

    public BatchResult convertAll(LocalDate settleDate, List<String> branchCodes) throws InterruptedException {
        ExecutorService pool = Executors.newFixedThreadPool(parallelism, namedThreads("settle-convert-"));
        try {
            Map<String, Future<Path>> futures = new LinkedHashMap<>();
            for (String branchCode : branchCodes) {
                // 필요한 값은 파라미터로 넘기고, 결과는 반환값으로 받는다
                futures.put(branchCode, pool.submit(() -> converter.convert(settleDate, branchCode)));
            }

            List<String> failed = new ArrayList<>();
            for (Map.Entry<String, Future<Path>> entry : futures.entrySet()) {
                try {
                    Path file = entry.getValue().get();      // 해당 지점 변환이 끝날 때까지 기다린다
                    log.info("변환 완료: branch={}, file={}", entry.getKey(), file);
                } catch (ExecutionException e) {            // 작업 안에서 던진 예외가 여기로 온다
                    failed.add(entry.getKey());
                    log.error("변환 실패: branch={}", entry.getKey(), e.getCause());
                }
            }
            return new BatchResult(branchCodes.size() - failed.size(), List.copyOf(failed));
        } finally {
            shutdownAndAwait(pool);
        }
    }

    private static ThreadFactory namedThreads(String prefix) {
        AtomicInteger sequence = new AtomicInteger(1);
        return task -> {
            Thread thread = new Thread(task, prefix + sequence.getAndIncrement());
            thread.setDaemon(false);   // 파일을 쓰는 작업은 데몬으로 두지 않는다
            return thread;
        };
    }

    private static void shutdownAndAwait(ExecutorService pool) {
        pool.shutdown();                                     // 새 작업을 받지 않는다
        try {
            if (!pool.awaitTermination(30, TimeUnit.MINUTES)) {
                pool.shutdownNow();                          // 남은 작업에 인터럽트를 보낸다
                if (!pool.awaitTermination(1, TimeUnit.MINUTES)) {
                    log.error("변환 스레드가 제한 시간 안에 끝나지 않았다");
                }
            }
        } catch (InterruptedException e) {
            pool.shutdownNow();
            Thread.currentThread().interrupt();              // 인터럽트 상태를 되살린다
        }
    }
}

record BatchResult(int succeeded, List<String> failedBranches) {
    boolean hasFailure() {
        return !failedBranches.isEmpty();
    }
}
```

배치의 `main` 메서드는 `convertAll`이 돌려준 `BatchResult`를 보고 `System.exit(result.hasFailure() ? 1 : 0)`처럼 종료 코드를 정한다. 그래야 스케줄러와 모니터링이 실패를 실패로 본다. `shutdownAndAwait`는 `ExecutorService` 문서에 실린 2단계 종료 예제와 같은 구조다. 먼저 `shutdown()`으로 새 작업을 막고 기다린 뒤, 제한 시간을 넘기면 `shutdownNow()`로 인터럽트를 보낸다. `shutdownNow()`는 최선의 시도일 뿐이어서 인터럽트에 반응하지 않는 작업은 끝나지 않을 수 있다는 점도 문서에 적혀 있다.

Java 21을 쓴다면 `ExecutorService`가 `AutoCloseable`이므로 try-with-resources로 감쌀 수 있다. 다만 `close()`는 모든 작업이 끝날 때까지 제한 시간 없이 기다린다. 변환이 멈춰 버리면 배치도 같이 멈추므로, 시간 창이 정해진 야간 배치에서는 위처럼 제한 시간을 직접 두는 쪽이 안전하다.

Spring Boot 애플리케이션 안에서 같은 일을 한다면 `ExecutorService`를 직접 만들기보다 `ThreadPoolTaskExecutor`를 빈으로 등록해 컨테이너가 종료를 관리하게 하는 편이 낫다. Spring Batch를 쓰고 있다면 파티셔닝이나 멀티스레드 Step처럼 프레임워크가 제공하는 병렬 처리 방식을 먼저 검토한다.

선택지를 나란히 놓으면 다음과 같다.

| 방법 | 맞는 경우 | 쓰지 말아야 할 때 |
|---|---|---|
| 현재 스레드에서 순차 실행 | 지점 수가 적거나, 병목이 DB 한 곳이라 병렬 이득이 없을 때 | 배치 시간 창을 넘긴다는 것이 확인됐을 때 |
| `new Thread().start()` | 학습용 코드, 프로그램 수명 동안 하나만 도는 보조 스레드 | 작업 수가 입력에 따라 늘어나거나, 결과와 예외를 모아야 할 때 |
| 고정 크기 `ExecutorService` | 독립 실행 배치에서 병렬도를 제한하고 결과를 모을 때 | Spring 컨테이너 안이라 수명 관리를 컨테이너에 맡길 수 있을 때 |
| 프로세스 분리 (지점 그룹별 JVM) | 한 그룹의 실패가 다른 그룹을 막으면 안 되거나, 서버를 나눠 돌릴 때 | 실행·모니터링 대상이 늘어나는 비용을 감당하기 어렵고 데이터 공유가 많을 때 |

## 데몬 스레드와 배치 종료

데몬 스레드를 제대로 쓰려면 JVM이 언제 내려가는지부터 알아야 한다. Java 문서에 따르면 JVM은 살아 있는 비데몬 스레드가 처음으로 0개가 될 때, `System.exit`가 호출될 때, 또는 운영체제 신호 같은 외부 이벤트를 받았을 때 종료 절차를 시작한다. 데몬 스레드는 이 계산에 들어가지 않는다. 데몬 스레드가 아직 일하고 있어도 비데몬 스레드가 모두 끝나면 JVM은 종료 절차에 들어간다.

더 중요한 것은 종료되는 순간이다. `Runtime` 문서는 JVM이 종료되면 데몬이든 아니든 모든 스레드가 더 이상 Java 코드를 실행하지 못하며, 이때 `finally` 블록도 실행되지 않고 try-with-resources로 연 자원도 닫히지 않는다고 명시한다. 파일 변환 스레드를 데몬으로 만들면 메인 스레드가 먼저 끝나는 순간 버퍼를 비우지 못한 파일이 남는다. 다음 날 담당자가 받는 파일은 열리지 않거나, 더 나쁘게는 열리지만 행이 빠져 있다.

반대 방향의 사고도 있다. `Executors.newFixedThreadPool`이 기본으로 만드는 스레드는 비데몬이다. `shutdown()`을 호출하지 않으면 작업이 다 끝나도 풀 스레드가 다음 작업을 기다리며 살아 있으므로 JVM이 내려가지 않는다. 배치 프로세스가 계속 떠 있으면 다음 날 스케줄러가 이전 실행이 아직 진행 중이라며 새 실행을 건너뛰거나, 같은 배치 두 개가 겹쳐 돌 수 있다. 참고로 새 스레드는 만든 스레드의 데몬 여부를 물려받는다. `main`에서 만든 스레드는 따로 지정하지 않으면 비데몬이다.

정리하면 파일을 쓰거나 DB에 반영하는 작업은 비데몬 스레드에서 돌리고, 종료는 `shutdown()`과 `awaitTermination()`으로 명시적으로 기다린다. 데몬 스레드는 진행률을 주기적으로 찍는 감시 작업처럼 중간에 끊겨도 잃을 것이 없는 일에만 쓴다.

종료 신호도 고려해야 한다. 운영자가 배치를 중지하거나 서버가 재시작되어 프로세스가 종료 신호를 받으면 종료 절차가 시작되고, 등록된 셧다운 훅이 살아 있는 다른 스레드와 함께 실행된다. 훅이 모두 끝나면 JVM은 남은 스레드를 기다리지 않고 종료된다. 그래서 훅에서는 풀에 `shutdownNow()`로 인터럽트를 보내고 짧게 기다리는 정도만 하고, 변환 코드는 인터럽트를 받으면 쓰던 임시 파일을 지우고 빠져나오게 만든다. 강제 종료처럼 훅조차 실행되지 않는 경우까지 대비하려면 파일을 임시 이름으로 쓴 뒤 다 쓰고 나서 `Files.move`로 최종 이름으로 옮긴다. 같은 파일 시스템 안이라면 `StandardCopyOption.ATOMIC_MOVE`를 줄 수 있다. 이렇게 하면 중간에 끊겨도 완성되지 않은 파일이 최종 이름으로 보이는 일은 막는다.

## 어떻게 확인하나

### 테스트로 실행 스레드를 고정한다

가장 먼저 `run()`과 `start()`, 그리고 `Future`로 예외가 돌아오는 동작을 테스트로 고정한다. JUnit 5와 AssertJ 기준이다.

```java
class ThreadExecutionTest {

    @Test
    void run은_호출한_스레드에서_동기로_실행된다() {
        AtomicReference<String> executedOn = new AtomicReference<>();
        Thread worker = new Thread(
                () -> executedOn.set(Thread.currentThread().getName()), "settle-convert-test");

        worker.run();

        assertThat(executedOn.get()).isEqualTo(Thread.currentThread().getName());
        assertThat(worker.getState()).isEqualTo(Thread.State.NEW);   // 한 번도 시작되지 않았다
    }

    @Test
    void start는_이름을_붙인_새_스레드에서_실행된다() throws InterruptedException {
        AtomicReference<String> executedOn = new AtomicReference<>();
        Thread worker = new Thread(
                () -> executedOn.set(Thread.currentThread().getName()), "settle-convert-test");

        worker.start();
        worker.join(1_000);

        assertThat(executedOn.get()).isEqualTo("settle-convert-test");
        assertThatThrownBy(worker::start).isInstanceOf(IllegalThreadStateException.class);
    }

    @Test
    void 변환_작업의_예외는_Future로_돌아온다() throws InterruptedException {
        ExecutorService pool = Executors.newFixedThreadPool(1);
        try {
            Future<Path> future = pool.submit(() -> {
                throw new IOException("정산 파일 쓰기 실패");
            });

            assertThatThrownBy(future::get)
                    .isInstanceOf(ExecutionException.class)
                    .hasCauseInstanceOf(IOException.class);
        } finally {
            pool.shutdown();
            pool.awaitTermination(5, TimeUnit.SECONDS);
        }
    }
}
```

첫 테스트에서 `run()`을 부른 뒤에도 스레드 상태가 `NEW`라는 점을 확인한다. 실행은 됐지만 스레드는 시작된 적이 없다는 뜻이다. 두 번째 테스트는 이름 붙은 새 스레드에서 실행됐는지와 두 번째 `start()`가 거부되는지를 함께 본다.

### 로그에서 스레드별로 세어 본다

배치 로그에서 변환 시작 줄이 어느 스레드에서 나왔는지 세어 보면 병렬 실행 여부를 바로 알 수 있다. 앞의 로그 패턴이라면 두 번째 칸이 스레드 이름이다.

```bash
grep "변환 시작" settlement-batch.log | awk '{print $2}' | sort | uniq -c
```

`[settle-convert-1]`부터 풀 크기만큼의 이름이 고르게 나오면 정상이다. `[main]` 한 줄만 나오면 `run()`을 호출했거나 순차 루프로 돌고 있다. `[Thread-N]`이나 `[pool-N-thread-M]`이 나오면 이름 없는 스레드나 이름 없는 풀을 만드는 코드가 있으니 `new Thread(`와 `Executors.new`를 소스에서 검색한다.

### jcmd로 살아 있는 스레드를 본다

배치가 "종료" 로그를 남겼는데 프로세스가 계속 떠 있거나 변환이 멈춘 것 같으면, 같은 서버에서 JVM을 실행한 사용자와 같은 권한으로 `jcmd`를 실행한다. 컨테이너 안의 JVM이라면 `jcmd -l`에 나오지 않을 수 있으므로 `ps`로 PID를 찾는다.

```bash
jcmd -l
jcmd <pid> Thread.print -l > settle-dump-1.txt
grep -A 14 '"settle-convert-' settle-dump-1.txt
```

작업이 다 끝났는데 `shutdown()`을 빠뜨렸다면 풀 스레드가 다음과 같이 큐에서 새 작업을 기다리고 있다. (발췌이며 주소, 시간, 줄 번호는 생략했다.)

```text
"settle-convert-3" #34 [21408] prio=5 os_prio=0 cpu=... elapsed=... tid=0x... nid=21408 waiting on condition  [0x...]
   java.lang.Thread.State: WAITING (parking)
	at jdk.internal.misc.Unsafe.park(java.base@21/Native Method)
	- parking to wait for  <0x...> (a java.util.concurrent.locks.AbstractQueuedSynchronizer$ConditionObject)
	at java.util.concurrent.locks.LockSupport.park(java.base@21/LockSupport.java)
	...
	at java.util.concurrent.LinkedBlockingQueue.take(java.base@21/LinkedBlockingQueue.java)
	at java.util.concurrent.ThreadPoolExecutor.getTask(java.base@21/ThreadPoolExecutor.java)
	at java.util.concurrent.ThreadPoolExecutor.runWorker(java.base@21/ThreadPoolExecutor.java)
	at java.util.concurrent.ThreadPoolExecutor$Worker.run(java.base@21/ThreadPoolExecutor.java)
	at java.lang.Thread.run(java.base@21/Thread.java)

"DestroyJavaVM" #37 [21390] prio=5 os_prio=0 cpu=... elapsed=... tid=0x... nid=21390 waiting on condition  [0x0000000000000000]
   java.lang.Thread.State: RUNNABLE
```

읽는 순서는 이렇다. 헤더 줄에 `daemon`이라는 표시가 없으면 비데몬 스레드이고, 이 스레드가 살아 있는 한 JVM은 종료 절차에 들어가지 않는다. 스택이 `LinkedBlockingQueue.take`와 `ThreadPoolExecutor.getTask`에서 멈춰 있으면 일을 하는 중이 아니라 다음 작업을 기다리는 유휴 상태다. `main` 스레드는 보이지 않고 `DestroyJavaVM` 스레드가 보인다면 `main` 메서드는 이미 끝났고 JVM이 비데몬 스레드가 끝나기를 기다리는 중이다. 이 세 가지가 함께 보이면 `shutdown()` 누락을 의심한다. 반대로 변환 스레드가 `RUNNABLE`이고 스택 맨 위가 파일 쓰기나 DB 조회라면 일이 진행 중이거나 느린 것이므로, 몇 초 간격으로 덤프를 두세 번 받아 스택이 바뀌는지 비교한다.

### 실패했을 때 처음 볼 곳

- 변환이 빨라지지 않았다: 로그의 스레드 이름부터 본다. `[main]`뿐이면 `run()` 호출이나 순차 실행이다.
- 배치는 성공으로 끝났는데 파일이 빠졌다: 작업의 예외를 `Future.get()`으로 회수하는지, 실패가 종료 코드에 반영되는지 본다.
- 프로세스가 내려가지 않는다: 스레드 덤프에서 이름 붙은 비데몬 풀 스레드가 큐 대기 중인지 본다.
- 파일이 잘려 있다: 변환 스레드가 데몬인지(덤프 헤더의 `daemon`), 임시 파일 후 이동 방식을 쓰는지 본다.

## 정리

- 지점별 변환처럼 서로 독립적인 작업만 스레드로 나누고, 공유 상태 대신 반환값으로 결과를 모은다.
- 새 실행 흐름이 필요하면 `start()`를 쓰고, 로그의 스레드 이름으로 실제로 갈라졌는지 확인한다.
- 스레드를 직접 만들지 말고 크기를 정한 `ExecutorService`에 역할이 드러나는 이름의 스레드로 맡긴다.
- `Future.get()`으로 예외를 회수해 배치의 종료 코드에 반영한다.
- 파일과 DB를 다루는 작업은 비데몬 스레드에서 돌리고, `shutdown()`과 `awaitTermination()`으로 종료를 기다린다.
- 프로세스가 안 끝나거나 멈춘 것 같으면 `jcmd <pid> Thread.print`로 어떤 이름의 스레드가 어디서 기다리는지 먼저 본다.

## 참고한 공식 문서

- [Java SE 21 API: Thread](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Thread.html) — `start()`와 `run()`의 차이, 한 번만 시작할 수 있다는 규칙, 데몬 여부와 자동 스레드 이름
- [Java SE 21 API: ExecutorService](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ExecutorService.html) — `shutdown()`, `shutdownNow()`, `awaitTermination()`과 2단계 종료 예제, `close()`의 대기 방식
- [Java SE 21 API: Runtime](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/lang/Runtime.html) — 종료 절차가 시작되는 조건, 셧다운 훅, JVM 종료 시 `finally`가 실행되지 않는다는 설명
- [JDK 21 Tool Specifications: jcmd](https://docs.oracle.com/en/java/javase/21/docs/specs/man/jcmd.html) — `jcmd -l`, `Thread.print`의 `-l` 옵션, 같은 머신·같은 사용자로 실행해야 한다는 조건
