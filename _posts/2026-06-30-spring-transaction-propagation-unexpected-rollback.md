---
title: "Spring 트랜잭션 전파를 잘못 섞으면 UnexpectedRollbackException이 나는 이유"
date: 2026-06-30 09:00:00 +0900
tags: [Spring, Transaction, Backend]
excerpt: "Spring의 트랜잭션 전파는 메서드 경계의 옵션처럼 보이지만, REQUIRED와 REQUIRES_NEW를 어떻게 섞느냐에 따라 롤백 전파와 커넥션 사용 방식이 크게 달라집니다."
---

## 문제 상황

주문 저장은 실패했지만 감사 로그는 남기고 싶어서 내부 메서드 하나에 `@Transactional(propagation = REQUIRES_NEW)`를 붙였더니, 어떤 요청에서는 예상치 못한 `UnexpectedRollbackException`이 발생하고 어떤 요청에서는 커넥션 풀이 갑자기 부족해지는 일이 생길 수 있습니다. 코드만 보면 "안쪽 메서드 트랜잭션만 따로 돌겠지"라고 생각하기 쉽지만, 실제 동작은 그렇게 단순하지 않습니다.

특히 Spring을 처음 실무에 깊게 쓰기 시작하면 `REQUIRED`, `REQUIRES_NEW`, `NESTED`를 이름만 보고 이해하는 경우가 많습니다. 하지만 장애는 이름이 아니라 물리 트랜잭션과 논리 트랜잭션이 어떻게 매핑되는지에서 생깁니다. 공식 문서도 전파를 설명할 때 이 둘의 차이를 먼저 보라고 안내합니다.

중요한 질문은 "이 메서드가 트랜잭션을 새로 만드는가"만이 아닙니다. 더 중요한 것은 "안쪽 메서드의 rollback 표시가 바깥 commit에 어떤 영향을 주는가", 그리고 "새 트랜잭션을 만들 때 DB 커넥션을 하나 더 필요로 하는가"입니다.

## 핵심 개념

Spring 공식 문서에 따르면 `PROPAGATION_REQUIRED`는 기존 외부 트랜잭션이 있으면 그 물리 트랜잭션에 참여합니다. 메서드마다 논리 트랜잭션 경계는 생기지만, 실제 DB 입장에서는 같은 물리 트랜잭션 하나를 공유합니다. 그래서 안쪽 메서드가 rollback-only를 표시하면 바깥 메서드도 결국 commit할 수 없습니다.

이때 바깥 호출자는 스스로 롤백을 결정한 적이 없는데도 commit 시점에 `UnexpectedRollbackException`을 받을 수 있습니다. Spring 문서는 이것이 호출자가 "정상 commit된 줄 착각하지 않도록" 일부러 명확한 예외를 던지는 동작이라고 설명합니다. 즉, 이 예외는 이상한 버그라기보다 REQUIRED 전파의 정상적인 신호입니다.

반면 `PROPAGATION_REQUIRES_NEW`는 항상 독립적인 물리 트랜잭션을 만듭니다. 안쪽 트랜잭션은 바깥 롤백 상태와 별개로 commit 또는 rollback될 수 있고, 락도 끝나면 바로 해제됩니다. 대신 공식 문서는 이 방식이 새 데이터베이스 커넥션을 추가로 필요로 하므로 커넥션 풀 고갈이나 데드락을 일으킬 수 있다고 경고합니다. 동시 요청 수보다 최소 1개 이상 여유 있는 풀 크기를 고려하라는 문구도 직접 나옵니다.

`PROPAGATION_NESTED`는 또 다릅니다. 문서 기준으로 하나의 물리 트랜잭션 안에서 savepoint를 사용해 부분 롤백을 허용합니다. 즉 완전히 새 트랜잭션이 아니라, 같은 트랜잭션 안에서 "여기까지만 되돌리기"가 가능한 구조입니다.

## 코드로 보기

문제가 잘 드러나는 예시는 아래와 같습니다.

```java
@Transactional
public void placeOrder(OrderCommand command) {
    orderService.save(command);
    auditService.writeAudit(command);
}

@Transactional
public void save(OrderCommand command) {
    orderRepository.save(command.toEntity());
    throw new IllegalStateException("payment validation failed");
}
```

위 구조에서 `save()`가 같은 `REQUIRED` 전파로 참여했다면, 내부에서 rollback-only가 설정되고 바깥 `placeOrder()`가 나중에 commit하려는 순간 `UnexpectedRollbackException`을 받을 수 있습니다. 바깥 메서드가 예외를 잡아도 물리 트랜잭션은 이미 되돌릴 수밖에 없는 상태일 수 있습니다.

감사 로그를 꼭 남겨야 해서 별도 커밋이 필요하다면 아래처럼 분리할 수 있습니다.

```java
@Transactional
public void placeOrder(OrderCommand command) {
    try {
        orderService.save(command);
    } catch (Exception ex) {
        auditService.writeFailureAudit(command, ex.getMessage());
        throw ex;
    }
}

@Transactional(propagation = Propagation.REQUIRES_NEW)
public void writeFailureAudit(OrderCommand command, String reason) {
    auditRepository.save(AuditLog.failed(command.orderId(), reason));
}
```

다만 이 구조는 "감사 로그는 남기되 주문은 실패"라는 의도를 명확히 할 때만 써야 합니다. 무심코 남용하면 한 요청 안에서 커넥션을 둘 이상 쓰는 흐름이 늘어납니다.

## 자주 하는 실수

첫 번째 실수는 `REQUIRED`를 "메서드마다 독립 트랜잭션"으로 오해하는 것입니다. 논리 경계는 여러 개여도 물리 트랜잭션은 하나일 수 있습니다.

두 번째 실수는 `UnexpectedRollbackException`을 없애려고 무조건 `REQUIRES_NEW`로 바꾸는 것입니다. 예외는 사라질 수 있어도, 대신 비즈니스 정합성이 바뀌거나 커넥션 사용량이 늘어날 수 있습니다.

세 번째 실수는 `REQUIRES_NEW`를 감사 로그, 알림, 이력 저장 곳곳에 붙여 놓고 커넥션 풀 크기를 그대로 두는 것입니다. Spring 공식 문서가 경고하듯 바깥 트랜잭션 리소스는 유지된 채 안쪽에서 새 커넥션을 잡기 때문에, 동시성이 올라가면 예상보다 빨리 풀 고갈이 납니다.

## 언제 쓰면 좋은가

`REQUIRED`는 서비스 한 요청 안에서 성공과 실패가 함께 묶여야 하는 기본 흐름에 가장 잘 맞습니다. 주문과 재고 차감처럼 둘 중 하나만 남으면 안 되는 작업은 기본적으로 여기서 출발하는 편이 좋습니다.

`REQUIRES_NEW`는 바깥 작업이 실패해도 별도로 남겨야 하는 감사 로그, 실패 이력, 보상 트리거처럼 "독립 커밋 의도"가 분명할 때만 쓰는 편이 좋습니다. 단지 예외를 피하려고 선택하면 나중에 더 큰 문제를 만듭니다.

`NESTED`는 JDBC savepoint 기반 부분 롤백이 필요한 상황에서 고려할 수 있지만, 모든 트랜잭션 매니저에서 같은 방식으로 동작하는 것은 아니므로 사용 전 기반 기술을 확인해야 합니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "안쪽 작업이 실패해도 바깥 작업 전체를 성공시키고 싶은가, 아니면 실패 사실만 별도로 남기고 싶은가." 이 질문에 답이 분명할 때만 `REQUIRES_NEW`를 쓰는 편이 맞습니다.

## 운영에서 볼 것

- `UnexpectedRollbackException` 발생 위치
- `REQUIRES_NEW` 사용 메서드 수와 호출 빈도
- 요청 동시성 증가 시 커넥션 풀 active/pending 수
- 감사 로그는 남았는데 본 작업은 실패한 케이스 수
- read-only, isolation mismatch 설정 여부

트랜잭션 관련 장애를 볼 때는 아래를 함께 점검하면 좋습니다.

- 안쪽 메서드가 rollback-only를 남겼는가
- 바깥 호출자가 예외를 삼키고 commit을 시도했는가
- 새 트랜잭션 때문에 추가 커넥션이 필요한 구조인가

이 순서로 보면 "왜 갑자기 UnexpectedRollbackException이 났는가"를 코드 흐름과 리소스 관점에서 같이 설명할 수 있습니다.

## 정리

Spring 트랜잭션 전파는 단순한 어노테이션 옵션이 아니라, 물리 트랜잭션과 커넥션 사용 방식을 바꾸는 운영 설정입니다. `REQUIRED`는 rollback-only 전파 때문에 `UnexpectedRollbackException`을 만들 수 있고, `REQUIRES_NEW`는 독립 커밋을 가능하게 하지만 커넥션 풀 부담을 늘립니다. 예외를 없애는 방향보다, 어떤 작업을 정말 독립 커밋해야 하는지부터 명확히 정하는 편이 안전합니다.

## 참고한 공식 문서

- Spring Framework Transaction Propagation: https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/tx-propagation.html
