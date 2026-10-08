---
title: "알림 발송 Service 필드에 수신자 ID를 저장하면 요청이 섞이는 이유"
date: 2026-10-08 08:55:00 +0900
tags: [Spring, Java, Backend]
excerpt: "알림 발송 예제로 Spring singleton Service가 요청별 값을 필드에 저장하면 왜 위험한지, 메서드 파라미터와 지역 변수로 상태를 다루는 기준을 초급 수준에서 설명한다."
---

# 알림 발송 Service 필드에 수신자 ID를 저장하면 요청이 섞이는 이유

한 번 만들어진 Service 객체를 여러 요청이 함께 쓰는 방식

**대상 독자: Java 문법과 간단한 Spring CRUD를 막 익힌 개발자**

알림 발송 API를 만들면서 `receiverId`를 `NotificationService` 필드에 저장하면 코드가 편해 보인다. 메서드마다 수신자 ID를 전달하지 않아도 되기 때문이다. 하지만 동시에 두 요청이 들어오면 한 요청이 저장한 값 위에 다른 요청의 값이 덮일 수 있다. 이 글은 알림 요청 하나를 따라가며 Spring Service에 어떤 값을 보관하면 안 되는지 설명한다.

핵심은 Service가 나쁘다는 것이 아니다. 기본 설정의 Spring bean은 한 번 만들어진 객체를 여러 곳에서 함께 쓸 수 있다. 그래서 요청마다 달라지는 값은 필드가 아니라 메서드 안에서 다뤄야 한다.

## 1. 오늘의 주제

관리자가 회원 101에게 공지 알림을 보내고, 거의 동시에 다른 관리자가 회원 202에게 알림을 보낸다고 하자. 두 요청은 같은 `NotificationService`를 호출할 수 있다. 이때 Service 필드에 “현재 수신자”를 저장하면, 두 요청이 같은 칸을 번갈아 쓰게 된다.

Spring을 처음 배울 때는 `@Service`가 붙은 클래스를 요청마다 새로 만든다고 생각하기 쉽다. 하지만 일반적인 Spring bean의 기본 scope는 singleton이다. 여기서 singleton은 Spring 컨테이너 안에서 같은 bean 정의에 대해 하나의 객체를 관리한다는 뜻이다. 이 글을 읽은 뒤에는 요청별 값과 서비스가 공유해도 되는 값을 구분할 수 있다.

이 예시는 학습용 알림 서비스다. 실제 알림 발송 순서나 외부 메시지 제공자의 동작을 재현하는 것이 아니라, 한 Service 인스턴스의 필드가 여러 요청에 공유되는 문제만 다룬다.

## 2. 핵심 개념

먼저 필드는 객체가 살아 있는 동안 남아 있는 값이다. `NotificationService` 객체가 하나라면 그 안의 필드도 하나다. `private Long receiverId;`는 요청마다 새로 생기는 칸이 아니다.

반면 메서드 파라미터와 메서드 안의 지역 변수는 호출마다 따로 만들어진다. `send(Long receiverId, String message)`의 `receiverId`는 알림 요청 한 번에만 쓰는 값이다. 다른 요청이 같은 메서드를 호출해도 자기 호출의 파라미터를 사용한다.

무상태 서비스는 요청별 데이터를 필드에 보관하지 않는 Service를 말한다. 데이터베이스 Repository, 알림 발송기처럼 여러 요청이 함께 써도 되는 의존성은 `final` 필드로 주입해도 된다. 하지만 회원 ID, 요청 내용, 임시 계산 결과처럼 매번 달라지는 값은 필드에 두지 않는 것이 기본이다.

## 3. 내부 동작 원리

알림 요청 두 개가 들어올 때 나쁜 코드에서는 다음 일이 일어날 수 있다.

1. 요청 A가 Service 필드 `receiverId`에 101을 저장한다.
2. 요청 A가 아직 발송 처리를 끝내기 전에 요청 B가 같은 필드에 202를 저장한다.
3. 요청 A가 필드를 다시 읽으면 원래의 101 대신 202를 얻을 수 있다.
4. 결과적으로 A의 메시지가 잘못된 수신자에게 향할 위험이 생긴다.

두 요청이 정확히 어느 순서로 겹칠지는 보장되지 않는다. 로컬에서 한 번씩만 호출하면 문제가 보이지 않을 수 있다. 요청을 처리하는 스레드가 둘 이상일 때만 드러나는 문제이기 때문이다. 그렇다고 복잡한 동시성 도구를 먼저 붙일 필요는 없다. 요청별 상태를 필드에서 제거하는 것이 가장 단순한 해결이다.

Spring은 기본 singleton bean을 컨테이너 안에서 하나의 공유 객체로 관리한다. singleton 자체가 위험한 것이 아니다. 상태를 저장하지 않는 Service는 여러 요청이 함께 사용해도 된다. 위험한 것은 공유 객체 안에 요청마다 달라지는 값을 넣는 일이다.

## 4. 실제 코드

아래 왼쪽 방식은 피해야 한다. 오른쪽처럼 수신자 ID와 메시지를 메서드 파라미터로 받으면 요청마다 값이 분리된다.

```java
@Service
@RequiredArgsConstructor
public class NotificationService {
    private final NotificationSender notificationSender;
    // private Long receiverId; // 요청별 값을 필드에 두면 안 된다.

    public void send(Long receiverId, String message) {
        if (receiverId == null || message == null || message.isBlank()) {
            throw new IllegalArgumentException("알림 정보가 올바르지 않습니다.");
        }

        notificationSender.send(receiverId, message);
    }
}
```

`notificationSender`는 알림을 보내는 역할을 가진 협력 객체다. 요청별 데이터를 직접 들고 있지 않는다고 가정하므로 `final` 필드로 한 번 주입해 공유할 수 있다. 반면 `receiverId`와 `message`는 `send`를 호출한 요청에만 필요한 값이다. 파라미터로 받으면 다른 요청이 이 값을 덮어쓸 수 없다.

검증도 메서드 안에서 한다. 수신자 ID가 없거나 빈 메시지라면 발송 전에 실패시킨다. 잘못된 요청을 필드에 저장한 뒤 나중에 확인하면, 어느 요청의 값이 문제였는지 추적하기 더 어렵다.

## 5. 실제 서비스 적용

Controller는 요청 DTO에서 수신자 ID와 메시지를 받고, Service 메서드에 인자로 넘긴다. Service는 형식을 확인한 뒤 `NotificationSender`를 호출한다. 요청에서 온 값은 Controller와 Service 호출 흐름 안에서만 이동한다. `static` 변수나 Service 필드에 잠시 저장해 다음 메서드에서 꺼내는 구조는 만들지 않는다.

알림 요청이 많아지면 한 번에 받는 메시지 길이와 수신자 수를 먼저 제한한다. 하지만 요청량이 늘었다는 이유로 `receiverId`를 필드에 캐시해서는 안 된다. 수신자 정보가 필요하면 Repository에서 조회하거나, 현재 요청의 파라미터를 쓴다. 성능 문제와 요청 상태 보관 문제는 별개다.

처음 확인할 테스트는 수신자 101과 202로 `send`를 각각 호출했을 때 `NotificationSender`가 각 ID와 메시지를 정확히 받는지다. 이상한 발송 로그가 보이면 Service의 필드 목록부터 확인한다. 그 다음 Controller가 요청값을 다른 곳에 저장하고 있지 않은지 본다.

## 6. 흔히 발생하는 문제

### 1) 현재 수신자를 Service 필드에 저장하는 경우

현상은 가끔 알림 수신자가 바뀌거나 로그의 회원 ID가 섞여 보이는 것이다. 원인은 singleton Service의 필드를 여러 요청이 공유하기 때문이다. 첫 확인 지점은 `private Long receiverId`와 같이 요청 데이터를 가진 필드다. 해결 방향은 그 값을 메서드 파라미터와 지역 변수로 옮기는 것이다.

### 2) 필드를 static으로 바꾸는 경우

현상은 Service 객체를 여러 개 만들지 않으니 괜찮다고 생각했는데 문제가 계속되는 것이다. `static` 필드는 객체가 아니라 클래스에 하나만 생기므로 오히려 더 넓게 공유된다. 첫 확인 지점은 `static Long currentReceiverId` 같은 선언이다. 요청 상태에는 static을 쓰지 않고 호출 흐름으로 값을 전달한다.

### 3) singleton이 불안해서 모든 Service를 request scope로 바꾸는 경우

현상은 단순한 서비스까지 scope 설정과 주입 방식이 복잡해지는 것이다. 원인은 공유 상태 문제를 객체 개수 문제로만 본 데 있다. 첫 확인 지점은 요청별 값을 필드에 둔 코드가 있는지다. 대부분의 Service는 무상태로 만들고 singleton으로 유지하면 충분하다. 요청마다 상태를 가진 객체가 정말 필요할 때만 request scope를 검토한다.

## 7. 기술 선택의 Trade-off

무상태 singleton Service의 장점은 구조가 단순하고 의존성을 한 번만 만들 수 있다는 점이다. 일반적인 Controller-Service-Repository 흐름에서 가장 자주 쓰기 좋다. 여러 요청이 들어와도 요청별 값을 파라미터와 지역 변수로 다루면 서로의 데이터를 건드리지 않는다.

단점은 Service 필드에 편하게 값을 저장할 수 없다는 점이다. 하지만 이는 불편함보다 안전 장치에 가깝다. HTTP 요청마다 별도 객체 상태가 꼭 필요하면 Spring의 request scope를 사용할 수 있다. 다만 singleton에 request-scoped bean을 주입할 때는 수명 차이를 이해해야 하므로, 단순한 수신자 ID 전달 문제의 첫 해결책으로는 적합하지 않다.

다음 네 단계로 결정하면 충분하다.

1. 필드 값이 애플리케이션 전체에서 공유해도 되는 의존성인지 확인한다.
2. 회원 ID·메시지·요청 내용처럼 호출마다 달라지는 값이면 파라미터나 지역 변수로 옮긴다.
3. 동시 요청 테스트에서 전달한 수신자 ID와 발송기 호출 값을 비교한다.
4. 요청별 객체 상태가 정말 필요할 때만 request scope를 검토한다.

### 참고한 공식 문서

- [Spring Framework Bean Scopes](https://docs.spring.io/spring-framework/reference/core/beans/factory-scopes.html) — singleton이 기본 scope이며, Spring 컨테이너가 하나의 공유 bean 인스턴스를 관리하는 방식을 확인했다.
- [Spring Framework Request Scope](https://docs.spring.io/spring-framework/reference/core/beans/factory-scopes.html#beans-factory-scopes-request) — request scope가 HTTP 요청마다 별도 bean 인스턴스를 만드는 동작과 적용 범위를 확인했다.
