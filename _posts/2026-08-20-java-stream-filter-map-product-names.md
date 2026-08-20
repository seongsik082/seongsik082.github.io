---
title: "Java Stream의 filter와 map을 상품 목록 코드에서 처음 이해하는 방법"
date: 2026-08-20 08:57:00 +0900
tags: [Java, Stream, Backend]
excerpt: "상품 목록에서 판매 중인 상품 이름만 꺼내는 예제로 Java Stream의 filter, map, toList를 이해하고 반복문과 선택 기준을 정리한다."
---

# Java Stream의 filter와 map을 상품 목록 코드에서 처음 이해하는 방법

> **부제:** 목록에서 필요한 것만 고르고, 원하는 값으로 바꾸는 두 단계를 분리하기

**대상 독자:** Java 문법과 간단한 Spring CRUD 코드를 작성해 본 초급 백엔드 개발자

상품 목록을 받아서 “판매 중인 상품 이름만 보여 달라”는 요구는 자주 나온다. 처음에는 `for`문과 `if`문으로 충분히 해결할 수 있다. Java Stream은 목록을 **고르는 일**과 **값을 바꾸는 일**을 읽기 좋은 순서로 표현하는 도구다.

## 1. 오늘의 주제

상품 조회 API가 `Product` 목록을 받았다고 하자. 화면에는 전체 상품 객체가 아니라 판매 중인 상품의 이름만 필요할 수 있다. 이때 해야 할 일은 두 가지다. 첫째, 판매 중인 상품만 남긴다. 둘째, 남은 상품에서 이름만 꺼낸다.

Stream은 이 작업을 `filter`와 `map`으로 나누어 보여 준다.

다만 Stream을 SQL 대신 사용하는 것은 아니다. 데이터베이스에서 가져올 행이 아주 많다면, 먼저 SQL의 `WHERE` 조건으로 행 수를 줄이는 것이 우선이다.

## 2. 핵심 개념

`List<Product>`는 상품 객체를 보관하는 목록이다. Stream은 목록을 저장하는 새 통이 아니라, 요소를 순서대로 읽으며 작업을 연결하는 흐름이다.

`filter`는 조건에 맞는 요소만 남긴다. 예를 들어 상품의 `onSale` 값이 `true`인 상품만 통과시킬 수 있다. 통과하지 못한 상품은 다음 단계로 가지 않는다.

`map`은 요소를 다른 값으로 바꾼다. 여기서는 `Product` 객체를 상품 이름인 `String`으로 바꾼다. `filter`가 “무엇을 남길까”를 담당한다면, `map`은 “남긴 것을 무엇으로 보여 줄까”를 담당한다.

마지막의 `toList()`는 앞 단계의 결과를 `List`로 모은다. `filter`와 `map`은 작업을 연결해 두는 중간 단계이고, `toList()`를 만나야 실제로 결과가 만들어진다.

## 3. 내부 동작 원리

원래 `products` 목록은 바뀌지 않는다. 새로 만들어지는 것은 판매 중인 상품 이름 목록이다.

1. `products.stream()`이 상품 목록을 읽을 준비를 한다.
2. `filter(Product::onSale)`이 각 상품의 판매 여부를 확인한다. 판매 중이 아닌 상품은 여기서 제외된다.
3. 통과한 상품만 `map(Product::name)`으로 이동한다. 이 단계에서 상품 전체 대신 이름만 꺼낸다.
4. `toList()`가 남은 이름들을 새 목록으로 모아 반환한다.

이미 작은 목록을 조회했고 응답 형태만 바꾸려는 경우 Stream은 자연스럽다. 반대로 많은 상품을 먼저 가져온 뒤 `filter`한다면, 데이터베이스 조회 조건을 먼저 고쳐야 한다.

## 4. 실제 코드

아래 코드는 판매 여부와 이름만 가진 간단한 상품 모델이다. Stream을 보기 전에, `Product`가 이름과 판매 여부를 getter로 돌려준다고 생각하면 된다.

```java
import java.util.List;

class Product {
    private final String name;
    private final boolean onSale;

    public Product(String name, boolean onSale) {
        this.name = name;
        this.onSale = onSale;
    }

    public String getName() {
        return name;
    }

    public boolean isOnSale() {
        return onSale;
    }
}

public class ProductService {
    public List<String> findOnSaleNames(List<Product> products) {
        return products.stream()
            .filter(Product::isOnSale)
            .map(Product::getName)
            .toList();
    }
}
```

`products.stream()`은 목록을 Stream으로 바꾼다. `Product::isOnSale`은 각 상품의 `isOnSale()` 메서드를 조건으로 사용한다는 뜻이다. 처음에는 아래처럼 람다식으로 써도 된다.

```java
.filter(product -> product.isOnSale())
```

그 다음 `map(Product::getName)`은 통과한 `Product`에서 `getName()`을 호출해 `String`으로 바꾼다. 따라서 메서드의 반환형은 `List<Product>`가 아니라 `List<String>`이다.

같은 코드를 반복문으로 쓰면 다음과 같다.

```java
List<String> names = new ArrayList<>();
for (Product product : products) {
    if (product.isOnSale()) {
        names.add(product.getName());
    }
}
return names;
```

반복문이 틀린 방법은 아니다. 조건이 여러 갈래로 나뉘거나 중간 상태를 바꿔야 한다면 반복문이 더 읽기 쉬울 수 있다.

## 5. 실제 서비스 적용

상품 목록 API를 생각해 보자. Repository가 데이터베이스에서 필요한 상품을 조회하고, Service가 화면에 맞는 값으로 가공한 뒤 Controller가 응답한다. `filter`와 `map`은 이 중 Service에서 이미 조회한 작은 목록을 응답 형태로 정리할 때 쓸 수 있다.

예를 들어 관리자가 검토할 상품 10개를 가져온 뒤 판매 중인 이름만 알림 메시지에 넣는 기능이라면, 위 메서드를 호출한 결과를 그대로 사용할 수 있다. 테스트에서는 판매 중인 상품 두 개와 판매 중이 아닌 상품 한 개를 넣고, 결과에 이름 두 개만 있는지 확인하면 된다.

하지만 고객 상품 목록처럼 데이터가 계속 늘어나는 조회는 다른 판단이 필요하다. “판매 중인 상품만” 필요하다면 Repository 쿼리에서 먼저 조건을 건다. 예를 들면 `WHERE on_sale = true`로 데이터베이스가 불필요한 행을 보내지 않게 한다. 그 후에 Service에서 이름, 가격, 이미지 주소처럼 응답에 필요한 모양으로 바꾸는 데 Stream을 사용할 수 있다.

결과가 비어 있다면 Service의 `filter` 조건보다 Repository가 실제로 어떤 상품을 조회했는지 먼저 확인한다. 조회된 상품 수는 맞는데 응답 필드가 비어 있다면 `map`에서 어떤 값을 꺼냈는지 확인한다.

## 6. 흔히 발생하는 문제

### 1) Stream을 호출했는데 결과가 없다고 생각하는 경우

현상은 `products.stream().filter(...)`를 작성했는데 화면이나 반환값이 바뀌지 않는 것이다. 원인은 Stream이 원래 `List`를 직접 수정하지 않기 때문이다. 결과를 `toList()`로 받아 반환하거나 변수에 담아야 한다.

처음 확인할 곳은 메서드의 반환문이다. Stream 뒤에 `toList()`가 있고 그 결과를 실제 응답에 쓰는지 확인한다.

### 2) `toList()` 결과에 `add()`를 호출하는 경우

현상은 결과 목록에 이름을 하나 더 넣으려 할 때 `UnsupportedOperationException`이 발생하는 것이다. Java의 `Stream.toList()`가 돌려주는 목록은 수정할 수 없는 목록이기 때문이다. 읽기 전용 응답을 만들 때는 오히려 실수로 수정하는 일을 막아 준다는 장점이 있다.

첫 확인 지점은 예외가 난 줄과 `toList()`로 만든 목록인지 여부다. 이후에 항목을 더해야 한다면 `new ArrayList<>(findOnSaleNames(products))`처럼 수정 가능한 목록을 새로 만들 수 있다. 다만 정말 중간에 목록을 수정해야 하는지 먼저 생각해 보자. 수정이 많다면 처음부터 반복문과 `ArrayList`가 더 단순할 수 있다.

### 3) 데이터베이스 전체 결과를 가져온 뒤 Stream으로 거르는 경우

현상은 코드상으로는 정확하지만 데이터가 늘수록 조회가 느려지고 메모리 사용량이 커지는 것이다. 원인은 데이터베이스가 처리할 수 있는 조건을 애플리케이션까지 가져온 뒤 처리했기 때문이다.

처음 확인할 곳은 Repository의 SQL 또는 JPA가 만든 조회 조건과 조회된 목록 크기다. 판매 여부 같은 검색 조건은 데이터베이스의 `WHERE` 절로 먼저 처리하고, Stream은 이미 필요한 범위로 줄어든 목록을 응답 형태로 바꿀 때 사용한다. 이 선택은 코드 한 줄보다 데이터 이동량에 더 큰 영향을 준다.

## 7. 기술 선택의 Trade-off

Stream의 장점은 `filter`와 `map`처럼 단계가 분명한 작업을 위에서 아래로 읽을 수 있다는 점이다. 특히 목록을 고르고 DTO나 이름 목록으로 바꾸는 코드에서, 각 단계의 책임이 눈에 보인다. 하지만 모든 반복문을 Stream으로 바꾸는 것이 좋은 것은 아니다. 중간 상태를 여러 번 바꾸거나 조건 분기가 길다면 반복문이 더 쉽게 읽히고 디버깅하기도 편하다.

`toList()`는 결과를 수정하지 않아도 되는 API 응답이나 조회 결과에 잘 맞는다. 이후에 항목을 추가해야 한다면 수정 가능한 `ArrayList`를 명시적으로 만들 수 있다.

| 상황 | 더 자연스러운 선택 | 이유 |
| --- | --- | --- |
| 이미 조회한 작은 목록에서 조건 하나를 적용하고 값 하나를 꺼냄 | Stream | 조건과 변환 단계가 짧고 분명하다. |
| 반복 중 로그, 여러 분기, 상태 변경이 필요함 | `for`문 | 중간 과정을 한 줄씩 확인하기 쉽다. |
| 데이터베이스의 많은 행 중 일부만 필요함 | SQL/JPA 조회 조건 + 필요한 경우 Stream | 먼저 전송할 행 수를 줄여야 한다. |
| 결과 목록에 항목을 계속 추가해야 함 | `ArrayList` 또는 `for`문 | `toList()` 결과는 수정할 수 없다. |

실무에서는 다음 순서로 결정하면 된다. 1) 지금 가공하려는 데이터가 이미 메모리에 있는 목록인지 확인한다. 2) 조건으로 고르고 값으로 바꾸는 단순한 흐름이면 Stream을 선택한다. 3) 중간 상태 변경이나 복잡한 분기가 있으면 반복문으로 돌아간다. 4) 데이터베이스에서 가져올 양이 크다면 Stream보다 조회 조건과 페이징을 먼저 검토한다.

### 참고한 공식 문서

- [Java Stream API](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/stream/Stream.html)
- [Java Stream 패키지 설명](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/stream/package-summary.html)
