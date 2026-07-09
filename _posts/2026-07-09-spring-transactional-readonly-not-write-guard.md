---
title: "@Transactional(readOnly=true)를 쓰기 방어막으로 믿으면 JPA 변경이 조용히 새는 이유"
date: 2026-07-09 08:57:00 +0900
tags: [Spring, JPA, Backend]
excerpt: "Spring의 @Transactional(readOnly=true)는 읽기 전용 트랜잭션 의도를 표현하는 설정이지만, 서비스 코드의 쓰기 버그를 완전히 막는 보안 장치로 보면 위험합니다. 쓰기 메서드 경계, 테스트, DB 권한을 함께 설계해야 합니다."
---

## 문제 상황

조회 API 응답을 만들다가 마지막 조회 시간을 남기고 싶어서 entity 필드를 살짝 바꾸는 코드가 들어갔다고 하자. 서비스 클래스에는 습관처럼 `@Transactional(readOnly = true)`가 붙어 있다. 개발자는 "읽기 전용 트랜잭션이니까 저장은 안 되겠지"라고 생각한다.

그런데 운영 DB에는 일부 값이 바뀌어 있다. 반대로 어떤 환경에서는 값이 안 바뀐다. 로컬, 테스트, 운영에서 동작이 달라 보이니 원인 찾기가 어렵다. 문제는 `readOnly=true`를 "절대 쓰기 금지"로 이해한 데서 시작한다.

Spring의 `@Transactional(readOnly = true)`는 트랜잭션 의미를 표현하는 metadata다. 트랜잭션 매니저와 persistence provider가 이를 참고해 최적화하거나 read-only 힌트로 사용할 수 있지만, 애플리케이션의 모든 쓰기 경로를 자동으로 차단하는 방어막이라고 보기는 어렵다. 특히 JPA dirty checking, 명시적 repository save, native query, DB 권한이 섞이면 기대와 실제가 달라질 수 있다.

## 핵심 개념

Spring 문서에서 `@Transactional`은 method, class, interface에 트랜잭션 의미를 부여하는 annotation이다. 기본 설정은 propagation `REQUIRED`, isolation `DEFAULT`, read-write 트랜잭션, runtime exception과 error에 rollback이다. `readOnly` 속성은 read-write와 read-only를 구분하는 값이며, `REQUIRED`나 `REQUIRES_NEW` 같은 실제 트랜잭션 범위에 적용된다.

중요한 점은 설정 우선순위다. 클래스에 `@Transactional(readOnly = true)`를 붙여도 메서드에 `@Transactional(readOnly = false)`를 붙이면 메서드 설정이 더 구체적이므로 우선한다. 그래서 조회 중심 서비스의 기본값을 read-only로 두고, 쓰기 메서드만 read-write로 열어두는 패턴은 실무에서 자주 쓴다.

하지만 이 패턴은 코드 구조를 명확히 하는 데 의미가 있지, 쓰기 버그를 100% 차단한다는 뜻은 아니다. JPA에서는 영속성 컨텍스트가 entity 변경을 감지하고 flush 시점에 SQL을 보낼 수 있다. 구현체와 설정에 따라 read-only 트랜잭션에서 flush mode가 조정될 수 있지만, 팀은 "readOnly면 어떤 코드도 DB를 못 바꾼다"라고 단정하면 안 된다.

## 코드로 보기

다음 코드는 보기에는 조회 API지만 entity를 변경한다.

```java
@Service
@Transactional(readOnly = true)
public class ProductQueryService {

    private final ProductRepository productRepository;

    public ProductDetail getProduct(long productId) {
        Product product = productRepository.findById(productId)
            .orElseThrow(ProductNotFoundException::new);

        product.markViewedAt(Instant.now());

        return ProductDetail.from(product);
    }
}
```

`markViewedAt`이 단순한 메모리 변경처럼 보여도, entity가 영속 상태라면 flush 시점에 update 후보가 될 수 있다. 개발자는 repository `save`를 호출하지 않았으니 안전하다고 생각하지만, JPA의 dirty checking은 명시적 `save`만 쓰기 경로로 보지 않는다.

더 안전한 코드는 조회 모델과 쓰기 모델의 경계를 나눈다.

```java
@Service
@Transactional(readOnly = true)
public class ProductQueryService {

    public ProductDetail getProduct(long productId) {
        return productRepository.findDetail(productId)
            .orElseThrow(ProductNotFoundException::new);
    }
}

@Service
public class ProductViewCommandService {

    @Transactional
    public void recordView(long productId, Instant viewedAt) {
        productRepository.updateLastViewedAt(productId, viewedAt);
    }
}
```

조회 메서드는 DTO projection이나 read model을 반환하고, 쓰기는 별도 command service에서 명시적으로 처리한다. 이렇게 나누면 `readOnly=true`에 기대지 않아도 코드 리뷰에서 "조회 흐름에서 entity를 바꾸고 있다"는 신호가 더 잘 보인다.

## 자주 하는 실수

첫 번째 실수는 class level read-only를 붙여두고 쓰기 메서드 override를 빼먹는 것이다. 이 경우 save를 호출했는데도 flush가 기대와 다르게 동작하거나, DB나 provider 설정에 따라 결과가 달라져 디버깅이 어려워진다. 쓰기 메서드에는 `@Transactional(readOnly = false)` 또는 단순 `@Transactional`을 명시해 의도를 드러내자.

두 번째 실수는 read-only 트랜잭션 안에서 audit 값을 바꾸는 것이다. `lastViewedAt`, `lastAccessedAt`, `downloadCount` 같은 값은 조회처럼 보이지만 실제로는 쓰기다. 조회 API 성능과 쓰기 부하를 함께 흔들 수 있으므로 이벤트나 비동기 집계로 분리할지 판단해야 한다.

세 번째 실수는 read-only를 보안 권한처럼 쓰는 것이다. 정말 쓰기를 막아야 하는 reporting service라면 DB 계정 자체에 `SELECT` 권한만 주는 편이 더 확실하다. 애플리케이션 annotation은 개발 의도를 표현하지만, 권한 경계를 대신하지 않는다.

## 언제 쓰면 좋은가

`@Transactional(readOnly = true)`는 조회 메서드의 의도를 드러내고, 트랜잭션 매니저나 ORM이 읽기 중심 동작을 선택할 수 있게 하는 데 좋다. 특히 조회 서비스가 많고 일부 메서드만 쓰기라면 class level에 read-only를 두고 command 메서드에서 override하는 방식이 읽기 쉽다.

반대로 "혹시 누가 entity를 바꿔도 저장되지 않게 하자"라는 목적이라면 부족하다. 이 목적에는 DTO projection, entity 노출 금지, service 분리, repository 메서드 네이밍, 테스트, DB 권한이 더 직접적이다.

판단 기준은 이렇게 잡는다. 읽기 메서드임을 표시하고 provider 최적화 여지를 주려면 read-only를 쓴다. 쓰기 금지를 강제하려면 코드 구조와 권한을 바꾼다. 조회 중 부수효과가 필요하면 그건 조회가 아니라 command인지 먼저 따진다.

## 운영에서 볼 것

운영에서는 읽기 API에서 update SQL이 나가는지 확인해야 한다. Hibernate SQL 로그를 항상 켤 필요는 없지만, 의심 구간에서는 datasource proxy, p6spy, APM span, slow query log로 endpoint와 SQL을 연결해 본다.

다음과 같은 로그가 보이면 조회 경계가 새고 있는 것이다.

```text
endpoint=GET /products/42 tx.readOnly=true sql="update product set last_viewed_at=? where id=?"
```

또한 DB 지표에서 조회 트래픽 증가와 함께 write IOPS, row lock, replication lag이 같이 오르는지 확인한다. 조회 API가 실제로 쓰기를 만들면 cache hit rate나 read latency만 봐서는 원인이 보이지 않는다.

테스트도 한 가지는 두는 편이 좋다. 핵심 조회 서비스에 대해 트랜잭션 전후 entity snapshot을 비교하거나, SQL capture로 update/delete/insert가 없음을 확인한다. 모든 조회에 과하게 적용할 필요는 없지만, 트래픽이 큰 조회와 정산, 권한, 재고처럼 쓰기 사고 비용이 큰 영역에는 효과가 있다.

코드 리뷰에서는 세 가지 질문을 반복하면 좋다. 첫째, 조회 서비스가 entity를 그대로 반환하거나 외부 계층에 넘기지 않는가. entity가 오래 살아남을수록 의도하지 않은 변경 지점이 늘어난다. 둘째, 조회 중 부수효과가 꼭 필요한가. 조회수, 마지막 접근 시각, 추천 점수 같은 값은 별도 이벤트로 비동기 처리해도 되는 경우가 많다. 셋째, 쓰기 메서드가 이름과 트랜잭션 설정으로 명확히 드러나는가. `getAndUpdate`, `findOrCreate` 같은 이름은 호출자가 읽기인지 쓰기인지 헷갈리게 만든다.

팀 규칙도 중요하다. 조회 서비스에는 DTO projection을 우선 사용하고, command service만 entity 변경 메서드를 호출하게 제한하면 실수 가능성이 줄어든다. 정적 분석이나 아키텍처 테스트로 `..query..` 패키지에서 `save`, `delete`, `@Modifying` repository 메서드를 호출하지 못하게 막는 것도 실무적으로 효과가 있다. 이런 장치는 `readOnly=true`보다 더 직접적으로 쓰기 경계를 지킨다.

읽기 전용 복제본을 사용하는 구조라면 더 엄격히 봐야 한다. read-only 트랜잭션이라고 믿고 조회 메서드를 replica datasource로 보내는데, 그 안에서 쓰기를 시도하면 환경에 따라 즉시 실패하거나 primary로 우회되는 잘못된 구성이 숨어 있을 수 있다. 조회 경로와 쓰기 경로가 datasource routing으로 나뉜 서비스에서는 `readOnly=true`가 라우팅 힌트로 쓰일 수 있으므로, 잘못 붙인 annotation 하나가 성능 문제나 정합성 문제로 이어진다.

그래서 운영 기준은 "저장되느냐"보다 "어느 경로로 어떤 SQL이 나가느냐"에 둬야 한다. 조회 API에서 update SQL이 보이면 실제 저장 성공 여부와 무관하게 경계 위반이다. 테스트 DB에서 우연히 저장되지 않았다고 넘어가면, 운영 provider 설정이나 트랜잭션 매니저 변경 뒤에 다시 나타날 수 있다. 조회 서비스는 부수효과가 없다는 약속을 코드와 관측 지표 양쪽에서 확인해야 한다.

## 정리

`@Transactional(readOnly = true)`는 읽기 의도를 표현하는 좋은 도구지만, 쓰기 버그를 완전히 막는 장치는 아니다.
JPA dirty checking 때문에 repository `save`가 없어도 변경 후보가 생길 수 있다.
조회와 쓰기 service를 나누고, DTO projection과 테스트로 경계를 확인하는 편이 안전하다.
정말 쓰기를 막아야 하는 시스템은 DB 계정 권한까지 read-only로 분리해야 한다.

## 참고한 공식 문서

- [Spring Framework - Using @Transactional](https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html)
