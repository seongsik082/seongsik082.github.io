---
title: "H2로 통과한 테스트가 PostgreSQL에서 깨지는 이유와 Testcontainers 적용 기준"
date: 2026-07-17 08:50:00 +0900
tags: [Testing, Testcontainers, Database, Backend]
excerpt: "H2 기반 테스트는 빠르지만 PostgreSQL의 타입, 함수, 인덱스, 트랜잭션 동작까지 동일하게 재현하지는 않습니다. Testcontainers로 운영과 같은 DB 엔진과 버전을 띄우고 마이그레이션·제약조건·대표 쿼리를 검증할 범위를 나누는 실무 기준을 정리합니다."
---

## 문제 상황

로컬과 CI의 테스트는 모두 통과했는데 배포 후 PostgreSQL에서만 SQL 오류가 발생하는 경우가 있습니다. H2가 지원하지 않는 JSONB 연산자, PostgreSQL 전용 함수, partial index 조건, enum 처리, timestamp 정밀도 차이가 원인일 수 있습니다. 테스트에서는 단순한 문자열이나 숫자로 보였던 컬럼이 운영 DB에서는 다른 타입과 제약조건을 가지고 있었던 것입니다.

또 다른 문제는 마이그레이션입니다. 애플리케이션 테스트는 이미 만들어진 테스트 테이블을 재사용하거나 JPA가 스키마를 자동 생성하도록 두었지만, 운영에서는 Flyway나 Liquibase가 빈 데이터베이스에 순서대로 migration을 실행합니다. 새 데이터베이스에서 처음부터 시작하는 경로와 기존 데이터가 있는 상태에서 업그레이드하는 경로가 모두 검증되지 않으면 배포 시점에 실패합니다.

## H2와 운영 DB의 차이를 구분한다

H2는 빠르고 설정이 간단해 순수한 서비스 로직이나 간단한 repository 테스트에 유용합니다. 그러나 H2 모드가 PostgreSQL 문법과 비슷해 보여도 엔진 내부의 타입, planner, locking, isolation, function 동작까지 동일하게 만들지는 않습니다.

Testcontainers는 테스트 중 실제 데이터베이스를 컨테이너로 실행합니다. 공식 문서처럼 실제 DB 엔진과 알려진 초기 상태를 사용하므로 H2와 운영 DB 사이의 공백을 줄일 수 있습니다. 대신 컨테이너 시작 비용이 있어 모든 단위 테스트에 적용하면 안 됩니다.

다음 기준으로 테스트 층을 나누면 비용을 관리하기 쉽습니다.

- 도메인 계산과 순수 변환은 일반 단위 테스트로 빠르게 실행합니다.
- SQL, mapping, constraint, transaction을 확인하는 repository 테스트는 실제 DB 컨테이너를 사용합니다.
- 배포 직전에는 빈 DB에서 전체 migration을 실행하고 애플리케이션이 기동하는지 확인합니다.
- 중요 쿼리는 실제 운영 DB와 같은 major version에서 결과와 실행 실패 여부를 검증합니다.

## 실제 DB를 테스트에 연결하는 예시

Testcontainers의 JDBC URL 방식은 애플리케이션이 사용할 JDBC URL을 바꾸어 테스트용 DB를 자동으로 준비하는 방법입니다.

    spring.datasource.url=jdbc:tc:postgresql:16:///orders
    spring.datasource.username=test
    spring.datasource.password=test

프로덕션이 PostgreSQL 16이라면 테스트도 임의의 latest 이미지가 아니라 16 계열처럼 버전을 고정하는 편이 좋습니다. extension 차이까지 민감하다면 CI 이미지 digest와 운영 이미지 변경 절차도 관리해야 합니다. 예시 버전은 팀 환경에 맞추되, 운영 엔진과 다른 버전을 설명 없이 사용하는 것이 더 위험합니다.

마이그레이션 검증은 다음과 같은 테스트 흐름으로 구성할 수 있습니다.

    1. 빈 PostgreSQL 컨테이너를 시작한다.
    2. 애플리케이션의 Flyway 또는 Liquibase migration을 모두 실행한다.
    3. 핵심 테이블, index, constraint, 권한이 기대한 상태인지 확인한다.
    4. 대표적인 insert, update, 조회 쿼리를 실제로 실행한다.
    5. 기존 버전 데이터가 있는 fixture에 새 migration을 적용하는 경로도 별도로 실행한다.

고정된 초기 SQL이 있다면 Testcontainers JDBC URL의 init script를 사용할 수 있고, Flyway나 Liquibase 같은 migration 도구를 호출해야 한다면 init function 또는 애플리케이션 기동 경로를 사용할 수 있습니다. 중요한 것은 테스트 편의를 위해 JPA의 create-drop으로 운영 migration 경로를 대체하지 않는 것입니다.

## 자주 놓치는 차이

첫 번째는 SQL 문법만 확인하고 transaction 동작을 확인하지 않는 경우입니다. PostgreSQL의 격리 수준, unique violation, foreign key 오류 시점, lock 대기와 rollback을 애플리케이션이 어떻게 처리하는지 테스트해야 합니다. 단순히 repository 메서드가 결과를 반환했다는 것만으로는 충분하지 않습니다.

두 번째는 이미지 버전을 고정하지 않는 경우입니다. 개발자는 로컬에서 받은 이미지와 CI가 새로 받은 이미지가 다를 수 있고, minor 변경이나 extension 설치 여부가 결과를 바꿀 수 있습니다. 이미지 업데이트는 의존성 업데이트와 동일하게 changelog와 회귀 테스트를 남겨야 합니다.

세 번째는 테스트 컨테이너의 초기 상태를 재사용하는 경우입니다. 이전 테스트가 남긴 데이터와 schema가 다음 테스트에 영향을 주면 잘못된 안정성이 생깁니다. 테스트 간 격리와 병렬 실행 시 이름 충돌 방지가 필요합니다.

네 번째는 Testcontainers가 운영 환경 전체를 재현한다고 믿는 경우입니다. 실제 DB 엔진을 검증해도 네트워크 지연, RDS parameter group, replica lag, backup 정책, IAM 인증, connection pool과 같은 운영 조건까지 자동으로 재현되지는 않습니다. 컨테이너는 DB 호환성의 공백을 줄이는 도구이지 전체 장애 시뮬레이터가 아닙니다.

## 언제 적용할 것인가

다음 조건이면 Testcontainers의 비용을 감수할 가치가 큽니다.

- H2가 지원하지 않는 DB 전용 SQL이나 타입을 사용합니다.
- migration 실패가 배포 중단으로 이어집니다.
- repository 쿼리의 결과뿐 아니라 constraint와 transaction 실패를 검증해야 합니다.
- 개발자마다 설치한 DB 버전이 달라 테스트 결과가 흔들립니다.

반대로 모든 서비스 테스트를 실제 DB로 바꾸면 피드백 속도가 느려지고 테스트 실패 원인이 넓어집니다. 순수 로직은 빠른 단위 테스트로 유지하고, 실제 DB 테스트는 도메인별 핵심 쿼리·migration·회귀 시나리오에 집중하는 편이 낫습니다. CI에서는 컨테이너 시작 시간, 이미지 cache 적중률, flaky test, migration 실행 시간을 별도 지표로 관찰합니다.

정리하면 다음과 같습니다.

- H2 테스트 통과는 PostgreSQL의 SQL·타입·제약조건 호환성을 보장하지 않습니다.
- Testcontainers는 실제 DB 엔진과 알려진 초기 상태를 제공하지만 모든 운영 환경을 복제하지는 않습니다.
- 운영 DB와 같은 major version으로 migration과 핵심 repository 쿼리를 검증해야 합니다.
- 빠른 단위 테스트와 비용이 큰 DB 통합 테스트의 경계를 분리해야 테스트 속도와 신뢰성을 함께 유지할 수 있습니다.

## 참고한 공식 문서

- [Testcontainers Java database containers](https://java.testcontainers.org/modules/databases/)
- [Testcontainers JDBC support and migration init functions](https://java.testcontainers.org/modules/databases/jdbc/)
