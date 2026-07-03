---
title: "같은 클래스에서 @Transactional을 다시 호출하면 트랜잭션이 조용히 빠지는 이유"
date: 2026-07-03 08:50:00 +0900
tags: [Spring, Transaction, Backend]
excerpt: "Spring의 @Transactional은 기본적으로 프록시를 통해 들어오는 외부 호출만 가로채므로, 같은 클래스 안에서 자기 메서드를 다시 호출하면 기대한 트랜잭션 경계가 실제로는 적용되지 않을 수 있습니다."
---

## 문제 상황

주문 정산 배치를 만들다 보면 "성공한 건 바로 확정하고, 실패한 건 별도 트랜잭션으로 실패 이력만 남기자" 같은 요구가 자주 나옵니다. 그래서 같은 서비스 클래스 안에 `confirm()`과 `recordFailure()`를 두고, 뒤쪽 메서드에 `@Transactional(propagation = REQUIRES_NEW)`를 붙이는 식으로 구현하기 쉽습니다.

문제는 코드가 깔끔해 보여도 실제 동작은 의도와 다를 수 있다는 점입니다. 배치가 도는 동안 실패 이력은 남았다고 생각했는데, 장애가 나고 나서 확인해 보면 별도 커밋이 전혀 일어나지 않았거나, 반대로 `readOnly = true`를 믿고 넣었던 조회 메서드가 같은 클래스 내부 호출 때문에 평범한 메서드처럼 실행된 경우가 있습니다.

이런 문제는 예외가 크게 터지지 않아서 더 위험합니다. "트랜잭션이 깨졌다"는 신호보다 "왜 이 메서드만 기대한 경계가 안 먹지?"라는 식의 조용한 오동작으로 나타나기 때문입니다. 실무에서는 어노테이션이 붙어 있는가보다, 그 호출이 프록시를 통과하는가를 먼저 봐야 합니다.

## 핵심 개념

Spring 공식 문서는 `@Transactional`의 기본 동작이 `proxy mode`라고 설명합니다. 이 모드에서는 프록시를 통해 들어오는 외부 메서드 호출만 가로채며, 같은 객체 내부에서 자기 메서드를 다시 호출하는 self-invocation은 실제 런타임 트랜잭션으로 이어지지 않습니다. 즉, 메서드에 `@Transactional`이 붙어 있어도 `this.innerMethod()`처럼 호출하면 기대한 advice가 실행되지 않을 수 있습니다.

Spring AOP 프록시 문서도 같은 점을 더 직접적으로 설명합니다. 타깃 객체에 호출이 도달한 뒤 그 객체가 자기 자신의 다른 메서드를 호출하면, 그 호출은 프록시가 아니라 `this` 참조를 타므로 advice를 우회합니다. 트랜잭션, 로깅, 리트라이처럼 프록시 기반으로 붙는 부가 기능이 여기서 함께 빠집니다.

그래서 중요한 질문은 "메서드에 `@Transactional`을 붙였는가"가 아니라 "그 메서드가 프록시를 통해 호출되는가"입니다. 이 차이를 놓치면 `REQUIRES_NEW`, `readOnly`, 별도 isolation 같은 설정이 코드상으로만 존재하고 실제로는 적용되지 않는 상황이 생깁니다.

## 코드로 보기

아래 코드는 처음 보면 실패 이력을 별도 트랜잭션으로 남기는 것처럼 보입니다.

```java
@Service
public class SettlementService {

    @Transactional
    public void settle(SettlementCommand command) {
        try {
            settleInternal(command);
        } catch (Exception ex) {
            recordFailure(command, ex.getMessage());
            throw ex;
        }
    }

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordFailure(SettlementCommand command, String reason) {
        failureLogRepository.save(FailureLog.of(command.id(), reason));
    }

    private void settleInternal(SettlementCommand command) {
        // 외부 정산 API 호출
        throw new IllegalStateException("timeout");
    }
}
```

하지만 `settle()`이 `recordFailure()`를 같은 객체 내부에서 직접 호출하면, `recordFailure()`는 프록시를 통과하지 않습니다. 따라서 `REQUIRES_NEW`가 기대대로 새 물리 트랜잭션을 만들지 않을 수 있습니다.

실무에서는 아래처럼 트랜잭션 경계를 다른 빈으로 분리하는 편이 가장 안전합니다.

```java
@Service
public class SettlementFailureService {

    @Transactional(propagation = Propagation.REQUIRES_NEW)
    public void recordFailure(SettlementCommand command, String reason) {
        failureLogRepository.save(FailureLog.of(command.id(), reason));
    }
}

@Service
public class SettlementService {

    private final SettlementFailureService failureService;

    @Transactional
    public void settle(SettlementCommand command) {
        try {
            settleInternal(command);
        } catch (Exception ex) {
            failureService.recordFailure(command, ex.getMessage());
            throw ex;
        }
    }
}
```

Spring AOP 문서는 self-invocation을 피하는 리팩터링을 가장 덜 침습적인 접근으로 안내합니다. self injection이나 `AopContext.currentProxy()` 같은 우회책도 가능하지만, 코드가 프레임워크 세부 동작에 더 강하게 묶입니다.

## 자주 하는 실수

첫 번째 실수는 메서드에 어노테이션만 붙으면 언제나 동작한다고 믿는 것입니다. 프록시 기반 기능은 호출 경로가 맞아야 적용됩니다.

두 번째 실수는 self-invocation 문제를 해결하려고 같은 클래스를 억지로 자기 자신에게 주입하는 것입니다. 가능은 하지만 읽기 어려워지고 테스트가 불편해집니다. 팀원이 봤을 때 "왜 자기 자신을 주입하지?"라는 설명 비용도 커집니다.

세 번째 실수는 프록시 경계 문제를 숨긴 채 `REQUIRES_NEW`나 `readOnly` 값을 계속 바꾸는 것입니다. 원인은 호출 구조인데 설정 값만 바꾸면, 운 좋게 지나가는 테스트 몇 개를 제외하면 운영에서 다시 드러납니다.

네 번째 실수는 생성자나 초기화 단계에서 트랜잭션을 기대하는 것입니다. Spring 문서도 프록시가 완전히 초기화되기 전 시점에는 트랜잭션 동작에 의존하지 말라고 안내합니다.

## 언제 쓰면 좋은가

별도 트랜잭션이 정말 필요한 경우는 분명히 있습니다. 실패 감사 로그, 외부 정산 실패 이력, 보상 작업 예약처럼 "본 작업은 실패해도 이 기록은 독립 커밋해야 한다"는 의도가 명확할 때입니다.

이때 판단 기준은 단순합니다. 내부 메서드에 다른 트랜잭션 의미를 주고 싶다면, 먼저 그 경계를 다른 빈으로 분리할 수 있는지 보십시오. 분리 가능하면 프록시 기반 동작이 가장 읽기 쉽고 유지보수도 쉽습니다.

반대로 도메인 모델이 아주 촘촘하게 얽혀 있어서 메서드 분리가 더 큰 복잡성을 만들고, 프록시 기반 제약을 반복해서 우회해야 한다면 AspectJ 모드 같은 대안을 검토할 수 있습니다. 다만 이 경우는 설정과 운영 복잡도가 커지므로 "같은 클래스 내부 호출이 많다"는 이유만으로 바로 선택할 일은 아닙니다.

실무에서 바로 쓸 판단 규칙을 하나만 고르면 이렇습니다. `@Transactional` 의미가 다른 메서드가 같은 클래스에 둘 이상 섞이기 시작하면, 그 시점부터는 어노테이션이 아니라 빈 경계를 먼저 나누는 편이 안전합니다.

## 운영에서 볼 것

- 별도 커밋을 기대한 로그나 이력 테이블이 실제로 남는지
- 한 요청 안에서 독립 트랜잭션이 생겨야 하는 구간이 통합 테스트에서 재현되는지
- `REQUIRES_NEW`를 붙였는데도 커밋/롤백 시점이 바깥 메서드와 함께 움직이는지
- self-invocation이 많은 서비스 클래스가 점점 비대해지고 있는지

장애 분석 때는 "어노테이션이 왜 안 먹었는가"보다 "이 호출이 프록시 바깥에서 일어났는가"를 먼저 좁히는 편이 빠릅니다. 트랜잭션 문제를 설정 실수로만 보면 오래 헤매지만, 호출 경계 문제로 보면 원인이 훨씬 빨리 드러납니다.

## 정리

Spring의 `@Transactional`은 기본적으로 프록시를 통해 들어오는 외부 호출에 붙습니다. 같은 클래스 내부에서 자기 메서드를 다시 호출하면 그 경계가 조용히 사라질 수 있고, `REQUIRES_NEW`나 `readOnly` 같은 의도도 함께 무효가 될 수 있습니다. 내부 메서드에 다른 트랜잭션 의미가 필요해지는 순간, 가장 먼저 검토할 해법은 설정 변경보다 빈 분리입니다.

## 참고한 공식 문서

- [Spring Framework Reference: Using `@Transactional`](https://docs.spring.io/spring-framework/reference/data-access/transaction/declarative/annotations.html)
- [Spring Framework Reference: Proxying Mechanisms](https://docs.spring.io/spring-framework/reference/core/aop/proxying.html)
