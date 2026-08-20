---
title: "상품 ID 대량 조회에서 DB 반환 순서에 기대면 API 응답 계약이 깨지는 이유"
date: 2026-08-20 08:55:00 +0900
tags: [Java, PostgreSQL, SQL, Performance, Backend]
excerpt: "여러 상품 ID를 한 번에 조회할 때 입력 순서를 PostgreSQL WITH ORDINALITY와 ORDER BY로 보장하는 방법을 정리합니다. Java Map 재조립 방식과 비교해 입력 크기, 누락 상품, 중복 의미, 쿼리 비용을 어디에서 판단할지 설명합니다."
---

# 상품 ID 대량 조회에서 DB 반환 순서에 기대면 API 응답 계약이 깨지는 이유

> **부제:** 요청 순서는 데이터가 아니라 계약이다. PostgreSQL `WITH ORDINALITY`와 Java 조립 중 책임질 계층을 선택하는 법

**대상 독자:** Spring Boot와 PostgreSQL로 조회 API를 만들고 있으며, 여러 ID를 한 번에 조회한 결과를 요청 순서대로 돌려줘야 하는 백엔드 개발자

상품 상세 화면이나 비교 기능은 여러 상품 ID를 한 번에 서버로 보낸다. `WHERE id IN (...)`은 필요한 행을 가져오지만, 클라이언트가 보낸 순서로 반환한다는 보장은 없다. 실행 계획·통계·데이터 분포가 바뀌면 우연히 맞던 응답 순서도 흔들릴 수 있다.

지난 글에서 `List`, `LinkedHashSet`, `Map`의 책임을 분리했다면, 이제는 그 순서를 Java에서 다시 조립할지 DB가 위치를 가진 행으로 반환하게 할지 선택해야 한다. 이 글은 PostgreSQL을 사용하는 상품 일괄 조회 API를 설계 예시로 삼아, 순서 보장과 입력 크기 제한을 같은 문제로 다룬다.

## 1. 오늘의 주제

다음처럼 상품 ID 목록을 받는 API를 생각해 보자.

```http
POST /api/products:batch-get
Content-Type: application/json

{ "ids": [41, 12, 99, 41] }
```

여기서 먼저 정할 것은 SQL 문법이 아니다. 첫째, `41`이 두 번 왔을 때 응답도 두 번이어야 하는지 정한다. 둘째, 판매 중이 아니거나 삭제된 `99`를 생략할지, 누락 목록을 반환할지, 요청 전체를 실패시킬지 정한다. 셋째, 응답 순서를 입력 순서로 약속할지 정한다. 이 세 가지가 정해져야 중복 제거와 `ORDER BY`가 최적화인지 데이터 손실인지 판단할 수 있다.

이 주제는 Collection 기본기를 실제 DB 조회로 연결하는 시점에 중요하다. Java/Spring 개발자는 DB가 행을 찾는 책임과 API가 결과를 표현하는 책임을 분리해야 한다.

이 글의 설계 예시는 “첫 등장 순서대로 한 번씩만 반환하고, 찾지 못한 ID는 `missingIds`로 알린다”이다. 주문 라인처럼 중복이 수량을 뜻하는 API에는 이 정책을 적용하지 않는다. 같은 SQL 패턴도 도메인 계약에 따라 중복 제거 전의 ID 배열을 그대로 사용해야 할 수 있다.

## 2. 핵심 개념

SQL 결과는 `ORDER BY`가 없으면 특정 순서로 반환된다고 약속되지 않는다. `IN`에 넣은 값의 순서, PK 인덱스의 물리적 구조, 테이블에 저장된 순서는 API의 순서 계약이 아니다. 특히 실행 계획은 통계, 캐시, 데이터 양에 따라 바뀔 수 있으므로 테스트에서 한 번 맞았다는 사실만으로 순서가 보장되지는 않는다.

PostgreSQL의 `unnest`는 배열을 행 집합으로 펼친다. 여기에 `WITH ORDINALITY`를 붙이면 각 원소가 배열에서 몇 번째였는지 나타내는 위치 열을 함께 얻는다. 예를 들어 `[41, 12, 99]`는 `id=41, position=1` 같은 행이 된다. 이 위치를 상품 테이블과 join하고 `ORDER BY position`을 쓰면, 입력 순서를 SQL의 명시적인 정렬 기준으로 만들 수 있다.

`LinkedHashSet`은 중복을 제거하면서 첫 삽입 순서를 유지한다. “같은 상품은 한 번만 응답”이라는 계약일 때만 `List<Long>`를 ordered unique ID 목록으로 바꾼다. 중복이 의미라면 변환하지 않는다. `WITH ORDINALITY`는 중복 원소 각각에 위치를 주므로 원본 배열도 순서대로 join할 수 있다.

`IN` 결과를 Java `Map<Long, ProductSummary>`로 색인한 뒤 ordered ID 목록을 다시 순회할 수도 있다. 이 방식은 DB 정렬을 피하는 대신 결과 map과 누락 ID 조립 메모리를 쓴다. 입력 크기·DB 부하·응답 형태·DB 이식성에 따라 책임을 고른다.

## 3. 내부 동작 원리

요청이 들어오면 Controller는 ID가 비어 있지 않은지, 숫자 범위가 맞는지, 한 요청에 허용할 최대 개수를 넘지 않는지 확인한다. Service는 계약이 허용할 때만 `LinkedHashSet`으로 첫 등장 순서를 유지한 중복 제거를 한다. 이 목록은 JDBC에서 PostgreSQL `bigint[]` 배열 parameter 하나로 전달된다. 문자열로 `IN (41,12,99)`를 이어 붙이지 않는 이유는 값과 SQL 구조를 분리하고, 입력 수에 따라 SQL 텍스트가 불필요하게 달라지는 일을 줄이기 위해서다.

DB에서는 `unnest`가 배열 원소마다 한 행을 만들고 `WITH ORDINALITY`가 위치를 더한다. `product.id`와 join할 때 상품의 PK 또는 조회 조건에 맞는 인덱스는 상품을 찾는 비용에 영향을 준다. 이후 `ORDER BY requested.position`이 위치 기준 결과를 만든다. 위치 정렬은 비용이 없는 약속이 아니다. 요청 목록이 커질수록 배열 전개 행, join 대상, 정렬해야 할 행이 같이 늘어난다.

판매 중인 상품만 반환하는 조건을 넣으면 입력 ID와 최종 행 수가 달라질 수 있다. 삭제된 상품, 비공개 상품, 권한이 없는 상품은 join 뒤 필터에서 빠질 수 있다. 따라서 결과 행만 반환하면 클라이언트는 “상품이 없었는지, 정책상 보이지 않는지, 서버가 일부를 놓쳤는지”를 구분하지 못한다. API가 부분 성공을 허용한다면 Service는 요청 ID와 반환 ID의 차이를 계산해 `missingIds` 또는 도메인에 맞는 상태를 명시한다.

동시성의 경계도 중요하다. ordered ID 목록, JDBC array, RowMapper가 만든 응답 목록은 한 요청 안에서만 쓰는 지역 값이다. 여러 요청이 같은 목록을 공유하는 것이 아니므로 동시 컬렉션을 넣어 해결할 문제가 아니다. 반면 이 조회 결과를 로컬 캐시에 올리면 여러 스레드와 Pod가 같은 상품 상태를 서로 다른 시점에 볼 수 있다. 순서를 보장하는 SQL과 캐시 최신성은 분리된 문제이며, 캐시 도입은 실제 DB 병목과 무효화 요구를 확인한 뒤에 결정한다.

## 4. 실제 코드

다음 예시는 PostgreSQL에서만 사용할 수 있는 `WITH ORDINALITY`를 JDBC array parameter와 함께 쓰는 Repository다. Service가 ordered unique ID 목록을 넘긴다고 가정한다. `ORDER BY requested.position`을 빼면 ordinality 열이 있어도 최종 행 순서는 보장되지 않는다.

```java
@Repository
@RequiredArgsConstructor
public class ProductBatchQueryRepository {
    private final JdbcTemplate jdbcTemplate;

    public List<ProductSummary> findInRequestedOrder(List<Long> orderedIds) {
        if (orderedIds.isEmpty()) {
            return List.of();
        }

        return jdbcTemplate.execute((ConnectionCallback<List<ProductSummary>>) connection -> {
            Array idArray = connection.createArrayOf("bigint", orderedIds.toArray(Long[]::new));
            try (PreparedStatement statement = connection.prepareStatement("""
                    WITH requested(id, position) AS (
                        SELECT input.id, input.position
                        FROM unnest(?::bigint[]) WITH ORDINALITY AS input(id, position)
                    )
                    SELECT p.id, p.name, p.price
                    FROM requested
                    JOIN product p ON p.id = requested.id
                    WHERE p.sale_status = 'ON_SALE'
                    ORDER BY requested.position
                    """)) {
                statement.setArray(1, idArray);
                try (ResultSet rs = statement.executeQuery()) {
                    List<ProductSummary> results = new ArrayList<>();
                    while (rs.next()) {
                        results.add(new ProductSummary(
                                rs.getLong("id"), rs.getString("name"), rs.getBigDecimal("price")));
                    }
                    return results;
                }
            } finally {
                idArray.free();
            }
        });
    }
}
```

Service는 SQL에 전달할 목록과 응답 정책을 담당한다. 최대 개수는 서비스 요구에 맞춰 정하며, 중복 제거 전의 원본 요청부터 제한해야 한다. 그래야 반복 ID로 애플리케이션 메모리 경계를 우회할 수 없다.

```java
public ProductBatchResponse findProducts(List<Long> requestedIds) {
    if (requestedIds.size() > maxBatchSize) {
        throw new IllegalArgumentException("too many requested product ids");
    }

    List<Long> orderedUniqueIds = new ArrayList<>(new LinkedHashSet<>(requestedIds));
    List<ProductSummary> found = productBatchQueryRepository.findInRequestedOrder(orderedUniqueIds);
    Set<Long> foundIds = found.stream().map(ProductSummary::id).collect(Collectors.toSet());
    List<Long> missingIds = orderedUniqueIds.stream().filter(id -> !foundIds.contains(id)).toList();
    return new ProductBatchResponse(found, missingIds);
}
```

이 코드는 PostgreSQL 드라이버의 SQL array와 `JdbcTemplate`을 전제로 한다. Spring의 `JdbcTemplate`은 connection·statement 같은 JDBC 자원 수명 관리를 돕지만, 애플리케이션은 query의 입력 크기와 반환 정책을 여전히 책임져야 한다. JPA를 쓰는 서비스라도 이처럼 순서가 중요한 일괄 조회는 native query 또는 JDBC 경계로 분리하는 편이 읽기 쉬울 수 있다.

## 5. 실제 서비스 적용

상품 비교 화면, 장바구니 미리보기, AI Commerce Platform의 추천 결과 검증은 여러 상품 ID를 입력 순서대로 확인해야 하는 상황이다. 예를 들어 Agent가 추천 후보 ID를 만들더라도, Agent가 DB를 직접 읽게 하지 않고 Product Service의 batch-get API가 판매 상태·권한·누락 정책을 검증해 반환하도록 둔다. 이 글의 SQL은 Product Service 내부 구현에만 머물고, 상위 서비스는 `found`와 `missingIds`라는 검증된 계약을 받는다.

트래픽이 늘면 `WITH ORDINALITY`가 있어서 안전하다고 끝나지 않는다. 요청당 원본 ID 수, 중복 제거 뒤 ID 수, 반환 행 수, 누락 비율, query latency의 p95·p99, DB의 rows·buffers·sort 관련 실행 계획을 함께 본다. 특정 요청이 큰 배열을 보내는 문제는 평균 요청 시간만으로 놓치기 쉽다. 운영에서 먼저 조정할 대상은 API 최대 개수와 호출 패턴이며, `EXPLAIN ANALYZE`로 실제 행 수와 정렬·join 비용을 확인한 뒤에만 쿼리나 인덱스를 바꾼다.

장애 영향도 나눠야 한다. DB가 느려지면 동기 batch-get은 호출한 화면이나 상위 Agent 응답을 함께 늦춘다. timeout을 짧게 둔다고 결과 정합성이 자동으로 보장되지는 않으며, 재시도는 읽기 요청이라도 DB 부하를 겹칠 수 있다. 상위 서비스는 timeout·재시도 횟수·부분 결과 허용 여부를 API 계약과 맞추고, 요청 ID 원문 전체를 로그에 남기기보다 개수·중복률·누락 수 같은 안전한 요약 지표를 남긴다.

검증에서는 DB가 입력과 다른 순서로 상품을 반환하는 경우를 반드시 만든다. `[41, 12, 99]`를 넣고 테이블의 삽입 순서나 인덱스를 믿지 않아도 응답이 `41, 12` 순서인지 확인한다. 누락된 `99`의 정책도 응답에서 명확해야 한다. 결과가 어긋났을 때 첫 확인 지점은 `ORDER BY requested.position` 유무와 Service가 중복 제거 전·후 어느 목록을 비교했는지다.

## 6. 흔히 발생하는 문제

첫 번째 문제는 `WITH ORDINALITY`만 넣고 `ORDER BY position`을 생략하는 것이다. 현상은 개발 DB에서는 입력 순서처럼 보이는데 배포 뒤 결과가 섞이는 것이다. 근본 원인은 테이블 함수가 position 열을 제공해도 SQL 출력 순서를 자동으로 약속하지 않기 때문이다. 정렬 테스트와 실행 SQL을 확인해 발견하고, 최종 조회에 `ORDER BY requested.position`을 명시한다. 부작용은 정렬 대상 행이 늘수록 비용도 늘어난다는 점이므로 큰 목록은 API 경계에서 제한한다.

두 번째 문제는 일괄 조회 API를 사실상 무제한 목록 API로 여는 것이다. 현상은 일부 client 요청에서만 query time과 응답 직렬화 시간이 튀거나 DB가 많은 행을 처리하는 것이다. 원인은 array 전개·join·정렬 비용과 응답 크기가 요청 ID 수에 비례해 커지는 데 있다. 요청당 ID 수 분포와 실제 rows를 관측하고, 최대 크기·페이지·비동기 export처럼 목적에 맞는 경계를 둔다. 너무 작은 상한은 client의 왕복 호출을 늘리고 부분 실패 처리를 복잡하게 한다.

세 번째 문제는 중복 제거를 성능 최적화로만 보고 도메인 의미를 지우는 것이다. 현상은 같은 상품을 두 줄로 요청한 장바구니나 우선순위 목록에서 응답 항목 수가 줄어드는 것이다. 원인은 `LinkedHashSet` 변환이 중복을 제거한다는 계약을 코드가 묵시적으로 정했기 때문이다. 반복 ID가 실제 수량이나 순위를 뜻하는 요청을 테스트해 발견하고, 그런 API는 원본 `List`를 ordinality와 함께 전달한다. 중복을 보존하면 DB join과 응답 크기도 함께 늘어난다는 비용을 받아들여야 한다.

네 번째 문제는 누락 행을 `filter`로 조용히 버리는 것이다. 현상은 클라이언트가 보낸 ID와 응답 ID가 달라도 원인을 알 수 없는 부분 성공이다. 원인은 판매 상태·권한·삭제 조건으로 행이 빠진 사실을 표현하지 않았기 때문이다. found ID와 requested ID를 비교해 누락 비율을 기록하고, 도메인에 맞게 `missingIds`, 오류 코드, 전체 실패 중 하나를 명시한다. 누락 사유를 너무 상세히 알려 주면 비공개 상품이나 권한 정보를 노출할 수 있으므로 외부 응답 범위는 보안 정책과 맞춘다.

## 7. 기술 선택의 Trade-off

PostgreSQL `WITH ORDINALITY` 방식은 입력 위치를 DB의 정렬 기준으로 만들므로 결과 조립 코드를 줄이고, 중복을 보존해야 하는 계약에도 자연스럽다. 대신 PostgreSQL 의존성이 생기고, array 전개와 위치 정렬 비용을 DB가 맡는다. SQL에서 순서를 보장해야 하며 DB 왕복 뒤 바로 결과를 반환하는 단순 batch 조회에 적합하다.

Java `Map` 재조립 방식은 DB 방언 의존을 낮추고, DB 쿼리는 순서를 신경 쓰지 않고 필요한 행을 반환하게 할 수 있다. 그러나 Service가 map·ordered ID 목록·누락 계산을 유지하고, 큰 결과에서는 애플리케이션 메모리와 CPU를 더 사용한다. 이미 Service가 여러 source의 상품 정보를 합쳐야 하거나 DB 이식성이 중요한 경우에 적합하다. 반대로 결과가 DB 한 곳에서 끝나고 입력 순서가 핵심인 PostgreSQL 서비스라면 ordinality 쿼리가 더 직접적일 수 있다.

`ORDER BY CASE id WHEN ...`로 입력 순서를 직접 적는 대안도 있다. 작은 고정 목록에는 읽을 수 있지만, 요청 값마다 SQL 표현과 parameter가 커지고 동적으로 조립하기 쉬워 관리가 어렵다. 순서가 필요 없으면 가장 좋은 선택은 정렬 자체를 하지 않는 것이다. 반환 목록을 가격·이름·점수 같은 도메인 정렬로 정의할 수 있다면, 입력 순서를 보존하는 비용과 복잡도를 지불할 이유가 없다.

실무에서는 다음 다섯 단계로 결정한다.

1. 입력 순서·중복·누락이 외부 API 계약인지, 내부 구현 편의인지 먼저 정한다.
2. 요청당 최대 ID 수와 부분 성공 정책을 정해 DB 작업량과 응답 크기의 상한을 만든다.
3. PostgreSQL 의존을 허용하고 DB 순서가 필요한지, Java에서 여러 source를 합칠지에 따라 ordinality와 map 재조립을 고른다.
4. 선택한 계층에서만 순서 책임을 명시하고, `ORDER BY` 또는 ordered ID 목록을 테스트로 고정한다.
5. ID 수 분포·누락률·p95/p99·실행 계획을 관측한 뒤 API 제한, 쿼리, 캐시를 실제 병목에 맞게 조정한다.

### 참고한 공식 문서

- [PostgreSQL 18 Table Expressions](https://www.postgresql.org/docs/current/queries-table-expressions.html): `UNNEST ... WITH ORDINALITY`의 위치 열과 table function 사용법을 확인했다.
- [PostgreSQL 18 Sorting Rows](https://www.postgresql.org/docs/current/queries-order.html): `ORDER BY`가 없을 때 결과 행 순서가 지정되지 않는다는 규칙을 확인했다.
- [PostgreSQL 18 Indexes and ORDER BY](https://www.postgresql.org/docs/current/indexes-ordering.html): 정렬·인덱스·명시적 sort의 비용 판단 근거를 확인했다.
- [Oracle Java 21 LinkedHashSet](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/LinkedHashSet.html): 삽입 순서와 중복 제거의 동작을 확인했다.
- [Spring Framework JDBC Core](https://docs.spring.io/spring-framework/reference/data-access/jdbc/core.html): `JdbcTemplate`의 JDBC 자원 관리 책임을 확인했다.
