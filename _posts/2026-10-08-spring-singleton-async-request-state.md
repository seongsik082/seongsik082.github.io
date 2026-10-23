---
title: "결재 승인 메일 발송으로 보는 싱글톤 빈의 요청 상태와 @Async의 경계"
date: 2026-10-08 08:55:00 +0900
tags: [Spring, Java, Async, Backend]
excerpt: "결재 승인 결과 메일을 예로 싱글톤 빈 필드에 요청 상태를 두면 섞이는 이유, @Async의 프록시 동작과 전용 executor, 예외 처리, 커밋 후 발송까지 정리한다."
redirect_from:
  - /posts/spring-async-comment-notification/
  - /posts/spring-singleton-notification-request-state/
---

전자결재에서 문서가 최종 승인되거나 반려되면 기안자에게 결과 메일을 보낸다. 처음에는 승인 처리와 메일 발송을 한 메서드에서 차례로 실행하지만, 메일 서버 응답이 느린 날에는 결재자의 승인 버튼까지 같이 느려진다. 그래서 메일 발송을 `@Async`로 떼어 내게 되는데, 이때 Spring 빈의 기본 동작 두 가지를 정확히 알아야 한다. 하나는 서비스 빈이 기본적으로 싱글톤이라 모든 요청 스레드가 같은 객체를 쓴다는 점이고, 다른 하나는 `@Async`가 프록시를 거친 호출에만 적용된다는 점이다. 이 글은 승인 결과 메일 하나를 따라가며 요청별 상태가 섞이는 문제를 테스트로 재현하고, `@Async`를 설정할 때 놓치기 쉬운 executor, 예외, 트랜잭션 경계를 차례로 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 승인 요청 하나가 지나가는 길

결재자가 `POST /approvals/{documentId}/approve`를 보내면 다음 순서로 처리된다고 하자.

1. 톰캣 요청 스레드 하나(`http-nio-8080-exec-N`)가 요청을 맡는다.
2. `ApprovalService.approve()`가 트랜잭션 안에서 문서 상태를 바꾸고 결재 이력을 남긴다.
3. 기안자 메일 주소와 결과로 메일 제목과 본문을 만든다.
4. 메일 서버에 발송한다.
5. 결재자에게 응답한다.

3과 4가 느리면 5가 늦어진다. 같은 시각에 다른 결재자가 다른 문서를 승인하면 두 요청은 서로 다른 요청 스레드에서 실행되지만, `ApprovalService`와 메일 서비스는 같은 객체를 쓴다. Spring 문서에 따르면 싱글톤은 기본 스코프이고, 컨테이너는 빈 정의마다 공유 인스턴스 하나만 관리한다. 같은 문서는 상태를 가진 빈에는 prototype을, 상태가 없는 빈에는 singleton을 쓰라고 권한다. 서비스 빈을 싱글톤으로 쓰는 한 그 빈은 요청별 상태를 가지면 안 된다는 뜻이다.

## 싱글톤 빈 필드에 요청 상태를 두면

다음 코드는 private 메서드마다 인자를 넘기기 번거로워 요청 값을 필드에 담아 둔 메일 서비스다. `MailGateway`는 SMTP나 사내 메일 API를 감싼 인터페이스, `ApprovalMailRenderer`는 본문 템플릿을 채우는 컴포넌트다.

```java
public enum ApprovalResult { APPROVED, REJECTED }

public record ApprovalMailCommand(Long documentId, String drafterEmail, ApprovalResult result) {}

public interface MailGateway {
    void send(String to, String subject, String body);
}

public interface ApprovalMailRenderer {
    String render(ApprovalResult result);
}

@Service
public class ApprovalMailService {

    private final MailGateway mailGateway;
    private final ApprovalMailRenderer renderer;

    // 요청마다 달라지는 값을 필드에 두었다. 모든 요청 스레드가 이 두 칸을 함께 쓴다.
    private Long documentId;
    private String drafterEmail;

    public ApprovalMailService(MailGateway mailGateway, ApprovalMailRenderer renderer) {
        this.mailGateway = mailGateway;
        this.renderer = renderer;
    }

    public void sendResult(ApprovalMailCommand command) {
        this.documentId = command.documentId();
        this.drafterEmail = command.drafterEmail();

        String body = renderer.render(command.result());   // 템플릿 조회처럼 시간이 걸리는 구간
        mailGateway.send(drafterEmail, subject(), body);
    }

    private String subject() {
        return "[결재] 문서 " + documentId + " 처리 결과";
    }
}
```

문서 101의 승인 요청 A가 필드에 값을 쓰고 본문을 만드는 사이, 문서 202의 반려 요청 B가 같은 필드를 덮어쓴다. A가 본문 생성을 마치고 `drafterEmail`과 `subject()`를 읽으면 B의 값을 읽는다. 결국 B의 기안자는 같은 문서 메일을 두 통 받고 A의 기안자는 아무것도 받지 못한다. 결재 문서 번호나 반려 사유가 다른 사람에게 가는 것은 단순한 버그가 아니라 정보 노출이다.

이 문제는 로컬에서 한 번씩 호출해서는 보이지 않는다. 두 요청이 겹치는 순간에만 드러나기 때문이다. `Thread.sleep`으로 겹치기를 기대하면 테스트가 들쭉날쭉해지므로, 겹치는 지점을 `CyclicBarrier`로 고정한다.

```java
class ApprovalMailServiceConcurrencyTest {

    record SentMail(String to, String subject) {}

    static class RecordingMailGateway implements MailGateway {
        private final List<SentMail> sent = new CopyOnWriteArrayList<>();

        @Override
        public void send(String to, String subject, String body) {
            sent.add(new SentMail(to, subject));
        }

        List<SentMail> sent() {
            return sent;
        }
    }

    @Test
    void 동시에_처리된_두_문서의_메일은_각자의_기안자에게_간다() throws Exception {
        RecordingMailGateway gateway = new RecordingMailGateway();
        CyclicBarrier bothRendering = new CyclicBarrier(2);
        ApprovalMailRenderer renderer = result -> {
            awaitBoth(bothRendering);   // 두 요청이 모두 필드를 쓴 뒤에야 본문 생성을 마친다
            return "처리 결과: " + result;
        };
        ApprovalMailService service = new ApprovalMailService(gateway, renderer);

        ExecutorService requests = Executors.newFixedThreadPool(2);
        try {
            Future<?> a = requests.submit(() -> service.sendResult(
                    new ApprovalMailCommand(101L, "drafter-a@corp.example", ApprovalResult.APPROVED)));
            Future<?> b = requests.submit(() -> service.sendResult(
                    new ApprovalMailCommand(202L, "drafter-b@corp.example", ApprovalResult.REJECTED)));
            a.get(5, TimeUnit.SECONDS);
            b.get(5, TimeUnit.SECONDS);
        } finally {
            requests.shutdownNow();
        }

        assertThat(gateway.sent()).containsExactlyInAnyOrder(
                new SentMail("drafter-a@corp.example", "[결재] 문서 101 처리 결과"),
                new SentMail("drafter-b@corp.example", "[결재] 문서 202 처리 결과"));
    }

    private static void awaitBoth(CyclicBarrier barrier) {
        try {
            barrier.await(5, TimeUnit.SECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(e);
        } catch (BrokenBarrierException | TimeoutException e) {
            throw new IllegalStateException(e);
        }
    }
}
```

가짜 렌더러는 두 스레드가 모두 도착할 때까지 기다린다. 두 번째 스레드가 도착했을 때는 이미 두 요청이 필드를 한 번씩 쓴 뒤이므로, 이어서 필드를 읽는 두 스레드는 나중에 쓰인 값을 함께 본다. 필드 버전에서는 같은 수신자에게 두 통이 가서 이 테스트가 실패한다.

고치는 방법은 요청 값을 필드에서 빼는 것이다. 필드에는 여러 요청이 함께 써도 되는 의존성만 `final`로 남기고, 요청 값은 파라미터와 지역 변수로만 흐르게 한다.

```java
@Service
public class ApprovalMailService {

    private final MailGateway mailGateway;          // 공유해도 되는 의존성만 필드에 둔다
    private final ApprovalMailRenderer renderer;

    public ApprovalMailService(MailGateway mailGateway, ApprovalMailRenderer renderer) {
        this.mailGateway = mailGateway;
        this.renderer = renderer;
    }

    public void sendResult(ApprovalMailCommand command) {
        String body = renderer.render(command.result());
        mailGateway.send(command.drafterEmail(), subjectOf(command.documentId()), body);
    }

    private static String subjectOf(Long documentId) {
        return "[결재] 문서 " + documentId + " 처리 결과";
    }
}
```

같은 테스트가 이제 통과한다. 필드를 `static`으로 바꾸는 것은 해결책이 아니다. 클래스에 하나뿐인 칸이 되어 더 넓게 공유될 뿐이다. 요청 상태를 둘 곳의 선택지를 비교하면 다음과 같다.

| 방법 | 맞는 경우 | 쓰지 말아야 할 때 |
|---|---|---|
| 파라미터, 지역 변수, 불변 커맨드 객체 | 대부분의 서비스 로직. 기본값으로 쓴다 | 추적 ID처럼 모든 계층에 횡단으로 필요한 값까지 인자로 끌고 다녀야 할 때 |
| `ThreadLocal`, 로깅 MDC | 로그 추적 ID처럼 업무 로직과 무관한 횡단 정보 | 업무 데이터 전달. 풀 스레드에서 `remove()`를 빠뜨리면 다음 요청으로 값이 새고, `@Async` 스레드로는 자동으로 넘어가지 않는다 |
| request 스코프 빈 | 한 HTTP 요청 동안 여러 빈이 같은 요청 정보를 봐야 할 때 | `@Async`나 배치 스레드처럼 HTTP 요청에 묶이지 않은 스레드에서 접근할 때. 요청 컨텍스트가 없다는 예외가 난다 |
| prototype 스코프 빈 | 상태를 가진 객체를 쓸 때마다 새로 받아야 할 때 | 싱글톤에 주입해 두고 쓸 때. 주입 시점에 한 번만 만들어지므로 결국 공유된다 |

요청 값이 아니어도 위험한 필드가 있다. 메일 본문에 승인 일시를 넣으려고 `SimpleDateFormat`을 필드로 두면, 이 클래스는 스레드 안전하지 않아서 동시에 포맷할 때 엉뚱한 날짜가 찍힐 수 있다. 불변 객체인 `DateTimeFormatter`를 `static final`로 두면 같은 일을 안전하게 할 수 있다. 템플릿을 한 번만 읽으려고 `HashMap` 필드에 캐시를 채우는 코드도 같은 이유로 위험하다. 필드를 볼 때는 "요청마다 바뀌는 값인가"와 함께 "여러 스레드가 동시에 호출해도 되는 객체인가"를 같이 묻는다.

## @Async는 프록시를 거친 호출에만 적용된다

이제 상태 없는 메일 서비스를 비동기로 실행하자. `@Configuration` 클래스에 `@EnableAsync`를 붙이고 메서드에 `@Async`를 단다. 여기서 Spring 문서가 강조하는 조건이 있다. `@Async`의 기본 처리 방식은 프록시이고, 프록시는 자기를 통과하는 호출만 가로챈다. 같은 클래스 안에서 `this.sendResultMail()`처럼 부르면 가로채지지 않는다.

```java
@Service
public class ApprovalService {

    @Transactional
    public void approve(Long documentId, Long approverId) {
        ApprovalMailCommand command = changeStatus(documentId, approverId);  // 문서 상태 변경 후 메일 내용 준비
        sendResultMail(command);   // this 호출: 프록시를 거치지 않아 요청 스레드에서 동기로 실행된다
    }

    @Async("approvalMailExecutor")
    public void sendResultMail(ApprovalMailCommand command) {
        // ...
    }
}
```

이 코드는 오류 없이 돌아가지만 메일은 요청 스레드에서 동기로 나간다. 애너테이션이 조용히 무시되므로 로그의 스레드 이름으로만 알아챌 수 있다. 같은 이유로 `private` 메서드에 붙인 `@Async`, `new`로 직접 만든 객체의 `@Async`도 동작하지 않는다. `@Transactional`도 같은 원리로 빠진다는 점은 [같은 클래스에서 @Transactional을 다시 호출하면 트랜잭션이 빠지는 이유](/posts/spring-transactional-self-invocation-proxy-boundary/)에서 다뤘다.

가장 단순한 해결은 비동기로 실행할 메서드를 별도 빈으로 옮기는 것이다. 앞에서 만든 `ApprovalMailService`의 `sendResult`에 `@Async`를 달고, `ApprovalService`가 그 빈을 주입받아 호출하면 호출이 프록시를 지난다. AspectJ 위빙 모드로 바꾸면 같은 클래스 안의 호출도 가로챌 수 있지만, 빌드나 실행 설정에 위빙을 추가해야 하므로 메서드 하나 때문에 고를 방법은 아니다. 제대로 적용되면 로그의 스레드 이름이 바뀐다.

```text
10:15:02.311 [http-nio-8080-exec-3] INFO  c.e.a.ApprovalService - 결재 승인 완료: documentId=101
10:15:02.315 [approval-mail-1] INFO  c.e.a.ApprovalMailService - 결과 메일 발송 시작: documentId=101
```

두 번째 줄도 `http-nio-8080-exec-3`이라면 `@Async`가 적용되지 않은 것이다.

## 기본 executor에 맡기지 않는다

`@Async`에 executor를 지정하지 않으면 어디서 실행될까. `@EnableAsync` Javadoc에 따르면 Spring은 유일한 `TaskExecutor` 빈이나 이름이 `taskExecutor`인 `Executor` 빈을 찾고, 둘 다 없으면 `SimpleAsyncTaskExecutor`를 쓴다. 이 구현은 작업마다 새 스레드를 만들고 재사용하지 않으며, 기본으로 동시 실행 수 제한도 없다. Spring Boot는 `Executor` 빈이 없으면, 가상 스레드를 켜지 않은 경우 코어 스레드 8개짜리 `ThreadPoolTaskExecutor`를 자동 구성한다. 다만 Boot 문서의 설정 예시처럼 `queue-capacity`를 지정해야 제한 있는 큐가 된다. 메일 서버가 느려지면 발송 작업이 메모리 큐에 계속 쌓이고, 같은 executor를 쓰는 다른 비동기 작업까지 밀린다.

그래서 메일 발송에는 전용 executor를 둔다.

```java
@Configuration
@EnableAsync
public class AsyncConfig implements AsyncConfigurer {

    @Bean(name = "approvalMailExecutor")
    public ThreadPoolTaskExecutor approvalMailExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2);
        executor.setMaxPoolSize(4);
        executor.setQueueCapacity(200);                      // 큐가 차야 maxPoolSize까지 늘어난다
        executor.setThreadNamePrefix("approval-mail-");
        executor.setRejectedExecutionHandler(new ThreadPoolExecutor.CallerRunsPolicy());
        executor.setWaitForTasksToCompleteOnShutdown(true);  // 종료 시 큐에 남은 발송을 처리한다
        executor.setAwaitTerminationSeconds(30);
        return executor;
    }

    @Override
    public AsyncUncaughtExceptionHandler getAsyncUncaughtExceptionHandler() {
        return new ApprovalMailAsyncExceptionHandler();
    }
}
```

숫자는 예시다. 메일 서버가 허용하는 동시 연결 수와 발송량을 보고 정한다. 판단이 필요한 설정은 세 가지다.

- 거절 정책: 기본값인 `AbortPolicy`는 큐와 스레드가 모두 차면 제출하는 쪽에 `TaskRejectedException`을 던진다. 메일 하나 때문에 승인 요청이 오류로 보일 수 있으니 호출부에서 잡아 실패 기록으로 돌려야 한다. `CallerRunsPolicy`는 제출한 스레드가 직접 실행하므로 메일을 잃지 않지만, 그 순간 승인 응답이 발송 시간만큼 느려진다.
- 종료 대기: `waitForTasksToCompleteOnShutdown`의 기본값은 `false`다. 이 경우 애플리케이션을 내릴 때 큐에 남은 작업을 비우고, 그때까지 끝나지 않은 작업은 인터럽트한다(Spring 6.1부터는 그 전에 실행 중인 작업을 잠시 기다리는 단계가 있다). 배포할 때마다 대기 중인 메일이 사라질 수 있다는 뜻이다.
- 기본 executor와의 관계: Boot에서는 `Executor` 빈을 직접 등록하면 자동 구성 executor가 물러나고, 이름 없이 `@Async`만 붙인 다른 메서드도 등록한 빈을 쓰게 될 수 있다. 용도별 executor를 둔다면 `@Async("approvalMailExecutor")`처럼 이름을 항상 적는다.

비동기 작업이 메일 하나뿐이고 양도 적다면 전용 빈 대신 `spring.task.execution.pool.max-size`, `spring.task.execution.pool.queue-capacity` 같은 속성으로 자동 구성 executor의 큐를 제한하는 것으로 충분하다. 성격이 다른 비동기 작업이 섞이기 시작하면 그때 executor를 나눈다.

## void @Async의 예외는 호출자에게 돌아오지 않는다

`@Async` 메서드가 `void`를 반환하면 그 안에서 난 예외는 호출자에게 전달될 방법이 없다. Spring 문서에 따르면 기본 동작은 로그를 남기는 것뿐이다. 기본 처리기가 남기는 로그는 다음과 같은 모양이다.

```text
10:15:04.902 [approval-mail-1] ERROR o.s.a.i.SimpleAsyncUncaughtExceptionHandler - Unexpected exception occurred invoking async method: public void com.example.approval.ApprovalMailListener.onApprovalCompleted(com.example.approval.ApprovalCompletedEvent)
org.springframework.mail.MailSendException: Mail server connection failed
```

승인 API는 이미 200을 돌려줬으므로, 이 로그를 보지 않으면 누구도 실패를 모른다. `AsyncUncaughtExceptionHandler`를 등록하면 최소한 어떤 문서의 메일이 실패했는지 남길 수 있다. 아래 예시는 다음 절에서 만들 이벤트 객체 `ApprovalCompletedEvent`를 파라미터에서 찾아 문서 번호를 꺼낸다.

```java
public class ApprovalMailAsyncExceptionHandler implements AsyncUncaughtExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(ApprovalMailAsyncExceptionHandler.class);

    @Override
    public void handleUncaughtException(Throwable ex, Method method, Object... params) {
        String documentId = Arrays.stream(params)
                .filter(ApprovalCompletedEvent.class::isInstance)
                .map(p -> String.valueOf(((ApprovalCompletedEvent) p).documentId()))
                .findFirst()
                .orElse("unknown");
        log.error("비동기 작업 실패: method={}, documentId={}", method.getName(), documentId, ex);
    }
}
```

이 처리기는 모든 `void` `@Async` 메서드에 공통으로 걸리는 마지막 안전망이다. 재발송이 필요하다면 발송 코드 안에서 실패를 잡아 실패 이력으로 남기는 편이 맞다. 반환 타입을 `CompletableFuture<Void>`로 바꿔 호출부에서 `whenComplete`로 결과를 받는 방법도 있지만, 요청 스레드에서 `join()`이나 `get()`을 부르면 다시 동기 호출이 되므로 주의한다.

## 커밋되기 전에 메일이 나가는 문제

`approve()`는 `@Transactional`이다. 그 안에서 `@Async` 메서드를 부르면 발송 작업은 커밋을 기다리지 않고 바로 다른 스레드에서 시작된다. 트랜잭션은 스레드에 묶여 있으므로 발송 스레드는 승인 트랜잭션에 참여하지 않는다. 그래서 두 가지 일이 생길 수 있다. 메일을 보낸 뒤 승인 처리의 다음 단계에서 예외가 나 롤백되면, 존재하지 않는 승인을 알리는 메일이 이미 나간 상태가 된다. 또 발송 작업이 DB에서 문서를 다시 읽는다면 아직 커밋되지 않은 이전 상태를 볼 수 있다.

해결은 "커밋된 사실"만 알리는 것이다. 트랜잭션 안에서는 이벤트만 발행하고, 메일은 커밋 이후에 보낸다.

```java
public record ApprovalCompletedEvent(Long documentId, String drafterEmail, ApprovalResult result) {}

@Service
public class ApprovalService {

    private final ApprovalDocumentRepository documentRepository;
    private final ApplicationEventPublisher eventPublisher;

    public ApprovalService(ApprovalDocumentRepository documentRepository,
                           ApplicationEventPublisher eventPublisher) {
        this.documentRepository = documentRepository;
        this.eventPublisher = eventPublisher;
    }

    @Transactional
    public void approve(Long documentId, Long approverId) {
        ApprovalDocument document = documentRepository.findById(documentId)
                .orElseThrow(() -> new IllegalArgumentException("결재 문서가 없습니다: " + documentId));
        document.approve(approverId);   // 결재 차례와 권한 검사를 포함한다
        eventPublisher.publishEvent(new ApprovalCompletedEvent(
                documentId, document.getDrafterEmail(), document.getResult()));
    }
}

@Component
public class ApprovalMailListener {

    private final ApprovalMailService approvalMailService;

    public ApprovalMailListener(ApprovalMailService approvalMailService) {
        this.approvalMailService = approvalMailService;
    }

    @Async("approvalMailExecutor")
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT)
    public void onApprovalCompleted(ApprovalCompletedEvent event) {
        approvalMailService.sendResult(new ApprovalMailCommand(
                event.documentId(), event.drafterEmail(), event.result()));
    }
}
```

이제 `@Async`는 메일 서비스가 아니라 리스너에 붙는다. 이벤트에는 엔티티 대신 발송에 필요한 값만 담는다. 다른 스레드에서 지연 로딩이 일어날 여지를 없애기 위해서다. 이 구조에서 알아 둘 점이 있다.

- 트랜잭션 없이 발행된 이벤트는 기본적으로 버려진다. 누군가 `approve()`의 `@Transactional`을 지우면 메일이 조용히 사라진다. 트랜잭션 없이도 실행해야 한다면 `fallbackExecution = true`를 명시한다.
- `AFTER_COMMIT` 리스너를 `@Async` 없이 쓰면 커밋 직후 같은 스레드에서 실행된다. Javadoc 경고대로 이 시점의 데이터 접근은 원래 트랜잭션에 참여한 것으로 취급되어 변경이 커밋되지 않을 수 있다. 발송 이력을 DB에 남긴다면 `REQUIRES_NEW` 같은 새 트랜잭션에서 저장한다.
- 커밋 후 발송도 유실을 막지는 못한다. 커밋 직후 프로세스가 내려가면 메모리 큐에 있던 발송은 사라진다. 반드시 보내야 하는 메일이라면 같은 트랜잭션에서 발송 요청 행을 저장하고 별도 스케줄러가 보내는 방식을 검토한다. 판단 기준은 [Outbox pattern을 도입해야 하는 시점](/posts/outbox-pattern-when-to-adopt/)에 정리했다.

| 발송 방식 | 맞는 경우 | 쓰지 말아야 할 때 |
|---|---|---|
| 요청 스레드에서 동기 발송 | 발송량이 적고 메일 실패를 결재자에게 바로 보여 줘야 할 때 | 메일 서버 지연이 결재 응답 시간을 좌우할 때 |
| 트랜잭션 안에서 `@Async` 직접 호출 | 트랜잭션이 없는 단순 알림 | 메일 내용이 커밋 결과에 의존할 때 |
| `AFTER_COMMIT` 리스너 + `@Async` | 커밋된 사실만 알리고, 드문 유실은 재발송으로 수습할 수 있을 때 | 메일이 감사 근거라 유실이 허용되지 않을 때 |
| 발송 요청 테이블 + 스케줄러 | 반드시 보내야 하고 재시도 이력이 필요할 때 | 발송량이 적어 테이블과 스케줄러 운영 비용이 더 클 때 |

## 어떻게 확인하나

첫째, 동시성 재현 테스트를 돌린다.

```bash
./gradlew test --tests "*ApprovalMailServiceConcurrencyTest"
```

실패하면 빈 클래스의 `final`이 아닌 인스턴스 필드부터 본다. 아래 검색은 `private` 다음에 바로 타입이 오는 필드, 즉 `final`이 없는 필드를 찾는다.

```bash
grep -rnE "private (static )?[A-Z][A-Za-z0-9<>, ]* [a-z][A-Za-z0-9]*;" src/main/java
```

검색 결과가 서비스나 컴포넌트 클래스에 있다면 그 값이 모든 요청에 공통인 설정인지, 요청마다 바뀌는 값인지 하나씩 확인한다.

둘째, `@Async`가 적용됐는지 확인한다. 위의 로그 패턴에서 발송 로그의 스레드 이름이 `approval-mail-`로 시작해야 한다. 요청 스레드 이름이 찍혔다면 `@EnableAsync`가 있는지, 같은 클래스 안에서 호출하지 않았는지, 메서드가 `public`인지, 객체를 `new`로 만들지 않았는지를 이 순서로 본다. 빈이 프록시로 감싸졌는지는 테스트로 고정해 둘 수 있다.

```java
@SpringBootTest
class ApprovalMailAsyncWiringTest {

    @Autowired
    ApprovalMailListener listener;

    @Test
    void 메일_리스너는_프록시를_통해_호출된다() {
        assertThat(AopUtils.isAopProxy(listener)).isTrue();
    }
}
```

셋째, 발송이 밀릴 때는 스레드 덤프로 발송 스레드가 무엇을 기다리는지 본다.

```bash
jcmd <pid> Thread.print > mail-dump-1.txt
grep -A 12 '"approval-mail-' mail-dump-1.txt
```

```text
"approval-mail-2" #58 [31877] prio=5 os_prio=0 cpu=... elapsed=... tid=0x... nid=31877 runnable  [0x...]
   java.lang.Thread.State: RUNNABLE
	at sun.nio.ch.Net.poll(java.base@21/Native Method)
	at sun.nio.ch.NioSocketImpl.park(java.base@21/NioSocketImpl.java)
	at sun.nio.ch.NioSocketImpl.implRead(java.base@21/NioSocketImpl.java)
	at sun.nio.ch.NioSocketImpl.read(java.base@21/NioSocketImpl.java)
	...
	at org.springframework.mail.javamail.JavaMailSenderImpl.connectTransport(JavaMailSenderImpl.java)
	at org.springframework.mail.javamail.JavaMailSenderImpl.doSend(JavaMailSenderImpl.java)
	...
	at com.example.approval.SmtpMailGateway.send(SmtpMailGateway.java)
```

(발췌이며 주소, 시간, 줄 번호는 생략했다.) 모든 발송 스레드가 이렇게 소켓 읽기에 머물러 있고 몇 초 뒤 다시 받은 덤프에서도 그대로라면 메일 서버 응답을 기다리는 중이다. 이때는 스레드 수를 늘리기 전에 타임아웃부터 건다. Spring Boot 문서는 일부 메일 타임아웃의 기본값이 무한대라고 하며, `spring.mail.properties[mail.smtp.timeout]` 같은 속성으로 바꾸는 예를 든다.

## 정리

- 싱글톤 빈의 필드에는 공유해도 되는 의존성만 `final`로 두고, 요청 값은 파라미터와 불변 커맨드 객체로 넘긴다.
- 동시성 버그는 `CyclicBarrier`처럼 겹치는 지점을 고정한 테스트로 재현한다.
- `@Async`는 다른 빈을 통해 호출하고, 로그의 스레드 이름으로 실제로 갈라졌는지 확인한다.
- 기본 executor에 맡기지 말고 큐 크기, 거절 정책, 종료 대기를 정한 전용 executor를 이름으로 지정한다.
- `void` `@Async`의 예외는 `AsyncUncaughtExceptionHandler`로 남기고, 재발송이 필요하면 실패 이력을 따로 저장한다.
- 트랜잭션 결과를 알리는 메일은 `@TransactionalEventListener(phase = AFTER_COMMIT)`로 커밋 뒤에 보내고, 유실이 허용되지 않으면 발송 요청 테이블을 검토한다.

## 참고한 공식 문서

- [Spring Framework Reference: Bean Scopes](https://docs.spring.io/spring-framework/reference/core/beans/factory-scopes.html) — 싱글톤이 기본 스코프이며 공유 인스턴스 하나만 관리된다는 설명, 상태 있는 빈과 없는 빈의 스코프 권장, prototype 빈을 싱글톤에 주입할 때의 동작
- [Spring Framework Reference: Task Execution and Scheduling](https://docs.spring.io/spring-framework/reference/integration/scheduling.html) — `@EnableAsync`, 프록시 모드에서 같은 클래스 호출이 가로채지지 않는 조건, `@Async("이름")`, `void` 메서드 예외와 `AsyncUncaughtExceptionHandler`
- [Spring Framework Javadoc: EnableAsync](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/scheduling/annotation/EnableAsync.html) — executor를 찾는 순서와 `SimpleAsyncTaskExecutor` 기본값, `AsyncConfigurer` 예제
- [Spring Boot Reference: Task Execution and Scheduling](https://docs.spring.io/spring-boot/reference/features/task-execution-and-scheduling.html) — 자동 구성 executor의 기본 스레드 수와 큐 제한 설정, 직접 등록한 `Executor` 빈이 있을 때의 동작
- [Spring Framework Javadoc: TransactionalEventListener](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/transaction/event/TransactionalEventListener.html) — 기본 단계인 `AFTER_COMMIT`, 트랜잭션 밖에서 발행된 이벤트가 버려지는 조건과 `fallbackExecution`, 커밋 뒤 데이터 접근에 대한 경고
