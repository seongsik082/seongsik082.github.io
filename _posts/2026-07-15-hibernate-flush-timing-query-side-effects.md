---
title: "Hibernate flush 시점이 조회 결과와 API 지연 시간을 바꾸는 이유"
date: 2026-07-15 08:52:00 +0900
tags: [Spring, JPA, Hibernate, Performance, Backend]
excerpt: "JPA의 변경은 영속성 컨텍스트에 먼저 쌓이고 flush 때 SQL로 동기화되므로 save 호출과 실제 데이터베이스 실행 시점이 다를 수 있습니다. AUTO flush의 조회 조건, saveAndFlush의 비용, bulk query와 영속성 컨텍스트 불일치를 기준으로 운영 판단을 정리합니다."
---

## 문제 상황

Spring Data JPA 코드에서 save를 호출했으니 INSERT가 끝났다고 생각하기 쉽습니다. 하지만 JPA의 영속성 컨텍스트는 변경을 바로 데이터베이스에 보내는 저장소가 아니라, 엔티티 상태를 추적하면서 나중에 SQL로 동기화하는 작업 공간입니다. 이 동기화가 flush입니다. 따라서 save 직후에 SQL 로그가 보이지 않거나, 서비스 메서드 중간의 조회가 예상보다 많은 UPDATE를 발생시키는 일이 모두 가능합니다.

## flush는 commit과 다르다

flush는 영속성 컨텍스트의 INSERT, UPDATE, DELETE 변경을 데이터베이스에 전달해 상태를 맞추는 작업입니다. commit은 트랜잭션의 결과를 확정하는 작업입니다. flush가 성공했어도 뒤의 비즈니스 로직에서 예외가 발생하면 트랜잭션 전체가 rollback될 수 있습니다. 반대로 flush 단계에서 not-null, unique, foreign key 같은 제약조건 오류가 먼저 드러날 수도 있습니다.

Hibernate의 기본 AUTO flush는 보통 다음 시점에 동작합니다.

- 트랜잭션 commit 직전
- 대기 중인 변경과 결과가 겹칠 수 있는 JPQL 또는 HQL 실행 직전
- EntityManager API로 native SQL을 실행하기 전

같은 트랜잭션에서 주문을 추가한 뒤 주문을 조회하면 먼저 INSERT가 실행될 수 있지만, 전혀 다른 테이블을 조회하는 JPQL에서는 flush가 생략될 수 있습니다. 실행 시점은 쿼리 종류, flush mode, API에 따라 달라지므로 SQL 로그로 확인해야 합니다.

간단한 서비스 코드는 다음과 같은 실행 흐름을 만들 수 있습니다.

    @Transactional
    public long createAndCount(String userId) {
        orderRepository.save(new Order(userId));
        return orderRepository.countByUserId(userId);
    }

위 코드에서 save가 즉시 INSERT를 보장한다고 해석하면 안 됩니다. countByUserId가 주문 테이블을 대상으로 하면 AUTO flush가 먼저 실행된 뒤 INSERT와 SELECT가 수행될 수 있습니다.

## native query와 saveAndFlush의 차이

Spring Data JPA의 save는 엔티티를 저장 대상으로 등록하는 작업이고, JpaRepository의 saveAndFlush는 저장한 뒤 즉시 flush합니다. “다음 단계의 SQL이 반드시 현재 변경을 봐야 한다”는 명확한 이유가 있을 때 saveAndFlush를 사용할 수 있지만, 메서드마다 습관처럼 붙이면 비용이 커집니다.

    @Transactional
    public void importOrders(List<Order> orders) {
        for (Order order : orders) {
            orderRepository.saveAndFlush(order);
        }
    }

위 코드는 행마다 dirty checking과 SQL 실행을 유발해 대량 처리의 round trip과 lock 유지 시간을 키울 수 있습니다. 일정한 batch 크기마다 flush하고 clear하는 전략을 검토합니다.

    for (int i = 0; i < orders.size(); i++) {
        entityManager.persist(orders.get(i));
        if ((i + 1) % 100 == 0) {
            entityManager.flush();
            entityManager.clear();
        }
    }

반대로 native SQL은 사용하는 API가 중요합니다. Hibernate 문서에 따르면 EntityManager를 통한 native query는 기본 AUTO 환경에서 flush가 발생할 수 있지만, Hibernate Session API로 실행하는 native query는 자동 flush가 다르게 동작할 수 있고 필요한 경우 동기화 대상을 명시해야 합니다. 따라서 “native query를 호출하면 항상 flush된다” 또는 “절대 flush되지 않는다”라고 애플리케이션 전체의 규칙으로 일반화하면 안 됩니다.

## 자주 생기는 불일치와 성능 문제

flush 직후 다른 트랜잭션이 데이터를 보는지는 격리 수준과 commit에 달려 있습니다. 또한 FlushModeType.COMMIT은 dirty checking과 SQL을 줄일 수 있지만 중간 JPQL이 최신 변경을 보지 못할 수 있어, 조회의 기준을 테스트로 고정해야 합니다. bulk update나 delete는 1차 캐시를 자동 갱신하지 않으므로 작업 전 flush, 작업 후 clear 또는 별도 트랜잭션을 검토합니다. 제약조건 오류의 실제 위치를 찾으려면 SQL 로그와 trace에서 엔티티 등록·flush·commit을 구분합니다.

## 언제 명시적으로 flush할 것인가

명시적 flush는 다음처럼 이유를 설명할 수 있을 때 사용합니다.

- 같은 트랜잭션의 native query가 방금 변경한 데이터를 반드시 읽어야 할 때
- 데이터베이스 제약조건 오류를 특정 서비스 단계에서 조기에 확인해야 할 때
- 대량 처리에서 메모리와 dirty checking 대상을 batch 단위로 줄여야 할 때
- bulk query 전 기존 변경을 DB에 반영하고 영속성 컨텍스트를 정리해야 할 때

반대로 다음과 같은 상황에서는 saveAndFlush를 기본값으로 두지 않는 편이 낫습니다.

- 단순히 save 직후 SQL 로그가 안 보여 불안한 경우
- 반복문에서 매 행마다 flush해야 한다고 생각하는 경우
- commit 전에 다른 트랜잭션이 볼 것이라고 기대하는 경우
- AUTO flush의 동작을 측정하지 않고 COMMIT으로 변경하는 경우

운영에서는 flush 호출 횟수와 flush에 걸린 시간, 트랜잭션 지속 시간, SQL round trip 수, batch 크기, DB lock wait를 함께 확인합니다. API p95가 늘었는데 SQL 실행 횟수는 비슷하다면 flush 시점의 lock 대기나 제약조건 검사 비용을 의심할 수 있고, SQL 수가 폭증했다면 saveAndFlush 남용이나 batch 설정 변경을 먼저 봅니다. Hibernate statistics를 켤 때는 전체 트래픽에 무리한 비용을 주지 않도록 환경과 수집 기간을 제한해야 합니다.

정리하면 다음과 같습니다.

- save, flush, commit은 서로 다른 단계이며 SQL 실행 시점과 데이터 확정 시점을 구분해야 합니다.
- AUTO flush는 관련 JPQL/HQL, commit, native query API에 따라 일어날 수 있습니다.
- saveAndFlush는 정확한 필요가 있을 때만 쓰고, 대량 처리는 batch flush와 clear를 기준으로 설계합니다.
- bulk query와 FlushModeType.COMMIT은 영속성 컨텍스트의 최신성·성능·정합성 사이의 trade-off를 테스트로 확인해야 합니다.

## 참고한 공식 문서

- [Hibernate ORM User Guide - Flushing](https://docs.hibernate.org/orm/current/userguide/html_single/Hibernate_User_Guide.html#flushing)
- [Spring Data JPA JpaRepository API - flush and saveAndFlush](https://docs.spring.io/spring-data/jpa/reference/api/java/org/springframework/data/jpa/repository/JpaRepository.html)
