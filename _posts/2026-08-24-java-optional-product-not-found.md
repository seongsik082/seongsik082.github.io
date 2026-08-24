---
title: "Java Optional로 상품을 찾지 못했을 때 분기하는 방법"
date: 2026-08-24 08:56:00 +0900
tags: [Java, Optional, Backend]
excerpt: "단건 상품 조회에서 null 대신 Optional을 받고, 값이 없을 때 이유가 분명한 예외를 만드는 방법을 초급 Java 코드로 설명한다."
---

# Java Optional로 상품을 찾지 못했을 때 분기하는 방법

> **부제:** 값이 없을 수 있다는 사실을 메서드 반환값에 드러내기

**대상 독자:** Java 문법과 간단한 Spring CRUD를 막 익힌 초급 백엔드 개발자

상품 상세 화면을 만들면 상품 ID로 상품 하나를 찾는 코드가 필요하다. 그런데 사용자가 이미 삭제된 상품 주소를 열거나, 존재하지 않는 ID를 요청할 수 있다. 이때 조회 결과가 없다는 상황을 미리 코드에 적어 두지 않으면, 뒤에서 `NullPointerException`이 발생한 이유를 찾기 어려워진다.

`Optional`은 값이 하나 있거나 없을 수 있음을 표현하는 Java 타입이다. 이 글에서는 단건 상품 조회에서 `Optional`을 받은 뒤, 상품이 없을 때 어디에서 처리할지 한 가지 방법만 살펴본다.

## 1. 오늘의 주제

상품 ID `10`으로 조회했는데 상품이 없다고 해 보자. 초급 개발자는 조회 메서드가 `null`을 반환하는지, 예외를 던지는지, 빈 객체를 반환하는지 알기 어려울 수 있다. 호출하는 쪽이 이를 모르고 상품 이름을 바로 꺼내면 오류가 난다.

이럴 때 Repository가 `Optional<Product>`를 돌려주면, Service 코드를 읽는 사람도 “상품이 없을 수 있구나”를 알 수 있다. 글을 읽고 나면 단건 조회 결과가 없을 때 `get()`으로 꺼내지 않고, 서비스에 맞는 처리를 선택할 수 있다.

`Optional`은 모든 변수에 붙이는 기능이 아니다. 특히 “조회 결과가 없을 수 있다”는 뜻을 메서드의 반환값에 보여 줄 때 가장 이해하기 쉽다.

## 2. 핵심 개념

`null`은 값이 없다는 표시다. 하지만 변수에 `null`이 들어 있다는 사실은 코드를 실행하기 전까지 놓치기 쉽다. `Optional<Product>`는 상품이 있으면 `Product`를 담고, 없으면 비어 있는 상태를 담는다.

`orElseThrow`는 값이 있으면 그 값을 꺼내고, 없으면 지정한 예외를 던진다. “상품이 없으면 더 진행할 수 없다”는 규칙을 한 줄에 나타내기 좋다. 반대로 상품이 없어도 기본 화면을 보여 줄 수 있다면 `orElse`처럼 기본값을 주는 방법을 생각할 수 있다.

여기서 예외는 프로그램이 무조건 실패했다는 뜻이 아니다. API에서는 없는 상품을 찾았다는 사실을 Controller 예외 처리로 전달하는 신호로 쓸 수 있다. 우선은 Service가 조회 실패를 조용히 넘기지 않는다는 점을 이해하면 된다.

## 3. 내부 동작 원리

단건 상품 조회는 다음 순서로 진행된다.

1. Controller가 상품 ID를 받아 Service의 조회 메서드를 호출한다.
2. Service가 Repository에 ID를 전달한다.
3. Repository가 상품을 찾으면 값이 든 `Optional<Product>`를, 찾지 못하면 비어 있는 `Optional`을 돌려준다.
4. Service의 `orElseThrow`가 상품을 반환하거나, 없다는 예외를 만든다.

중요한 점은 `Optional` 자체가 상품이 아니라는 것이다. 상품이 있는지 없는지를 함께 표현하는 상자에 가깝다. 따라서 값이 없을 수 있는데 `get()`으로 바로 꺼내면, 없는 경우에 `NoSuchElementException`이 발생한다.

조회가 실패한 첫 지점은 Service가 아니라 실제 데이터일 수도 있다. 테스트에서는 존재하는 ID와 존재하지 않는 ID를 각각 넣어 보고, 두 경우가 다른 결과를 내는지 확인하면 흐름을 이해하기 좋다.

## 4. 실제 코드

아래 예시는 Spring Data JPA의 Repository가 `findById`로 `Optional<Product>`를 반환한다고 가정한 Service 코드다. `ProductNotFoundException`은 상품이 없다는 뜻을 이름으로 보여 주는 예외 클래스라고 생각하면 된다.

```java
import java.util.Optional;

public class ProductService {
    private final ProductRepository productRepository;

    public ProductService(ProductRepository productRepository) {
        this.productRepository = productRepository;
    }

    public Product findProduct(Long productId) {
        Optional<Product> product = productRepository.findById(productId);

        return product.orElseThrow(
            () -> new ProductNotFoundException(productId)
        );
    }
}
```

`findById(productId)`의 결과를 바로 `Product`에 넣지 않고 `Optional<Product>`에 받는다. 이 변수는 “상품이 없을 수도 있다”는 정보를 유지한다.

그 다음 `orElseThrow`가 분기한다. 상품이 있으면 `Product`를 반환한다. 비어 있으면 `ProductNotFoundException`을 만든다. 이후 코드는 상품이 반드시 있다는 전제로 작성할 수 있으므로, 매번 `null`인지 확인하지 않아도 된다.

처음에는 아래처럼 한 줄로 써도 된다. 다만 여러 줄로 나누면 디버깅할 때 조회 결과와 예외 발생 위치를 보기 쉽다.

```java
return productRepository.findById(productId)
    .orElseThrow(() -> new ProductNotFoundException(productId));
```

## 5. 실제 서비스 적용

작은 Spring 서비스에서는 Service의 단건 조회 메서드에 이 패턴을 적용할 수 있다. Controller는 `findProduct`를 호출하고, 정상일 때만 상품 응답 DTO를 만든다. 상품이 없는 경우는 전역 예외 처리 코드에서 404 응답으로 바꾸는 식으로 정리할 수 있다.

입력이 늘어날 때는 ID 하나당 조회를 반복하지 않도록 주의한다. 상품 ID 여러 개를 한 번에 조회해야 한다면 반복문 안에서 `findById`를 여러 번 호출하기보다, 목록 조회 방법을 따로 검토해야 한다. 지금의 `Optional` 예제는 **상품 하나**를 찾는 경우에만 집중한다.

문제가 생겼을 때 먼저 확인할 것은 테스트다. 존재하지 않는 ID로 `findProduct`를 호출했을 때 정말 `ProductNotFoundException`이 나오는지 확인한다. 예외가 예상과 다르면 Repository가 어떤 ID를 조회했는지와 테스트 데이터에 그 상품이 있는지를 먼저 본다.

## 6. 흔히 발생하는 문제

### 1) `get()`으로 바로 값을 꺼내는 경우

현상은 개발 중에는 잘 되다가 존재하지 않는 상품 ID에서 `NoSuchElementException`이 나는 것이다. 원인은 비어 있는 `Optional`에서도 `get()`을 호출했기 때문이다.

첫 확인 지점은 `optional.get()`이 있는 줄이다. 상품이 반드시 있어야 한다면 `orElseThrow`로 어떤 예외를 낼지 코드에 적는다. 상품이 없어도 괜찮다면 기본값이나 다른 화면 흐름을 선택한다.

### 2) `Optional` 변수 자체에 `null`을 넣는 경우

현상은 `Optional`을 썼는데도 다시 `NullPointerException`이 나는 것이다. 원인은 `Optional`이 비어 있는 상태와 `Optional` 변수 자체가 `null`인 상태를 섞었기 때문이다.

첫 확인 지점은 Repository 구현과 반환문이다. 값이 없을 때는 `null` 대신 `Optional.empty()`를 반환해야 한다. 호출하는 쪽도 `Optional`을 받았다면 그 자체가 `null`이라고 가정하지 않는 편이 좋다.

### 3) 값이 없어도 되는 화면에서 예외를 던지는 경우

현상은 추천 상품이나 선택 항목처럼 비어 있어도 되는 화면이 500 오류로 끝나는 것이다. 원인은 모든 빈 결과에 `orElseThrow`를 사용했기 때문이다.

첫 확인 지점은 “이 값이 없으면 요청 전체가 실패해야 하는가”라는 요구사항이다. 반드시 필요한 상품 상세 조회라면 예외가 맞을 수 있다. 선택 정보라면 `orElse`나 빈 응답을 사용해 흐름을 계속할지 결정한다.

## 7. 기술 선택의 Trade-off

`Optional`의 장점은 값이 없을 수 있다는 사실을 반환형에 보여 준다는 점이다. Service를 호출하는 사람은 `Product`가 바로 오지 않는다는 것을 보고 처리 방법을 생각하게 된다. 특히 단건 조회처럼 결과가 하나이거나 없을 수 있는 메서드에서 의미가 분명하다.

단점은 모든 필드와 변수에 붙이면 코드가 길어지고, 오히려 읽기 어려워진다는 점이다. 상품 이름 필드가 비어도 되는지 같은 데이터 규칙은 `Optional`보다 데이터 검증과 모델 설계로 다루는 편이 자연스러운 경우가 많다.

| 상황 | 선택 | 이유 |
| --- | --- | --- |
| 상품 상세처럼 없으면 요청을 끝내야 함 | `orElseThrow` | 실패 이유를 Service에서 분명히 만든다. |
| 선택 정보처럼 없어도 화면을 만들 수 있음 | `orElse` 또는 빈 응답 | 기본 흐름을 계속할 수 있다. |
| 객체의 모든 필드 | 일반 타입과 검증 | `Optional`을 필드마다 쓰면 코드가 복잡해진다. |

결정은 네 단계면 충분하다. 1) 이 메서드가 값을 찾지 못할 수 있는지 확인한다. 2) 그렇다면 반환형으로 `Optional`을 고려한다. 3) 값이 없을 때 요청을 멈출지, 기본 흐름을 이어 갈지 정한다. 4) 그 선택을 `orElseThrow` 또는 기본값 처리로 코드에 드러낸다.

### 참고한 공식 문서

- [Java Optional API](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/Optional.html)
