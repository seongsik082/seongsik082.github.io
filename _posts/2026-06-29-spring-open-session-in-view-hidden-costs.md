---
title: "Open Session in View가 N+1과 지연 쿼리를 숨기는 방식"
date: 2026-06-29 09:41:00 +0900
tags: [Spring, JPA, Backend]
excerpt: "Spring Boot의 Open Session in View 기본 동작은 화면 렌더링과 직렬화 단계까지 지연 로딩을 허용하지만, 그 편의성 때문에 쿼리 경계와 N+1 문제가 더 늦게 드러날 수 있습니다."
---

JPA를 처음 붙인 Spring 애플리케이션은 로컬에서 꽤 잘 돌아갑니다.
서비스 메서드에서 엔티티를 조회하고, 컨트롤러에서 그 엔티티를 그대로 응답으로 내보내도 `LazyInitializationException`이 잘 안 터집니다.
그래서 많은 팀이 "이 정도면 괜찮네"라고 생각한 채 기능을 늘립니다.
문제는 그 안정감이 구조적 해결이 아니라 `Open Session in View`, 정확히는 Spring Boot의 기본 등록 동작 덕분인 경우가 많다는 점입니다.

Spring Boot 공식 문서는 웹 애플리케이션에서 기본적으로 `Open EntityManager in View` 패턴을 적용하기 위해 `OpenEntityManagerInViewInterceptor`를 등록한다고 설명합니다.
또 Spring Framework의 `OpenEntityManagerInViewFilter` 문서는 이 패턴이 요청 전체 처리 동안 스레드에 `EntityManager`를 바인딩해, 원래 트랜잭션이 끝난 뒤에도 웹 뷰에서 lazy loading을 허용한다고 설명합니다.
즉 서비스 계층 바깥에서 엔티티 연관관계를 건드려도 추가 쿼리가 나갈 수 있게 길을 열어둔 것입니다.

## 편한 이유와 위험한 이유가 같다

OSIV가 편한 이유는 명확합니다.
서비스에서 엔티티 하나만 넘겨도 컨트롤러, 템플릿, JSON 직렬화 단계에서 연관 엔티티가 필요해지는 순간 지연 로딩이 동작합니다.
처음에는 예외가 안 나니 생산성이 좋아 보입니다.

하지만 바로 그 특성 때문에 쿼리 경계가 흐려집니다.
서비스 메서드가 끝났는데도 SQL이 더 나갈 수 있고, 개발자는 "어디서 쿼리가 터졌는지" 눈치채기 어려워집니다.
특히 Jackson 직렬화 중 getter가 열리면서 연관 엔티티가 로딩되면, 컨트롤러 코드는 멀쩡해 보여도 응답 직전 N+1이 터질 수 있습니다.

```java
@GetMapping("/orders/{id}")
public OrderResponse getOrder(@PathVariable Long id) {
    Order order = orderService.findById(id);
    return OrderResponse.from(order);
}
```

이 코드가 단순해 보여도 `OrderResponse.from(order)` 안에서 `order.getOrderLines()`나 `order.getMember().getName()`을 건드리는 순간 추가 쿼리가 발생할 수 있습니다.
OSIV가 켜져 있으면 예외 대신 "그냥 쿼리가 나감"으로 끝나기 때문에, 문제는 기능 테스트보다 운영 부하에서 먼저 보입니다.

## N+1이 서비스 계층 밖으로 새어 나간다

N+1 문제는 단순히 fetch join을 안 썼다는 뜻이 아닙니다.
더 근본적으로는 "어느 계층에서 어떤 데이터까지 읽을지"를 명시하지 않았다는 뜻입니다.
OSIV가 켜져 있으면 이 경계가 흐려져, 서비스 계층이 데이터를 다 준비하지 않아도 화면이나 응답 생성 단계가 나머지를 메워줍니다.

예를 들어 주문 목록 100건을 응답으로 내보내는 API가 있다고 합시다.

```java
List<Order> orders = orderRepository.findRecent();
return orders.stream()
    .map(order -> new OrderSummary(
        order.getId(),
        order.getMember().getName(),
        order.getOrderLines().size()))
    .toList();
```

겉으로는 조회 한 번처럼 보이지만, `member`와 `orderLines`가 lazy라면 목록 직렬화 과정에서 추가 쿼리가 다량 발생할 수 있습니다.
OSIV가 꺼져 있었다면 예외로 빨리 드러났을 문제인데, 켜져 있으니 성능 문제로 늦게 드러납니다.
그래서 OSIV는 "문제를 해결"하기보다 "문제를 지연시켜 숨기는" 장치가 되기 쉽습니다.

## 언제 끄는 편이 낫나

대부분의 JSON API 서버에서는 `spring.jpa.open-in-view=false`를 기본값으로 두는 편이 더 낫습니다.
응답에 필요한 데이터는 서비스 계층 안에서 명시적으로 준비하고, 컨트롤러 바깥에서 지연 로딩이 일어나지 않도록 만드는 쪽이 경계가 선명합니다.

```properties
spring.jpa.open-in-view=false
```

OSIV를 끄면 당장은 `LazyInitializationException`이 더 빨리 드러날 수 있습니다.
하지만 그건 나쁜 소식이 아니라, 지금까지 서비스 경계 밖에 숨어 있던 쿼리를 명시적으로 정리할 기회입니다.
이때 선택지는 대체로 다음과 같습니다.

- fetch join으로 필요한 연관만 한 번에 읽기
- `@EntityGraph`로 조회 의도를 선언하기
- 조회 전용 DTO 프로젝션으로 필요한 필드만 가져오기
- 쓰기 모델과 읽기 모델을 분리하기

중요한 건 "컨트롤러가 엔티티 그래프 탐험을 하지 않게" 만드는 것입니다.

## 그래도 OSIV가 완전히 틀린 선택은 아니다

서버 렌더링 템플릿 중심의 애플리케이션에서는 OSIV가 생산성을 높이는 경우도 있습니다.
템플릿에서 연관 데이터를 자연스럽게 읽어야 하고, 복잡한 DTO 매핑 비용이 더 큰 경우입니다.
Spring 공식 문서도 "웹 뷰에서 lazy loading을 허용하기 위한 패턴"이라고 설명합니다.
즉 이 패턴의 원래 목적은 API 서버보다는 뷰 렌더링 쪽에 더 가깝습니다.

다만 JSON API, 대량 목록 조회, 외부 호출과 DB 처리가 섞인 백엔드에서는 비용이 더 자주 큽니다.
특히 팀이 성능 이슈를 SQL 로그, APM, 트레이스로 추적해야 하는 규모가 되면 "응답 직전 어디선가 추가 쿼리가 나간다"는 특성이 큰 부담이 됩니다.

## 운영에서 확인할 것

OSIV가 켜져 있는 프로젝트라면 다음을 우선 확인하는 편이 좋습니다.

- 컨트롤러/직렬화 단계에서 추가 SQL이 발생하는지
- 목록 API에서 row 수 대비 쿼리 수가 선형으로 늘어나는지
- 트랜잭션 종료 이후에도 Hibernate SQL 로그가 이어지는지
- 응답 시간이 느린 구간이 서비스 로직이 아니라 직렬화 단계인지
- `LazyInitializationException`을 피하려고 엔티티를 그대로 응답 모델로 쓰고 있지 않은지

OSIV를 끈 뒤에는 반대로 다음을 보게 됩니다.

- 필요한 조회 패턴이 fetch join/EntityGraph/DTO로 정리됐는지
- 컨트롤러가 엔티티 대신 응답 모델을 다루는지
- 서비스 메서드 안에서 읽기 범위가 명확한지

## 정리

Open Session in View는 lazy loading 예외를 줄여주는 대신, 쿼리 경계가 서비스 계층 밖으로 새어나가게 만들 수 있습니다.
그래서 N+1과 지연 쿼리가 예외가 아니라 "늦은 응답"으로 나타나기 쉽습니다.
Spring Boot는 웹 애플리케이션에서 이 패턴을 기본 등록하므로, API 서버라면 `spring.jpa.open-in-view=false`를 의식적으로 검토하는 편이 좋습니다.
편의성보다 경계의 명확성이 더 중요해지는 시점이 운영 성능 문제의 시작점인 경우가 많습니다.

참고한 공식 문서:
- [Spring Boot SQL Databases: Open EntityManager in View](https://docs.spring.io/spring-boot/reference/data/sql.html#data.sql.jpa-and-spring-data.open-entity-manager-in-view)
- [Spring Framework OpenEntityManagerInViewFilter Javadoc](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/orm/jpa/support/OpenEntityManagerInViewFilter.html)
