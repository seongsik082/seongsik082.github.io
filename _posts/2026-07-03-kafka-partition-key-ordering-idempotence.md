---
title: "Kafka 파티션 키를 대충 고르면 같은 주문 이벤트의 순서가 뒤집히는 이유"
date: 2026-07-03 08:51:00 +0900
tags: [Kafka, Messaging, Backend]
excerpt: "Kafka는 같은 키를 같은 파티션으로 보내는 방식으로 순서를 다루는데, 키 설계가 흔들리거나 idempotence와 재시도 설정을 가볍게 보면 같은 엔터티의 이벤트도 운영에서 순서가 어긋날 수 있습니다."
---

## 문제 상황

주문 서비스에서 `ORDER_CREATED`, `ORDER_PAID`, `ORDER_CANCELLED` 이벤트를 Kafka로 내보낼 때, 개발 단계에서는 보통 한 파티션 또는 적은 트래픽으로 잘 돌아갑니다. 그래서 "Kafka는 순서를 보장하니까 괜찮다"라고 생각하기 쉽습니다.

운영으로 가면 이야기가 달라집니다. 어떤 주문은 `PAID`가 먼저 소비되고 몇 초 뒤에 `CREATED`가 따라오고, 어떤 소비자는 같은 주문 상태를 두 번 되돌렸다가 다시 앞으로 움직입니다. 코드는 크게 바뀐 게 없는데도 장애가 생기는 이유는, Kafka의 순서 보장이 "토픽 전체"가 아니라 사실상 "파티션과 프로듀서 설정"에 의존하기 때문입니다.

같은 주문의 이벤트가 항상 같은 파티션으로 가야 하는데 이벤트마다 다른 키를 쓰거나, 아예 키를 빼고 보내거나, 장애 상황에서 재시도 설정이 순서를 흔드는 구성을 쓰면 이 가정이 무너집니다. 그러면 소비자에서 아무리 정교하게 코드를 짜도 이미 입력 스트림이 어긋난 상태로 들어옵니다.

## 핵심 개념

Kafka 공식 문서의 `ProducerRecord` javadoc은 파티션 번호를 명시하면 그 파티션으로 보내고, 파티션을 지정하지 않았지만 key가 있으면 key의 해시를 바탕으로 파티션을 고른다고 설명합니다. 즉, 같은 엔터티의 순서를 맞추려면 "같은 엔터티에 대해 안정적인 key를 계속 사용한다"가 첫 번째 규칙입니다.

여기서 중요한 것은 key가 단순 식별자가 아니라 "순서를 묶는 단위"라는 점입니다. 주문 상태 전이 순서가 중요하면 `orderId`가 key 후보가 되고, 회원 전체 이력 순서가 중요하면 `userId`가 후보가 됩니다. 반대로 이벤트마다 새 UUID를 key로 쓰면 Kafka 입장에서는 서로 다른 흐름으로 보게 됩니다.

두 번째 규칙은 재시도와 순서의 관계입니다. Kafka producer config 문서는 `enable.idempotence=false`이고 `max.in.flight.requests.per.connection > 1`인 상태에서 재시도가 발생하면, 같은 파티션으로 보낸 두 배치도 뒤집힐 수 있다고 설명합니다. 첫 번째 배치가 실패 후 재시도되는 사이 두 번째 배치가 먼저 성공하면, 소비자 입장에서는 나중 이벤트가 먼저 보입니다.

현재 KafkaProducer javadoc은 Kafka 3.0부터 `enable.idempotence` 기본값이 `true`라고 설명합니다. 이 기본값은 꽤 안전한 방향이지만, 운영 코드에서 설정을 명시적으로 덮어쓰거나, 애플리케이션 레벨에서 직접 재전송을 다시 구현하면 그 보호막이 약해질 수 있습니다. 공식 문서도 프로듀서 세션 밖에서 애플리케이션이 재전송하는 경우는 중복 제거 대상이 아니라고 경고합니다.

## 코드로 보기

문제 있는 예시는 보통 이렇게 생깁니다.

```java
ProducerRecord<String, OrderEvent> record =
    new ProducerRecord<>("order-events", UUID.randomUUID().toString(), event);

producer.send(record);
```

이 코드는 각 이벤트마다 다른 key를 쓰므로, 같은 주문의 이벤트라도 파티션이 달라질 수 있습니다. 그러면 주문 한 건의 상태 전이를 소비자 한 곳에서 순서대로 처리하기가 어려워집니다.

보통은 아래처럼 "순서를 맞추고 싶은 엔터티 식별자"를 key로 고르는 편이 맞습니다.

```java
Properties props = new Properties();
props.put("bootstrap.servers", "kafka:9092");
props.put("acks", "all");
props.put("enable.idempotence", "true");
props.put("key.serializer", StringSerializer.class.getName());
props.put("value.serializer", JsonSerializer.class.getName());

ProducerRecord<String, OrderEvent> record =
    new ProducerRecord<>("order-events", event.orderId(), event);

producer.send(record);
```

이 구조에서도 trade-off는 남습니다. `orderId`를 key로 쓰면 주문 단위 순서는 맞추기 쉬워지지만, 특정 주문이나 특정 고객군에 트래픽이 몰릴 때는 파티션 hot spot이 생길 수 있습니다. 반대로 더 고르게 분산하려고 key를 지나치게 잘게 쪼개면, 원래 지키고 싶었던 순서를 잃습니다.

## 자주 하는 실수

첫 번째 실수는 "Kafka는 원래 순서를 보장한다"라고 넓게 이해하는 것입니다. 실제 설계에서는 "어떤 단위의 순서를 어디까지 보장할 것인가"를 먼저 정하고 key를 골라야 합니다.

두 번째 실수는 엔터티 식별자 대신 이벤트 ID를 key로 쓰는 것입니다. 이벤트 ID는 보통 매번 새로 생기므로, 순서를 묶는 기준으로는 오히려 부적절합니다.

세 번째 실수는 파티션 수 증설 영향을 가볍게 보는 것입니다. key 기반 라우팅은 파티션 수가 바뀌면 분포가 달라질 수 있으므로, "같은 key가 앞으로도 같은 파티션에 머무를 것"을 너무 강하게 전제하면 안 됩니다. 순서 보장이 필요한 단위는 소비자 코드와 운영 절차 양쪽에서 함께 다뤄야 합니다.

네 번째 실수는 idempotence를 꺼 놓은 채 재시도만 늘리는 것입니다. 공식 문서가 설명하듯 이 조합은 같은 파티션 안에서도 장애 시 재정렬 위험을 키웁니다.

## 언제 쓰면 좋은가

Kafka key 설계는 도메인 경계와 함께 결정해야 합니다. 한 주문의 상태 전이가 중요하면 `orderId`, 한 결제의 승인/취소/환불 순서가 중요하면 `paymentId`, 한 계좌의 잔액 이벤트가 중요하면 `accountId`처럼 "같이 처리되어야 하는 단위"를 key로 보는 편이 맞습니다.

반대로 전체 처리량이 더 중요하고 개별 엔터티의 엄격한 순서는 필요하지 않다면, 굳이 강한 key 고정을 하지 않는 편이 나을 수 있습니다. 모든 것을 한 key 체계로 묶으면 특정 파티션만 과열되고 소비 확장이 어려워질 수 있습니다.

실무 판단 기준을 하나만 고르면 이렇습니다. 소비자가 이전 이벤트를 모른 채 다음 이벤트를 처리하면 잘못된 상태가 되는가? 그렇다면 그 둘은 같은 key로 묶여야 합니다. 이 질문이 설계 회의에서 가장 빠르게 통합니다.

## 운영에서 볼 것

- 파티션별 생산량 편차와 특정 파티션 집중 여부
- 프로듀서 retry 증가 시 순서 관련 장애가 함께 늘어나는지
- 같은 엔터티 ID에서 out-of-order 처리가 감지되는지
- 파티션 수 변경 이후 동일 엔터티 처리 흐름이 달라졌는지
- 애플리케이션 레벨 재전송 코드가 별도로 존재하는지

장애가 났을 때는 소비자 코드만 보지 말고, 문제 엔터티의 key가 무엇이었는지부터 확인하는 편이 좋습니다. 순서 문제는 종종 "Kafka가 이상하다"가 아니라 "우리가 어떤 단위를 같은 흐름으로 보낼지 정하지 않았다"에서 시작합니다.

## 정리

Kafka에서 순서는 파티션과 프로듀서 설정 위에서 성립합니다. 같은 엔터티의 이벤트를 안정적인 key로 묶지 않으면 순서 설계는 처음부터 흔들리고, 재시도와 idempotence 설정을 잘못 잡으면 같은 파티션 안에서도 장애 시 순서가 뒤집힐 수 있습니다. Kafka key는 단순 분산 키가 아니라, 어떤 비즈니스 흐름을 함께 직렬화할지 결정하는 설계 값입니다.

## 참고한 공식 문서

- [Apache Kafka `ProducerRecord` Javadoc](https://kafka.apache.org/41/javadoc/org/apache/kafka/clients/producer/ProducerRecord.html)
- [Apache Kafka Producer Configs](https://kafka.apache.org/38/generated/producer_config.html)
- [Apache Kafka `KafkaProducer` Javadoc](https://kafka.apache.org/41/javadoc/org/apache/kafka/clients/producer/KafkaProducer.html)
