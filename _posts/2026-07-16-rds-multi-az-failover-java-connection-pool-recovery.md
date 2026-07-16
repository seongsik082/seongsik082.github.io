---
title: "RDS Multi-AZ failover가 끝났는데도 Java connection pool이 계속 실패하는 이유"
date: 2026-07-16 08:52:00 +0900
tags: [AWS, RDS, Java, Operations, Backend]
excerpt: "RDS Multi-AZ failover는 writer endpoint의 DNS 대상을 바꾸지만 기존 TCP 연결의 생명주기와 애플리케이션 커넥션 풀까지 자동으로 복구하지는 않습니다. JVM DNS TTL, 끊어진 idle connection 정리, 재연결 폭주, 트랜잭션 재시도의 위험을 함께 설계해야 합니다."
---

## 문제 상황

RDS Multi-AZ를 사용하면 데이터베이스가 자동으로 다른 인스턴스로 전환되므로 애플리케이션은 계속 동작할 것이라고 기대하기 쉽습니다. 실제 장애에서는 failover 이벤트가 끝난 뒤에도 Java 서비스의 5xx와 connection timeout이 몇 분 동안 이어질 수 있습니다. RDS 콘솔에는 새 writer가 보이는데 애플리케이션의 connection pool에는 idle connection이 남아 있고, 새 연결을 만들 때도 이전 IP로 접속하려는 로그가 반복되는 상황입니다.

핵심은 RDS 전환, DNS 갱신, 애플리케이션 pool의 새 TCP 연결 확보가 서로 다른 시점에 끝난다는 점입니다. 기존 TCP 연결은 DNS를 다시 조회하지 않습니다.

## RDS failover가 바꾸는 것

RDS Multi-AZ failover는 writer 역할을 옮기고 DB endpoint의 DNS가 새 인스턴스를 가리키게 합니다. 기존 연결은 재사용할 수 없고 Java JVM의 DNS 캐시 때문에 새 IP 사용도 늦어질 수 있습니다.

JVM DNS TTL은 모든 환경에서 같은 기본값이라고 가정하면 안 됩니다. AWS는 RDS Multi-AZ DB cluster failover 문서에서 JVM이 AWS 리소스 DNS를 너무 오래 캐시하지 않도록 networkaddress.cache.ttl을 60초 이하로 설정하는 방식을 안내합니다. 이 값은 연결이 만들어지기 전에 적용되어야 하며, 이미 오래된 연결을 새로 바꾸어 주는 설정은 아닙니다.

예를 들어 JVM 보안 프로퍼티에 다음처럼 적용할 수 있습니다.

    networkaddress.cache.ttl=60

실제 적용 위치와 기본값은 사용 중인 JDK와 실행 환경을 확인해야 합니다. 운영 중 값을 바꿔도 이미 채워진 DNS 캐시가 즉시 사라지는 것은 아니므로 새 연결 생성 테스트로 확인합니다.

## 커넥션 풀은 실패를 재사용하지 않아야 한다

Failover 직후 pool의 idle connection을 “유휴 상태라서 건강하다”고 보면 안 됩니다. 연결 객체가 pool에 남아 있어도 원격 writer가 사라졌거나, 해당 소켓이 이미 오류 상태일 수 있습니다. pool은 connection을 빌려줄 때 validation을 수행하고, 통신 오류가 난 연결을 폐기한 뒤 새 endpoint로 다시 연결해야 합니다.

서비스의 pool 설정에는 다음 정책이 필요합니다.

    connection-timeout-ms: 3000
    validation-timeout-ms: 1000
    connect-retry:
      max-attempts: 3
      backoff-ms: 200
    max-lifetime-ms: 1800000

위 값은 예시일 뿐이며 failover 시간을 예측하는 공식 값은 아닙니다. connection timeout은 요청 전체 timeout보다 짧아야 하고, validation timeout은 장애 연결을 오래 붙잡지 않을 정도로 짧아야 합니다. max lifetime은 주기적인 교체용이지 끊어진 연결을 즉시 치료하는 장치는 아닙니다. JDBC4 isValid, validation query, SQLState 분류도 확인해야 합니다.

재연결을 한꺼번에 시도하면 또 다른 장애가 생깁니다. 모든 인스턴스가 같은 순간에 pool 최대치만큼 새 연결을 만들면 RDS와 네트워크 장비에 connection storm이 발생합니다. 초기 연결 수와 최대 pool 크기를 분리하고, 실패 시 지수 백오프와 jitter를 적용하며, failover 중에는 요청을 짧게 실패시키거나 제한된 큐에서 기다리게 해야 합니다.

## 트랜잭션 재시도는 더 조심해야 한다

DB 연결이 끊겼다고 모든 SQL을 자동 재시도하면 안 됩니다. SELECT는 읽기 일관성과 timeout을 확인한 뒤 재시도할 수 있지만, INSERT나 결제·재고 차감 같은 쓰기는 연결이 끊긴 순간 커밋 전후를 알 수 없습니다. 애플리케이션은 “DB가 받지 못했다”고 생각해도 DB가 이미 커밋한 뒤 응답만 잃었을 수 있습니다.

따라서 retry 기준은 SQL 종류보다 비즈니스 작업의 멱등성으로 정합니다. 주문 생성에 요청 id와 unique constraint를 두고, 재시도 시 기존 결과를 반환할 수 있어야 합니다. Connection reset만 보고 다시 실행하면 중복 데이터가 생길 수 있습니다.

트랜잭션 중간에 연결이 끊겼다면 해당 트랜잭션이 재사용 가능한지 확신하지 말고 폐기합니다. pool에서 같은 connection을 다시 빌려 이전 세션 상태가 남아 있지 않은지 확인하는 것도 중요합니다. 자동 복구 라이브러리를 도입하더라도 트랜잭션 경계와 retry 가능한 작업 목록은 애플리케이션에서 명시해야 합니다.

## RDS Proxy를 선택할 때

RDS Proxy는 애플리케이션과 RDS 사이에서 연결을 관리하고 failover 때 새 writer로 전환하는 선택지입니다. AWS 문서에 따르면 proxy endpoint는 같은 주소로 연결을 받고 애플리케이션의 idle connection 대부분을 유지할 수 있어 DNS 지연과 pool 재연결 부담을 줄입니다.

대신 proxy가 진행 중인 모든 SQL과 트랜잭션을 보존하는 것은 아닙니다. AWS 문서에서도 failover 중 진행 중인 트랜잭션이나 SQL 문장은 취소될 수 있다고 설명합니다. 또한 세션 상태에 따라 connection pinning이 발생하면 multiplexing 효과가 줄어들고, proxy 비용과 추가 관측 지점이 생깁니다. 짧은 failover 복구가 중요한 서비스에는 유용하지만, 멱등성 없는 쓰기 재시도 문제를 대신 해결하지는 않습니다.

## 장애 리허설과 운영 지표

RDS 이벤트 로그와 pool active, idle, pending, connection creation, validation failure, connect timeout을 같은 시간축에 놓습니다. failover 전후 DNS 결과, 새 connection의 remote address, SQLState와 예외 종류도 남겨야 원인을 구분할 수 있습니다.

운영 리허설에서는 읽기 요청과 쓰기 요청을 분리해 failover를 실행하고, 이미 진행 중인 트랜잭션과 새 요청의 결과를 확인합니다. 복구 시간 목표가 짧다면 JVM DNS TTL, pool validation, RDS Proxy 도입 여부를 함께 비교합니다. 반대로 일시적인 쓰기 실패를 클라이언트가 안전하게 재시도할 수 없는 서비스라면 무리하게 자동 retry를 늘리기보다 명확한 실패 응답과 수동 보정 절차를 준비하는 편이 안전합니다.

정리하면 다음과 같습니다.

- RDS failover는 새 writer와 endpoint를 준비하지만 기존 TCP 연결과 Java pool까지 자동으로 정상화하지는 않습니다.
- JVM DNS TTL과 pool validation은 서로 다른 문제를 다루므로 둘 다 실제 환경에서 확인해야 합니다.
- 재연결 storm을 막기 위해 timeout, backoff, jitter, pool 상한을 함께 설계해야 합니다.
- DB 쓰기 재시도는 연결 오류가 아니라 비즈니스 멱등성 기준으로 허용해야 합니다.

## 참고한 공식 문서

- [Amazon RDS Multi-AZ DB cluster failover and JVM DNS TTL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/multi-az-db-clusters-concepts-failover.html)
- [Amazon RDS Proxy failover behavior](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-proxy.howitworks.html)
- [Connecting to an Amazon RDS DB instance and AWS drivers](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_CommonTasks.Connect.html)
