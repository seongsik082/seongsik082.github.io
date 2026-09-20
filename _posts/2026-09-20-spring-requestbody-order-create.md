---
title: "주문 생성 API에서 Spring @RequestBody를 DTO로 받는 이유"
date: 2026-09-20 15:10:00 +0900
tags: [Spring, REST API, Java, Backend]
excerpt: "주문 생성 요청 예제로 Spring @RequestBody가 JSON을 DTO로 바꾸는 순서, @RequestParam과 구분하는 기준, 요청 DTO를 엔티티와 분리하는 이유를 초급 수준에서 설명한다."
---

# 주문 생성 API에서 Spring `@RequestBody`를 DTO로 받는 이유

JSON 주문 요청은 Controller에서 어떻게 Java 객체가 될까?

**대상 독자:** Java 문법과 간단한 Spring CRUD를 막 익힌 개발자

프런트엔드가 주문 정보를 JSON으로 보내는데, Controller의 값이 `null`이라면 어디부터 봐야 할까? 처음에는 `@RequestParam`을 붙이거나 Entity를 그대로 받으면 된다고 생각하기 쉽다. 하지만 JSON 요청 본문은 `@RequestBody`로 받고, API 입력 전용 DTO로 옮기는 편이 역할을 구분하기 쉽다. 이 글은 주문 생성 요청 하나를 기준으로 이 변환이 어디서 일어나는지 설명한다.

## 1. 오늘의 주제

주문 생성 화면에서 사용자는 배송지와 주문할 상품 번호를 서버에 보낸다. 예를 들어 브라우저는 아래처럼 JSON 형식의 요청 본문을 보낼 수 있다.

```http
POST /orders
Content-Type: application/json

{
  "productId": 12,
  "deliveryAddress": "서울시 강남구"
}
```

Controller가 이 내용을 읽어 서비스에 전달해야 주문 저장을 시작할 수 있다. 이때 `@RequestBody`는 HTTP 요청의 본문을 Java 객체로 바꿔 달라고 Spring에 알려 주는 애너테이션이다. `@RequestParam`은 URL의 `?page=1`처럼 파라미터를 읽을 때 쓰므로, JSON 본문을 받는 목적과 다르다.

이 주제는 Spring Controller에 첫 생성 API를 만들 때 배우면 좋다. 글을 읽고 나면 “클라이언트가 보내는 JSON은 어디에 두는가”, “입력값은 왜 Entity와 다른 클래스에 두는가”를 코드에서 설명할 수 있다.

## 2. 핵심 개념

요청 본문은 HTTP 요청 안에 실리는 데이터 영역이다. 위 예시에서 중괄호 안의 JSON 전체가 요청 본문이다. Spring은 `@RequestBody`가 붙은 파라미터를 찾으면, 본문을 읽어 알맞은 Java 객체로 변환하려고 한다.

이 변환을 담당하는 것이 HTTP 메시지 변환기다. 어려운 이름이지만, `application/json`이라는 형식을 보고 JSON을 Java 객체로 옮겨 주는 Spring 내부 도구라고 이해하면 충분하다. 필드 이름이 JSON과 DTO에 맞아야 값이 들어간다.

DTO는 API가 받거나 돌려주는 데이터 모양을 위한 클래스다. 주문 Entity는 데이터베이스에 저장할 구조를 표현하고, 요청 DTO는 외부에서 받아도 되는 값만 표현한다. 둘을 나누면 클라이언트가 Entity의 모든 필드를 마음대로 채우는 일을 막을 수 있다.

## 3. 내부 동작 원리

주문 생성 요청은 다음 순서로 흐른다.

1. 클라이언트가 `Content-Type: application/json`과 JSON 본문을 함께 보낸다.
2. Spring MVC가 `/orders`와 `POST`에 맞는 Controller 메서드를 찾는다.
3. `@RequestBody`를 발견하면 메시지 변환기가 본문을 `CreateOrderRequest` 객체로 바꾼다.
4. `@Valid`가 붙어 있으면 배송지처럼 꼭 필요한 값이 비어 있는지 먼저 검사한다.
5. 검사를 통과한 DTO만 `OrderService`로 전달되어 주문 생성에 사용된다.

3번에서 JSON 문법이 잘못되었거나 필드 형식이 맞지 않으면 Controller 메서드 안까지 들어오지 못할 수 있다. 4번에서 검증에 실패하면 Spring은 기본적으로 400 Bad Request 응답을 만든다. 따라서 Service에서 `null`을 억지로 처리하기 전에, 요청이 DTO로 잘 변환되고 있는지부터 확인하는 편이 좋다.

`@RequestBody`가 주문을 저장하는 것은 아니다. Controller는 입력을 받고, Service는 주문 생성 규칙을 처리한다. 이 경계를 지키면 나중에 같은 주문 생성을 관리자 화면이나 다른 API에서 호출해도 Service 규칙을 재사용하기 쉽다.

## 4. 실제 코드

아래 코드는 주문 생성 요청을 DTO로 받고, 간단한 검증 뒤 Service에 넘기는 예시다. Entity의 모든 필드를 외부 입력으로 열어 두지 않는 점을 눈여겨보자.

```java
public class CreateOrderRequest {
    @NotNull
    private Long productId;

    @NotBlank
    private String deliveryAddress;

    public Long getProductId() {
        return productId;
    }

    public void setProductId(Long productId) {
        this.productId = productId;
    }

    public String getDeliveryAddress() {
        return deliveryAddress;
    }

    public void setDeliveryAddress(String deliveryAddress) {
        this.deliveryAddress = deliveryAddress;
    }
}

@RestController
@RequestMapping("/orders")
@RequiredArgsConstructor
public class OrderController {
    private final OrderService orderService;

    @PostMapping
    public ResponseEntity<Long> create(@Valid @RequestBody CreateOrderRequest request) {
        Long orderId = orderService.create(request.getProductId(), request.getDeliveryAddress());
        return ResponseEntity.ok(orderId);
    }
}
```

`@RequestBody`가 JSON을 `CreateOrderRequest`로 바꾼다. `@Valid`는 `@NotNull`, `@NotBlank` 같은 규칙을 검사한다. `productId`가 없거나 배송지가 빈 문자열이면 Service를 호출하기 전에 400 응답으로 끝난다.

이 예시의 응답 코드는 개념에 집중하려고 `200 OK`와 주문 번호만 반환했다. 실제 API에서 새 주문 리소스를 만들고 그 위치까지 약속한다면 `201 Created`와 `Location` 헤더를 검토할 수 있다. 그러나 먼저 고정할 것은 상태 코드보다 입력 JSON과 DTO의 계약이다.

## 5. 실제 서비스 적용

작은 주문 서비스에서는 Controller마다 요청 DTO를 둔다. `CreateOrderRequest`에는 주문 생성에 필요한 값만 넣고, 가격·주문 상태·결제 완료 여부처럼 서버가 결정해야 하는 값은 넣지 않는다. 특히 클라이언트가 `price`나 `status`를 보내도 그대로 믿어 저장하지 않는다는 규칙이 중요하다.

주문 요청이 늘었을 때 가장 먼저 제한할 것은 무조건 요청 수가 아니라 잘못된 입력이 Service와 데이터베이스까지 내려가는 경로다. `@Valid`로 비어 있는 값과 기본 형식 오류를 앞에서 막으면 불필요한 저장 시도를 줄일 수 있다. 다만 상품이 실제로 존재하는지, 현재 판매 가능한지는 Service에서 확인해야 한다. DTO의 검증만으로 업무 규칙이 모두 해결되지는 않는다.

첫 확인 지점은 요청 로그의 `Content-Type`과 400 응답 내용이다. Controller에 브레이크포인트를 걸기 전에 JSON 필드 이름, 요청 주소, 헤더가 코드와 맞는지 살핀다. 테스트에서는 올바른 JSON은 Service가 호출되고, 배송지가 없는 JSON은 Service가 호출되지 않는지를 확인한다.

## 6. 흔히 발생하는 문제

### 1) JSON 요청에 `@RequestParam`을 쓰는 경우

현상은 `productId`와 `deliveryAddress`가 `null`로 들어오거나 요청이 실패하는 것이다. 원인은 URL 파라미터를 읽는 `@RequestParam`으로 JSON 본문을 읽으려 했기 때문이다. 첫 확인 지점은 클라이언트가 보낸 값이 URL인지 JSON 본문인지다. JSON이라면 요청 DTO에 `@RequestBody`를 붙이고, URL의 검색 조건이라면 `@RequestParam`을 사용한다.

### 2) `Content-Type`을 보내지 않는 경우

현상은 JSON 모양은 맞아 보이는데 객체 변환이 실패하는 것이다. 원인은 서버가 요청 본문 형식을 판단할 단서를 받지 못했기 때문이다. 첫 확인 지점은 네트워크 탭이나 요청 로그의 `Content-Type` 헤더다. JSON을 보낼 때는 `application/json`을 명시한다.

### 3) Entity를 `@RequestBody`로 직접 받는 경우

현상은 주문 상태나 가격처럼 서버가 정해야 할 값까지 외부 요청에 섞이기 시작하는 것이다. 원인은 API 입력 구조와 데이터베이스 저장 구조를 같은 클래스로 썼기 때문이다. 첫 확인 지점은 Entity에 있는 필드가 요청 JSON에 그대로 노출됐는지다. 해결 방향은 생성 API 전용 DTO를 만들고, Service에서 필요한 값만 Entity에 옮기는 것이다.

## 7. 기술 선택의 Trade-off

`@RequestBody`와 요청 DTO를 함께 쓰면 API가 받는 데이터가 코드에 분명히 드러난다. 검증 규칙도 DTO 가까이에 모을 수 있어 Controller가 길어지는 것을 줄인다. 반면 API마다 DTO 클래스가 늘어나므로, 단순한 화면 하나를 만들 때는 파일 수가 많아 보일 수 있다.

그래도 주문, 결제, 회원 정보처럼 외부 입력이 데이터 상태를 바꾸는 API에서는 DTO 분리가 더 안전하다. 반대로 URL의 짧은 검색 조건이나 페이지 번호는 `@RequestParam`이 읽기 쉽다. HTML form 데이터를 그대로 받는 경우도 `@RequestParam`을 우선 검토한다. 어떤 형식이든 Entity를 곧바로 외부 입력으로 사용하지 않는 기준은 유지하는 편이 좋다.

결정은 네 단계로 한다. 먼저 클라이언트가 보내는 값이 JSON 본문인지 URL 파라미터인지 확인한다. JSON이면 요청 DTO와 `@RequestBody`를 사용한다. 다음으로 형식 검증은 DTO에, 상품 존재 여부 같은 업무 규칙은 Service에 둔다. 마지막으로 서버가 결정할 필드는 요청 DTO에서 제외한다.

### 참고한 공식 문서

- [Spring Framework @RequestBody](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/requestbody.html) — 요청 본문을 HTTP 메시지 변환기로 객체에 역직렬화하는 방식, `@Valid` 검증 실패가 기본적으로 400 응답으로 이어지는 동작을 확인했다.
