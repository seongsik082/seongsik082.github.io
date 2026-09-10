---
title: "댓글 알림을 Spring @Async로 분리할 때 먼저 정할 한 가지"
date: 2026-09-10 08:55:00 +0900
tags: [Spring, Java, Async, Backend]
excerpt: "댓글 저장과 알림 전송을 분리하는 예제로 Spring @Async의 실행 조건, 같은 클래스 호출이 동작하지 않는 이유, 알림 실패를 성공 응답으로 착각하지 않는 기준을 설명한다."
---

# 댓글 알림을 Spring `@Async`로 분리할 때 먼저 정할 한 가지

댓글 저장은 성공했는데 알림이 늦거나 실패해도 괜찮을까?

**대상 독자:** Java 문법과 간단한 Spring CRUD를 막 익힌 개발자

댓글을 작성하면 상대방에게 알림을 보내는 기능을 생각해 보자. 댓글 저장과 알림 전송을 한 요청에서 모두 기다리면, 알림 서비스가 늦을 때 댓글 작성 화면도 늦어진다. 그래서 Spring의 `@Async`를 붙여 알림을 따로 실행하고 싶어진다. 이때 가장 먼저 정할 것은 “알림이 실패하면 댓글 작성도 실패해야 하는가”이다.

이 글에서는 댓글 저장은 바로 응답하고, 알림은 그 뒤에 처리하는 학습용 상황만 다룬다. `@Async`가 무엇을 바꾸는지와, 붙였는데도 동기처럼 실행되는 흔한 이유를 한 코드 흐름으로 설명한다.

## 1. 오늘의 주제

게시글에 댓글을 남긴 사용자는 보통 “댓글이 등록되었다”는 결과를 먼저 원한다. 새 댓글 알림은 편리하지만, 알림 전송 자체가 댓글 데이터의 정합성을 결정하지는 않는 경우가 많다. 이때 댓글을 저장한 뒤 알림 전송을 별도 작업으로 보내면, 사용자는 알림 완료를 기다리지 않고 응답을 받을 수 있다.

`@Async`는 Spring에게 특정 메서드를 별도 작업으로 실행하도록 맡기는 표시다. 하지만 모든 메서드 호출이 자동으로 따로 실행되는 것은 아니다. Spring이 관리하는 객체 사이의 호출이어야 하며, 설정도 필요하다.

이 주제를 배우는 시점은 Controller와 Service의 역할을 나누기 시작한 뒤다. 글을 읽고 나면 댓글 저장처럼 반드시 끝나야 하는 일과, 알림처럼 뒤에서 처리할 수 있는 일을 구분하고 `@Async`를 어디에 둘지 판단할 수 있다.

## 2. 핵심 개념

먼저 댓글 저장과 알림은 서로 다른 결과를 만든다. 댓글 저장이 실패하면 사용자에게 실패를 알려야 한다. 반면 학습용 예시에서 알림이 실패했다고 댓글까지 지우면 사용자는 이미 작성한 내용을 잃을 수 있다. 따라서 두 작업을 분리할 수 있는지는 기술 선택보다 업무 규칙의 문제다.

`@EnableAsync`는 애플리케이션에서 `@Async`를 해석하도록 켜는 설정이다. `@Async`는 이 설정이 있을 때 Spring이 해당 메서드 호출을 가로채 별도 작업 실행기에 전달할 수 있다. 작업 실행기는 실행할 일을 줄 세우고, 정해 둔 작업자에게 맡기는 Spring의 관리 도구라고 생각하면 된다.

중요한 규칙이 하나 있다. `@Async` 메서드를 같은 클래스 안에서 직접 부르면 별도 실행으로 바뀌지 않을 수 있다. Spring은 다른 Spring 객체를 거쳐 들어오는 호출을 가로채기 때문이다. 그래서 댓글 저장 서비스와 알림 서비스를 분리하면 코드 책임도 분명하고, `@Async` 동작도 예측하기 쉽다.

## 3. 내부 동작 원리

댓글 작성 요청이 아래 구조를 지난다고 가정하자.

1. Controller가 `CommentService`에 댓글 작성을 요청한다.
2. `CommentService`가 댓글을 저장하고 저장된 댓글 번호를 받는다.
3. `CommentService`가 별도 Spring 객체인 `NotificationService`를 호출한다.
4. Spring은 `@Async`를 보고 알림 작업을 실행기에 전달한다. 댓글 요청을 처리하던 흐름은 응답을 계속 준비한다.
5. 실행기가 나중에 알림 전송 메서드를 실행한다. 성공하거나 예외가 나도, 이미 보낸 댓글 작성 응답을 다시 바꾸지는 못한다.

4번과 5번이 분리되므로 “댓글 등록 성공”은 “알림이 사용자에게 도착함”과 같은 뜻이 아니다. 이 차이를 기록하지 않으면 운영 중에 알림이 빠졌는데도 댓글 API가 200을 반환했다는 사실만 보게 된다. 알림 작업에는 댓글 번호와 수신자 번호를 로그에 남겨 두는 편이 좋다.

## 4. 실제 코드

아래는 댓글 저장 뒤 알림을 따로 보내는 짧은 Spring 예시다. 실제 알림 서비스 대신 로그만 남긴다. `NotificationService`를 별도 클래스로 둔 점이 핵심이다.

```java
@Configuration
@EnableAsync
public class AsyncConfig {
    @Bean("notificationExecutor")
    public Executor notificationExecutor() {
        ThreadPoolTaskExecutor executor = new ThreadPoolTaskExecutor();
        executor.setCorePoolSize(2);
        executor.setMaxPoolSize(4);
        executor.setQueueCapacity(20);
        executor.setThreadNamePrefix("notification-");
        return executor;
    }
}

@Service
public class NotificationService {
    @Async("notificationExecutor")
    public void sendNewComment(Long commentId, Long receiverId) {
        log.info("commentId={}, receiverId={} 알림 전송 시작", commentId, receiverId);
    }
}

@Service
@RequiredArgsConstructor
public class CommentService {
    private final CommentRepository commentRepository;
    private final NotificationService notificationService;

    public Long create(Long receiverId, String content) {
        Comment comment = commentRepository.save(new Comment(receiverId, content));
        notificationService.sendNewComment(comment.getId(), receiverId);
        return comment.getId();
    }
}
```

`@EnableAsync`가 없으면 `@Async`는 별도 실행 규칙으로 작동하지 않는다. `notificationExecutor`는 알림 작업만 위한 실행기 이름이다. 숫자 2, 4, 20은 정답이 아니라 학습용 시작값이다. 서비스의 알림 방식, 허용할 대기량, 서버 자원에 맞춰 정해야 한다.

`CommentService`는 댓글을 저장한 다음 다른 객체의 `NotificationService`를 호출한다. 같은 클래스의 `this.sendNewComment()`처럼 호출하지 않은 이유는 이 호출이 Spring의 가로채는 경로를 지나지 않을 수 있기 때문이다. 코드가 실행되더라도 별도 작업이 아닐 수 있으므로, 클래스 분리는 동작을 보장하기 위한 선택이기도 하다.

## 5. 실제 서비스 적용

작은 서비스에서는 먼저 “댓글 저장 성공”의 기준을 하나로 고정한다. 데이터베이스에 댓글이 저장되었을 때만 성공 응답을 보낸다. 알림은 그 뒤의 독립적인 부가 기능으로 취급한다. 알림 실패가 댓글을 되돌려야 하는 업무라면 이 구조를 그대로 쓰면 안 된다.

알림 요청이 늘면 가장 먼저 실행기 대기열이 쌓이는지 확인한다. 대기열이 계속 늘면 알림 작업이 처리되는 속도보다 들어오는 속도가 빠르다는 뜻이다. 이때 작업자 수만 크게 올리기보다, 알림 API가 느린지와 실패가 반복되는지를 먼저 확인한다. 로그에는 `commentId`, `receiverId`, 작업자 이름을 함께 남기면 같은 요청의 흐름을 찾기 쉽다.

테스트에서는 댓글 저장이 성공했을 때 `NotificationService`가 한 번 호출되는지를 먼저 확인한다. 실제 비동기 실행 순서까지 단위 테스트에서 억지로 검증하기보다, 알림 서비스가 실패했을 때 댓글 저장 결과가 어떻게 되는지라는 업무 규칙을 별도 테스트로 확인하는 편이 이해하기 쉽다.

## 6. 흔히 발생하는 문제

### 1) `@EnableAsync`를 빼먹는 경우

현상은 `@Async`를 붙였는데도 알림 로그가 댓글 저장 로그 바로 뒤에만 나오는 것이다. 원인은 Spring이 비동기 실행 규칙을 켜지 못했기 때문이다. 첫 확인 지점은 설정 클래스에 `@EnableAsync`가 있는지다. 해결은 설정을 추가하고, 작업자 이름이 포함된 로그로 별도 실행 경로를 확인하는 것이다.

### 2) 같은 클래스 안에서 `@Async` 메서드를 호출하는 경우

현상은 애너테이션이 있는데도 호출한 메서드가 현재 요청 흐름에서 실행되는 것이다. 원인은 Spring이 다른 객체를 통한 호출만 가로챌 수 있는 기본 동작 방식에 있다. 첫 확인 지점은 `this.`로 호출하거나 같은 Service 안에서 호출했는지다. 간단한 해결 방향은 알림 책임을 별도 `NotificationService`로 옮기는 것이다.

### 3) 댓글 성공 응답을 알림 성공으로 해석하는 경우

현상은 사용자가 “댓글은 작성됐는데 알림을 받지 못했다”고 문의하는 것이다. 원인은 비동기 작업의 실패가 이미 보낸 HTTP 응답에 들어가지 않기 때문이다. 첫 확인 지점은 `commentId`와 수신자 번호로 남긴 알림 시작·실패 로그다. 해결 방향은 알림 실패를 따로 기록하고 재처리할 기준을 정하는 것이다. 댓글 저장을 되돌릴지 여부는 업무 규칙을 먼저 확인해야 한다.

## 7. 기술 선택의 Trade-off

`@Async`는 댓글 저장처럼 사용자 응답을 빨리 끝내고, 그 뒤의 독립적인 알림을 처리할 때 읽기 쉬운 선택이다. 직접 `new Thread()`를 만들지 않아도 Spring이 실행기를 관리하므로 작업 이름과 대기열을 한곳에서 볼 수 있다. 대신 알림이 끝난 시점과 성공 여부가 댓글 API 응답과 분리된다.

댓글 저장 결과를 바꾸는 검증, 권한 확인, 데이터 저장은 `@Async`로 보내지 않는 편이 좋다. 사용자가 성공 응답을 받기 전에 끝나야 하는 일이기 때문이다. 알림이 반드시 한 번은 전달되어야 하거나 실패 후 재처리가 중요한 서비스라면, 단순 `@Async`만으로는 부족할 수 있다. 작업 기록과 재시도 규칙을 따로 설계하는 방식을 검토해야 한다.

결정은 네 단계면 충분하다. 먼저 실패해도 댓글을 저장해도 되는 작업인지 확인한다. 다음으로 사용자 응답 전에 끝나야 하는지 정한다. 분리해도 된다면 별도 Spring 서비스와 관리되는 실행기를 사용한다. 마지막으로 실패 로그와 재처리 기준이 없는 작업은 `@Async`로 보내지 않는다.

### 참고한 공식 문서

- [Spring Framework Task Execution and Scheduling](https://docs.spring.io/spring-framework/reference/integration/scheduling.html#scheduling-annotation-support-async) — `@EnableAsync` 설정, `@Async` 호출의 기본 프록시 방식, 같은 클래스 안의 호출이 가로채지지 않는 조건을 확인했다.
- [Spring Framework TaskExecutor](https://docs.spring.io/spring-framework/reference/integration/scheduling.html#scheduling-task-executor) — `TaskExecutor`와 `ThreadPoolTaskExecutor`가 작업을 대기열과 설정 규칙에 따라 실행하는 방식을 확인했다.
