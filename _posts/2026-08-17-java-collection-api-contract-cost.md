---
title: "Java Collection 선택을 미루면 상품 조회 API의 중복 제거와 응답 순서가 함께 깨지는 이유"
date: 2026-08-17 08:55:00 +0900
tags: [Java, Collection, API, Performance, Backend]
excerpt: "상품 ID 목록을 조회하는 Spring API에서 List, Set, Map을 어떤 책임으로 나눠야 하는지 정리합니다. 입력 순서·중복·조회 비용·동시성 범위를 분리하면 Collection 선택이 구현 취향이 아니라 API 계약과 운영 비용의 판단이 됩니다."
---

# Java Collection 선택을 미루면 상품 조회 API의 중복 제거와 응답 순서가 함께 깨지는 이유

> **부제:** `List`, `Set`, `Map`은 문법 선택이 아니라 입력 계약·조회 비용·공유 범위를 나누는 도구다

**대상 독자:** Java와 Spring Boot로 조회 API를 작성해 봤고, “중복을 없애려면 Set이면 되지 않을까?”라는 판단을 서비스 요구사항과 연결하고 싶은 백엔드 개발자

상품 ID 여러 개를 받는 API는 짧아 보인다. ID 순서·중복·없는 ID의 정책이 정해지지 않으면 컬렉션 선택도 우연에 맡겨진다. 처음에는 `ArrayList` 하나로 끝나지만, 데이터가 늘면 반복 탐색과 응답 순서의 흔들림이 나타난다.

이 글은 상품 조회 흐름에서 `List`, `Set`, `Map`의 책임을 분리한다. 핵심은 중복·순서·키 기반 조회·공유 동시성이라는 요구를 한 자료구조에 억지로 넣지 않는 것이다.

## 1. 오늘의 주제

다음 요청을 처리하는 카탈로그 API를 생각해 보자.

```http
GET /api/products?ids=41,12,41,99
```

클라이언트는 화면 순서대로 상품을 요청했고, 서버는 DB에서 필요한 상품을 한 번에 가져오려 한다. 입력의 `41` 두 개는 두 번 보여야 하는가, DB 조회는 한 번으로 줄일 것인가, 없는 `99`는 어떻게 알릴 것인가를 먼저 정한다. 어느 질문도 `HashMap`이나 `ArrayList`의 이름만으로 답할 수 없다.

이 주제는 Spring Controller와 Repository 사이에 데이터 가공 코드가 늘기 시작할 때 다루기 좋다. 백엔드 개발자는 API 계약을 컬렉션 규칙으로 바꾸고, 인스턴스가 늘어도 요청 결과가 흔들리지 않게 해야 한다.

여기서는 “입력의 첫 등장 순서를 유지하되 중복 상품은 한 번만 응답한다”는 계약을 설계 예시로 둔다. 이 계약이 맞지 않는 도메인도 있다. 장바구니의 동일 상품 두 줄처럼 중복 자체가 수량이나 사용자 의도를 표현한다면, 중복 제거는 최적화가 아니라 데이터 손실이 된다. Collection은 비즈니스 의미를 확인한 뒤에 선택한다.

## 2. 핵심 개념

`List`는 순서가 있는 시퀀스이며 중복을 허용한다. 요청 순서를 전달할 때 자연스럽지만, `List.contains`로 이미 본 ID를 계속 검사하면 앞에서부터 비교하는 일이 반복된다.

`Set`은 같은 원소를 중복으로 담지 않는 집합이다. 중복을 없애는 목적에는 맞지만, 구현체마다 순서 보장은 다르다. `HashSet`은 순회를 어떤 순서로 할지 계약하지 않는다. 요청의 첫 등장 순서를 유지하면서 중복만 제거하려면 삽입 순서를 정의하는 `LinkedHashSet`이 더 직접적이다. “Set이면 순서가 없다”가 아니라 “필요한 순서를 해당 구현체가 보장하는가”를 확인해야 한다.

`Map`은 키에서 값으로 가는 인덱스다. DB가 반환한 `ProductSummary` 목록을 상품 ID로 다시 찾으려면 `Map<Long, ProductSummary>`가 적합하다. 목록을 반복 탐색하지 않고 요청 ID별 lookup 책임을 분리할 수 있다. 다만 `HashMap`의 순회 순서는 지정되지 않았으므로 map 순회 결과를 곧바로 API 응답으로 쓰면 안 된다.

`equals`와 `hashCode`도 컬렉션 계약의 일부다. key로 넣은 객체의 비교 기준이 바뀌면 이후 조회 결과를 기대할 수 없다. 상품 ID처럼 불변인 `Long`을 key로 쓰면 lookup 기준을 안정적으로 유지할 수 있다.

동시성은 별도의 질문이다. 요청 메서드 안에서 새로 만든 `HashMap`은 그 요청만 사용하므로 동시 map일 필요가 없다. 여러 HTTP 요청이 함께 읽고 쓰는 전역 map이라면 일반 `HashMap`을 공유하면 안 된다. `ConcurrentMap`은 개별 연산의 원자성과 스레드 안전성을 제공하지만, 여러 단계 로직 전체나 캐시 만료·최신성까지 해결하지는 않는다.

## 3. 내부 동작 원리

이 API의 데이터를 세 번 변환한다고 보자. 첫 번째는 HTTP query string을 순서 있는 `List<Long>`로 바꾸는 단계다. 이 단계에서는 클라이언트가 보낸 원래 순서를 잃지 않는다. 두 번째는 DB 조회량을 줄이기 위해 `LinkedHashSet<Long>`으로 바꾸는 단계다. 중복 ID는 제거하지만 첫 등장 순서는 남는다. 세 번째는 Repository가 반환한 상품 목록을 `Map<Long, ProductSummary>`로 색인하는 단계다.

응답은 map의 `values()`를 그대로 반환하지 않는다. ordered ID를 다시 순회하면서 map에서 상품을 꺼낸다. `WHERE id IN (...)` 결과 순서는 `ORDER BY` 없이는 계약된 결과가 아니다. 순서가 API 계약이라면 Java 조립 단계 또는 명시적 SQL 정렬이 책임져야 한다.

이 흐름에서 `LinkedHashSet`과 `Map`은 추가 메모리를 사용한다. 항목이 매우 작고 한 번만 순회한다면 map 생성은 과할 수 있다. 그러나 동일 ID를 반복 조회하거나 Repository 결과를 요청 순서로 복원한다면 인덱스가 더 분명한 선택이다.

실패 처리도 데이터 변환 경계에서 정한다. 숫자가 아닌 값은 Controller validation에서 400으로 끝낼 수 있다. DB에 없는 ID는 생략·`missingIds` 반환·전체 실패 중 하나로 계약해야 한다. map의 `null`을 그대로 응답 정책으로 삼으면 부분 성공을 해석하기 어렵다.

요청 안의 map은 메서드가 끝나므로 락이 필요 없다. 반면 `ConcurrentHashMap` 로컬 캐시는 여러 요청이 함께 접근한다. 이때는 put/get 원자성 외에 만료·무효화·여러 Pod 간 불일치를 따로 설계한다.

## 4. 실제 코드

아래 코드는 요청의 첫 등장 순서를 유지하면서 중복 조회를 줄이고, DB가 반환한 결과를 안정적으로 조립하는 Spring Service 예시다. `ProductRepository`는 `findSummariesByIds`로 필요한 행만 조회한다고 가정한다. 중복 ID가 Repository 결과에 들어오면 데이터 조립 오류로 보고 예외를 내도록 했으며, 임의로 앞 또는 뒤 값을 덮어쓰지 않는다.

```java
@Service
@RequiredArgsConstructor
public class ProductLookupService {
    private final ProductRepository productRepository;

    @Transactional(readOnly = true)
    public ProductLookupResponse findByRequestedIds(List<Long> requestedIds) {
        List<Long> orderedUniqueIds = new ArrayList<>(new LinkedHashSet<>(requestedIds));

        Map<Long, ProductSummary> productsById = productRepository
                .findSummariesByIds(orderedUniqueIds)
                .stream()
                .collect(Collectors.toMap(
                        ProductSummary::id,
                        Function.identity(),
                        (left, right) -> {
                            throw new IllegalStateException("duplicate product id from query result");
                        }
                ));

        List<ProductSummary> found = orderedUniqueIds.stream()
                .map(productsById::get)
                .filter(Objects::nonNull)
                .toList();

        List<Long> missingIds = orderedUniqueIds.stream()
                .filter(id -> !productsById.containsKey(id))
                .toList();

        return new ProductLookupResponse(found, missingIds);
    }
}
```

`new LinkedHashSet<>(requestedIds)`는 중복을 제거하면서 첫 삽입 순서를 유지한다. 그 다음 `new ArrayList<>(...)`로 바꾼 이유는 Repository 호출과 응답 조립에서 “순서 있는 ID 목록”이라는 의도를 드러내기 위해서다. 결과 map은 빠른 조회를 위한 내부 인덱스일 뿐, 응답의 순서를 결정하는 자료가 아니다.

Repository 쿼리는 조회 대상만 줄이는 역할을 한다. `IN` 절의 값 개수와 API의 최대 ID 개수는 함께 제한해야 한다. 검증 없는 목록을 그대로 받으면 URL 길이, SQL parameter 수, DB 작업량이 동시에 커질 수 있다.

```sql
SELECT id, name, price, sale_status
FROM product
WHERE id IN (:ids)
  AND sale_status = 'ON_SALE';
```

이 코드에서 `missingIds`를 반환한 것은 설계 예시다. 주문 직전처럼 모든 상품이 반드시 존재해야 하는 API라면 누락 ID가 하나라도 있을 때 실패시키는 계약이 더 안전할 수 있다. 반대로 검색 결과를 넓게 보여 주는 화면이라면 누락을 생략하되 로그와 메트릭으로 비율을 관찰하는 편이 자연스럽다. 중요한 것은 `filter(Objects::nonNull)`이 정책을 몰래 결정하지 않게 하는 것이다.

## 5. 실제 서비스 적용

실제 요청 흐름에서는 Controller가 `ids`를 파싱하고 최대 개수·null·형식을 검증한다. Service는 중복 제거와 순서 복원, 누락 정책을 맡는다. Repository는 필요한 행만 DB에서 읽는다. 이 경계를 지키면 DB가 어떤 순서로 행을 반환하든 응답 계약은 Service에서 일정하게 유지된다. `List`는 외부 입력과 최종 표현, `LinkedHashSet`은 중복 제거, `Map`은 내부 조회라는 책임 분리가 된다.

트래픽이 증가할 때 먼저 봐야 할 지표는 전체 요청 수만이 아니다. 요청당 ID 개수의 분포, 중복 제거 전후 개수 차이, Repository 조회 행 수, 누락 ID 비율, 이 endpoint의 p95·p99 지연을 같이 본다. 예를 들어 평균 ID 개수는 작아도 특정 client가 수천 개를 보내면 DB query와 응답 직렬화 비용이 달라진다. 이때 처음 할 일은 `HashMap`의 초기 용량을 손으로 조절하는 것이 아니라 API 최대 개수와 pagination·batch API의 경계를 재검토하는 것이다.

장애 영향도 나눠 본다. DB가 느려지면 map 조립 자체는 빨라도 요청 전체가 기다린다. 캐시를 추가하더라도 존재하지 않는 ID 요청, 만료 직후 동시 요청, 상품 상태 변경의 반영 지연이 새로 생긴다. 조회 API의 중복 제거는 DB 부하를 줄일 수 있지만, 캐시 정합성의 근거가 되지는 않는다. 먼저 요청 범위와 쿼리 수를 제한하고, 반복 조회가 실제 병목이라는 측정이 있을 때만 cache-aside를 검토한다.

검증은 같은 ID가 반복되는 요청, 입력 순서가 다른 요청, 존재하지 않는 ID가 섞인 요청, DB 결과 순서를 바꾼 테스트를 포함한다. 특히 Repository가 `12,41,99` 순서로 반환해도 요청 `41,12,41,99`에 대한 응답이 계약대로 `41,12`인지 확인한다. 실패가 발생하면 첫 확인 지점은 map 구현체가 아니라 Controller가 정한 중복·누락 정책과 Repository가 실제로 반환한 ID 목록이다.

## 6. 흔히 발생하는 문제

첫 번째 문제는 중복 제거를 `List.contains`로 처리하는 것이다. 현상은 입력 목록이 커질수록 API CPU 시간과 지연이 늘어나는 모습이다. 근본 원인은 이미 본 ID를 확인할 때마다 목록 처음부터 비교하는 반복 탐색이다. profiler에서 해당 루프의 CPU 비중과 요청당 ID 개수를 같이 확인하고, 중복 제거가 계약에 맞다면 `LinkedHashSet`으로 바꾼다. 부작용은 HashSet으로 바꾸었을 때 입력 순서를 잃을 수 있다는 점이므로, 필요한 순서를 명시한다.

두 번째 문제는 `HashMap.values()`를 응답으로 반환해 우연한 순서를 API 계약처럼 쓰는 것이다. 현상은 같은 요청인데 응답 정렬 테스트가 불안정하거나, JDK·입력 조합이 달라질 때 화면 순서가 바뀌는 것이다. 근본 원인은 `HashMap`이 순회 순서를 보장하지 않는다는 데 있다. 응답 순서가 필요하면 ordered ID 목록으로 map을 조회하거나, 기본 삽입 순서 설정의 `LinkedHashMap`을 쓴다. 이 선택은 연결 구조를 위한 추가 메모리를 쓰므로 단순 순서가 불필요한 내부 인덱스에는 적용하지 않는다.

세 번째 문제는 `Collectors.toMap`의 merge 함수에 `(oldValue, newValue) -> newValue`를 넣어 중복 행을 조용히 덮는 것이다. 현상은 같은 상품 ID에 서로 다른 가격이나 상태가 있어도 마지막 값이 응답에 남는 것이다. 근본 원인은 Repository join이나 projection이 중복 행을 만들었는데 Service가 데이터를 잃는 방식으로 숨긴 데 있다. 발견 방법은 조회 결과의 ID 수와 distinct ID 수를 비교하는 테스트·로그다. 중복이 정상인 도메인이라면 `groupingBy`로 값의 복수성을 표현하고, 정상이어서는 안 된다면 예외·데이터 정합성 조사로 이어간다.

네 번째 문제는 전역 `HashMap`을 간단한 로컬 캐시로 두고 여러 요청에서 수정하는 것이다. 현상은 동시 부하에서 간헐적인 누락, 예외, 오래된 값처럼 재현하기 어려운 문제가 된다. 근본 원인은 일반 map이 동시 수정의 원자성 계약을 제공하지 않는 데 있다. 먼저 shared state가 꼭 필요한지 확인하고, 필요하면 `ConcurrentHashMap` 또는 만료·크기·통계를 갖춘 캐시 라이브러리를 선택한다. 다만 동시 map으로 바꿔도 TTL, eviction, 여러 Pod 간 불일치는 해결되지 않는다는 부작용을 남긴다.

## 7. 기술 선택의 Trade-off

`ArrayList`는 입력·응답 순서와 중복 자체가 의미일 때 가장 단순하다. 반면 값 존재 확인을 반복하는 인덱스로 쓰기에는 맞지 않을 수 있다. `HashSet`과 `HashMap`은 순서가 중요하지 않은 중복 제거·키 lookup에 가볍게 쓸 수 있지만, 순회 결과를 외부 API에 노출하면 안 된다. `LinkedHashSet`과 `LinkedHashMap`은 삽입 순서가 필요할 때 의도를 분명히 하지만 연결 정보를 유지하는 비용이 추가된다.

공유 동시성이 필요한 경우 `ConcurrentHashMap`은 일반 map보다 적절한 선택일 수 있다. 하지만 이것은 프로세스 안의 원자성 문제를 다루는 도구다. 캐시 크기 제한, 만료, cache stampede, 인스턴스 사이의 무효화, DB와의 최신성은 다른 계층의 문제다. 데이터와 트래픽이 늘수록 컬렉션을 바꾸는 것보다 API 최대 크기, DB index·query, 캐시 정책, 메시지 기반 갱신을 각각 검토해야 한다.

중복 제거를 적용하지 않아야 하는 경우도 있다. 장바구니 항목, 이벤트 수신 횟수, 사용자가 입력한 우선순위처럼 중복과 순서가 도메인 데이터인 경우다. `Set`으로 바꾸면 성능은 좋아 보여도 “두 개 담았다”는 사실을 한 개로 만들어 버린다. Collection 구현체는 비즈니스 의미를 보존한 다음에야 최적화 도구가 된다.

실무에서는 다음 다섯 단계로 결정한다.

1. 입력의 순서와 중복이 API 또는 도메인 의미인지 먼저 문장으로 정한다.
2. 존재 확인·키 lookup이 반복되는지 확인하고, 반복된다면 `Set` 또는 `Map` 인덱스를 분리한다.
3. 외부 응답 순서가 필요하면 `HashMap` 순회에 기대지 않고 ordered 목록 또는 순서 보장 구현체를 선택한다.
4. 요청 지역 데이터와 여러 요청이 공유하는 데이터를 나눠, 공유할 때만 동시 컬렉션과 캐시 정책을 검토한다.
5. 요청당 항목 수·중복률·DB 조회 행 수·지연을 측정한 뒤 API 제한, 쿼리, 캐시 중 실제 병목에 맞는 계층을 조정한다.

### 참고한 공식 문서

- [Oracle Java 21 Collections Framework 개요](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/doc-files/coll-reference.html): `List`, `Set`, `Map`, 동시 컬렉션의 역할과 계약을 확인했다.
- [Oracle Java 21 Map](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/Map.html): map 순회 순서와 변경 가능한 key 사용의 주의점을 확인했다.
- [Oracle Java 21 LinkedHashMap](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/LinkedHashMap.html): 삽입 순서와 access-order 동작을 확인했다.
- [Oracle Java 21 ConcurrentMap](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/concurrent/ConcurrentMap.html): 동시 접근의 원자성·memory consistency 보장 범위를 확인했다.
