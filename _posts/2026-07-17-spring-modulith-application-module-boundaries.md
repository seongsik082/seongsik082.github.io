---
title: "패키지만 나눈 모놀리스가 다시 얽히는 이유: Spring Modulith로 경계 검증하기"
date: 2026-07-17 08:51:00 +0900
tags: [Architecture, Spring, Modular Monolith, Backend]
excerpt: "모놀리스의 패키지를 order와 inventory로 나누는 것만으로는 모듈 경계가 보장되지 않습니다. Spring Modulith의 ApplicationModules.verify가 순환 의존성, 내부 패키지 접근, 허용되지 않은 모듈 참조를 어떻게 잡는지와 적용 시점을 정리합니다."
---

## 문제 상황

처음에는 하나의 Spring 애플리케이션 안에서 order, inventory, payment 패키지를 나누는 것만으로 구조가 좋아진 것처럼 보입니다. 시간이 지나면 order 서비스가 inventory의 내부 repository를 직접 호출하고, inventory가 다시 order의 entity를 참조합니다. 컴파일은 성공하고 테스트도 통과하지만, 어느 모듈을 바꾸려면 여러 패키지를 함께 수정해야 합니다.

이런 구조는 마이크로서비스로 분리하기 전 단계에서 특히 위험합니다. 아직 하나의 프로세스와 데이터베이스를 사용하므로 모든 코드가 모든 코드에 접근하기 쉽고, 팀은 “나중에 정리하자”는 이유로 임시 참조를 추가합니다. 배포 단위는 하나인데 변경 영향 범위는 계속 넓어지는 상태입니다.

모듈러 모놀리스의 핵심은 폴더 이름이 아니라 다른 모듈이 접근할 수 있는 API와 의존 방향을 명시하는 것입니다. 내부 구현을 숨기고, 허용된 의존만 유지하며, 이 규칙을 코드 리뷰가 아니라 자동 검증으로 고정해야 합니다.

## Spring Modulith가 검증하는 경계

Spring Modulith는 Spring Boot 애플리케이션의 논리적 모듈을 찾아 구조를 검증하는 도구입니다. ApplicationModules.of(Application.class).verify()를 호출하면 다음과 같은 규칙을 검사합니다.

- 모듈 사이에 순환 의존성이 없어야 합니다.
- 다른 모듈의 내부 패키지를 직접 참조하지 않고 API 패키지를 통해 접근해야 합니다.
- allowedDependencies로 선언한 허용 모듈 외의 참조를 만들지 않아야 합니다.

예를 들어 다음처럼 공개 API와 내부 구현을 나눌 수 있습니다.

    com.example.order
    ├── OrderFacade.java
    └── internal
        ├── OrderEntity.java
        └── OrderRepository.java

inventory 모듈은 order의 internal 패키지를 직접 import하지 않고 OrderFacade 같은 공개 진입점을 사용합니다. 중요한 것은 공개 클래스의 이름이 아니라, 어떤 타입을 외부 계약으로 허용할지 팀이 결정하고 그 결정을 구조 검사에 반영하는 것입니다.

검증 코드는 보통 아키텍처 테스트로 실행합니다.

    @Test
    void applicationModulesFollowTheRules() {
        ApplicationModules.of(Application.class).verify();
    }

이 테스트가 실패하면 순환 의존성이나 내부 패키지 접근 위치를 알려주는 위반 목록을 확인할 수 있습니다. 개발자가 패키지를 옮긴 뒤 테스트를 실행하지 않으면 규칙이 존재해도 효과가 없으므로 CI의 일반 테스트 단계에 포함시키는 것이 좋습니다.

## 패키지 분리만으로 해결되지 않는 문제

첫 번째 실수는 공통이라는 이름의 패키지를 만드는 것입니다. 여러 모듈이 사용하는 entity, repository, util을 common에 넣으면 처음에는 의존성이 줄어든 것처럼 보이지만, common이 사실상 모든 도메인의 내부 구현을 담는 거대한 모듈이 됩니다. 공통 코드가 정말 안정적인 기술 추상화인지, 특정 도메인의 규칙인지 먼저 구분해야 합니다.

두 번째는 공개 API에 너무 많은 타입을 노출하는 것입니다. Facade 메서드의 매개변수와 반환값이 내부 entity이면 다른 모듈이 내부 구조에 결합됩니다. 외부 모듈이 필요한 데이터만 담은 명령·조회 DTO나 도메인 이벤트를 사용하면 entity 변경의 파급 범위를 줄일 수 있습니다.

세 번째는 이벤트를 사용하면 결합이 사라진다고 생각하는 것입니다. 이벤트는 직접 메서드 호출보다 결합을 낮출 수 있지만, 이벤트 payload와 처리 순서라는 계약이 새로 생깁니다. 동기 이벤트 listener가 긴 작업을 수행하거나 실패를 호출자에게 전파한다면, 구조만 이벤트로 바뀌었을 뿐 운영 결합은 남아 있을 수 있습니다.

네 번째는 검증을 한 번만 실행하는 것입니다. 모듈 경계는 코드가 커질수록 다시 무너집니다. 신규 모듈을 추가하거나 허용 의존성을 변경할 때 반드시 architecture test를 함께 수정하고, 변경 이유를 기록해야 합니다. 허용 목록을 무조건 늘리는 것은 검증을 끄는 것과 비슷한 결과를 만듭니다.

## 테스트와 운영에서 확인할 것

Spring Modulith는 모듈별 통합 테스트도 지원합니다. 한 모듈과 직접 의존하는 모듈만 올리는 방식으로 테스트 범위를 줄이면 전체 SpringBootTest보다 빠르게 경계와 wiring을 확인할 수 있습니다. 다른 모듈의 bean을 너무 많이 mock해야 한다면 해당 모듈 간 결합이 높은 신호로 보고 API나 이벤트 경계를 다시 검토할 수 있습니다.

운영에서는 모듈 경계가 배포 단위를 나누지는 않지만, 변경 영향과 관측 단위를 나누는 데 도움을 줍니다. 모듈별 호출 횟수, 이벤트 listener 처리 시간, 실패 수, 모듈 간 의존 방향을 기록하면 특정 도메인의 장애가 어디로 전파되는지 확인하기 쉬워집니다. Spring Modulith의 production-ready 기능을 사용하면 모듈 구조를 actuator로 노출하고 상호작용을 metrics와 trace로 관찰할 수 있습니다.

모듈화 적용 여부는 다음처럼 판단합니다.

- 하나의 배포 단위를 유지하면서 도메인별 변경 독립성을 높이고 싶다면 적용합니다.
- 팀이 실제로 모듈별 책임과 공개 API를 합의할 수 있어야 합니다.
- 데이터베이스 테이블을 공유한다면 코드 경계만으로 트랜잭션과 정합성이 분리된다고 생각하지 않습니다.
- 운영·조직·데이터 경계가 이미 강하게 분리되어야 한다면 모듈러 모놀리스가 마이크로서비스의 대체재가 아닐 수 있습니다.

정리하면 다음과 같습니다.

- 패키지 구조는 경계를 표현할 뿐 자동으로 지켜주지 않습니다.
- 모듈 경계에는 공개 API, 허용 의존 방향, 내부 패키지 규칙이 함께 필요합니다.
- ApplicationModules.verify를 CI에 넣으면 순환 의존성과 내부 접근을 코드 수준에서 조기에 발견할 수 있습니다.
- 검증을 통과해도 데이터베이스와 이벤트 계약의 운영 결합까지 사라지는 것은 아니므로 별도로 관찰해야 합니다.

## 참고한 공식 문서

- [Spring Modulith application module verification](https://docs.spring.io/spring-modulith/reference/verification.html)
- [Spring Modulith application module testing](https://docs.spring.io/spring-modulith/reference/testing.html)
- [Spring Modulith production-ready features](https://docs.spring.io/spring-modulith/reference/production-ready.html)
