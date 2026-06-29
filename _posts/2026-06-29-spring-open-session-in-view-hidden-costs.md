---
title: "Open Session in View가 N+1과 지연 쿼리를 숨기는 방식"
date: 2026-06-29 09:41:00 +0900
tags: [Spring, JPA, Backend]
excerpt: "Spring Boot의 Open Session in View 기본 동작은 화면 렌더링과 직렬화 단계까지 지연 로딩을 허용하지만, 그 편의성 때문에 쿼리 경계와 N+1 문제가 더 늦게 드러날 수 있습니다."
---

JPA를 붙인 Spring API를 만들다 보면 처음에는 꽤 편합니다.
서비스에서 엔티티를 조회한 뒤 컨트롤러에서 그대로 응답으로 바꿔도 잘 동작하는 경우가 많기 때문입니다.
그래서 "생각보다 간단하네"라고 느끼고 그대로 기능을 늘리기 쉽습니다.
문제는 그 편함이 설계가 좋아서가 아니라 `Open Session in View`, 줄여서 OSIV 덕분인 경우가 많다는 점입니다.

Spring Boot 공식 문서는 웹 애플리케이션에서 기본적으로 `Open EntityManager in View` 패턴을 적용하기 위해 `OpenEntityManagerInViewInterceptor`를 등록한다고 설명합니다.
또 Spring Framework의 `OpenEntityManagerInViewFilter` 문서는 이 패턴이 요청 전체 처리 동안 스레드에 `EntityManager`를 바인딩해, 원래 트랜잭션이 끝난 뒤에도 웹 뷰에서 lazy loading을 허용한다고 설명합니다.
쉽게 말하면 서비스 계층 밖에서도 지연 로딩이 계속 일어날 수 있게 길을 열어두는 것입니다.

## 왜 문제인가

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

이 코드가 단순해 보여도 `OrderResponse.from(order)` 안에서 `order.getOrderLines()`나 `order.getMember().getName()`을 건드리면 추가 쿼리가 생길 수 있습니다.
OSIV가 켜져 있으면 예외 대신 "그냥 쿼리가 더 나간다"로 끝나기 때문에, 문제를 늦게 알아차리기 쉽습니다.

## 어디서 헷갈리기 쉬운가

OSIV가 켜져 있으면 서비스 메서드가 끝난 뒤에도 응답을 만드는 과정에서 추가 조회가 가능합니다.
그래서 개발자는 "서비스에서 필요한 데이터를 다 준비했는지" 덜 엄격하게 생각하게 됩니다.
그 결과 N+1 문제도 서비스 계층 안에서 바로 보이지 않고, 응답 직전이나 JSON 직렬화 단계에서 뒤늦게 나타날 수 있습니다.

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

겉으로는 조회 한 번처럼 보여도 `member`와 `orderLines`가 lazy라면 추가 쿼리가 여러 번 나갈 수 있습니다.
OSIV가 꺼져 있었다면 더 빨리 구조 문제를 발견했을 수 있는데, 켜져 있으면 성능 저하로만 늦게 보일 수 있습니다.

## 언제 끄는 편이 낫나

대부분의 JSON API 서버에서는 `spring.jpa.open-in-view=false`를 기본값으로 두는 편이 더 낫습니다.
응답에 필요한 데이터는 서비스 계층 안에서 명시적으로 준비하고, 컨트롤러 바깥에서 지연 로딩이 일어나지 않도록 만드는 쪽이 경계가 선명합니다.

```properties
spring.jpa.open-in-view=false
```

OSIV를 끄면 당장은 `LazyInitializationException`이 더 빨리 드러날 수 있습니다.
하지만 그건 오히려 구조를 정리할 기회입니다.
응답에 필요한 데이터는 서비스 계층 안에서 명시적으로 준비하자는 신호로 보면 됩니다.
보통은 다음 방식으로 정리합니다.

- fetch join으로 필요한 연관만 한 번에 읽기
- `@EntityGraph`로 조회 의도를 선언하기
- 조회 전용 DTO 프로젝션으로 필요한 필드만 가져오기
- 쓰기 모델과 읽기 모델을 분리하기

핵심은 컨트롤러가 엔티티를 따라가며 데이터를 즉석에서 꺼내 쓰지 않게 만드는 것입니다.

## 그래도 무조건 끄라는 뜻은 아니다

서버 렌더링 템플릿 중심의 애플리케이션에서는 OSIV가 생산성을 높이는 경우도 있습니다.
템플릿에서 연관 데이터를 자연스럽게 읽어야 하고, 복잡한 DTO 매핑 비용이 더 큰 경우입니다.
Spring 공식 문서도 이 패턴을 웹 뷰에서 lazy loading을 허용하는 용도로 설명합니다.
즉 API 서버보다는 서버 렌더링 화면 쪽에 더 자연스러운 선택입니다.

다만 JSON API, 대량 목록 조회, 외부 호출과 DB 처리가 섞인 백엔드에서는 비용이 더 자주 큽니다.
특히 SQL 로그와 APM으로 성능을 추적해야 하는 서비스라면, "응답 직전 어디선가 쿼리가 더 나간다"는 특성이 부담이 됩니다.

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

Open Session in View는 개발 초반에는 편하지만, 쿼리가 어디서 나가는지 흐리게 만들 수 있습니다.
그래서 N+1 문제가 예외가 아니라 늦은 응답으로 나타나기 쉽습니다.
JSON API 중심 서버라면 `spring.jpa.open-in-view=false`를 기본값 후보로 두고, 서비스 계층에서 필요한 데이터를 명시적으로 준비하는 쪽이 더 안전합니다.
실무에서는 "편하게 동작한다"보다 "쿼리 경계가 보이는가"가 더 중요한 기준이 됩니다.

참고한 공식 문서:
- [Spring Boot SQL Databases: Open EntityManager in View](https://docs.spring.io/spring-boot/reference/data/sql.html#data.sql.jpa-and-spring-data.open-entity-manager-in-view)
- [Spring Framework OpenEntityManagerInViewFilter Javadoc](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/orm/jpa/support/OpenEntityManagerInViewFilter.html)
