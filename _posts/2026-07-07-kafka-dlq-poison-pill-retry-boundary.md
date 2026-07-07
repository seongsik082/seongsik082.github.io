---
title: "Kafka DLQ를 만들기 전에 poison pill과 재시도 경계를 먼저 정해야 하는 이유"
date: 2026-07-07 08:55:00 +0900
tags: [Kafka, Messaging, Backend]
excerpt: "Kafka consumer 장애에서 DLQ는 실패 메시지를 치우는 쓰레기통이 아니라, 반복 실패 레코드가 consumer group 전체를 막지 않도록 격리하고 나중에 복구할 수 있게 만드는 운영 장치입니다."
---

주문 이벤트 consumer가 특정 메시지 하나에서 계속 실패한다고 가정해보자. 새 배포 뒤 역직렬화 예외가 나고, 같은 offset을 다시 읽고, 다시 실패한다. 뒤에 쌓인 정상 이벤트는 처리되지 않는다. 알림은 consumer lag 증가로만 보이고, 애플리케이션 로그에는 같은 stack trace가 반복된다.

이런 메시지를 흔히 poison pill이라고 부른다. 독이 든 알약처럼 consumer가 삼키는 순간 계속 실패를 만들고, 파티션의 다음 메시지로 진행하지 못하게 만드는 레코드다. DLQ, 또는 dead letter queue는 이 실패 레코드를 별도 토픽으로 옮겨 본 처리 흐름을 계속 진행하게 만드는 패턴이다.

하지만 DLQ를 "실패하면 보내는 곳" 정도로만 만들면 또 다른 운영 문제가 생긴다. 일시적인 DB 타임아웃까지 바로 DLQ로 보내면 정상 복구 가능한 메시지가 누락처럼 보인다. 반대로 모든 실패를 무한 재시도하면 poison pill 하나가 consumer group 전체 지연을 키운다. 핵심은 DLQ 자체가 아니라 어떤 실패를 몇 번 재시도하고, 어디서 포기하며, 포기한 메시지를 어떻게 다시 처리할지 정하는 것이다.

## 문제 상황

가장 단순한 consumer 코드는 실패 처리가 없다.

```java
@KafkaListener(topics = "order-created", groupId = "billing")
public void listen(OrderCreated event) {
    billingService.charge(event.orderId(), event.amount());
}
```

이 코드는 정상 메시지만 들어올 때는 읽기 쉽다. 하지만 `OrderCreated` 스키마가 바뀌었거나, 금액 필드가 비어 있거나, 외부 결제 API가 30초 동안 느려지면 이야기가 달라진다. 예외가 listener 밖으로 나가고, container의 error handler 설정에 따라 같은 record가 다시 전달될 수 있다.

Kafka는 topic, partition, offset 순서로 메시지를 읽는다. 같은 파티션에서 현재 offset을 처리하지 못하면 그 뒤 offset도 함께 밀린다. 그래서 실패 하나가 "그 메시지 하나 실패"로 끝나지 않고 같은 파티션의 정상 메시지 지연으로 번진다.

운영에서 더 위험한 지점은 실패 종류가 섞인다는 점이다. DB deadlock처럼 짧은 재시도로 해결될 수 있는 실패, JSON 포맷 오류처럼 같은 메시지를 다시 읽어도 해결되지 않는 실패, 외부 API 장애처럼 몇 분 뒤 다시 시도해야 하는 실패가 모두 같은 catch 블록으로 들어온다. DLQ 설계는 이 실패들을 구분하는 데서 시작해야 한다.

## 핵심 개념

DLQ는 Kafka 자체의 마법 기능이라기보다 실패한 record를 별도 topic에 publish하는 애플리케이션 또는 프레임워크 레벨의 처리 방식이다. Spring Kafka에서는 `DefaultErrorHandler`와 `DeadLetterPublishingRecoverer`를 조합해 일정 횟수 재시도 뒤 실패 record를 dead letter topic으로 보낼 수 있다.

중요한 용어는 세 가지다.

첫째, retryable failure다. 네트워크 흔들림, 일시적 503, DB deadlock처럼 같은 요청을 다시 실행하면 성공할 수 있는 실패다. 이런 실패는 짧은 backoff와 제한된 횟수 재시도가 도움이 된다.

둘째, non-retryable failure다. 역직렬화 실패, 필수 필드 누락, 잘못된 enum 값처럼 메시지 내용 자체가 틀린 경우다. 같은 메시지를 100번 읽어도 성공하지 않는다. 이런 실패는 빠르게 DLQ로 보내고 원인을 조사하는 편이 낫다.

셋째, recovery다. 실패 record를 버리는 것이 아니라 별도 topic, 테이블, 로그로 옮겨 나중에 재처리할 수 있게 만드는 단계다. DLQ가 운영 장치가 되려면 이 recovery 이후의 조사, 수정, replay 절차까지 있어야 한다.

## 설정으로 보기

Spring Kafka에서 흔히 잡는 구조는 "짧게 재시도하고, 그래도 실패하면 원본 partition을 유지한 DLT로 보낸다"는 방식이다.

```java
@Bean
DefaultErrorHandler kafkaErrorHandler(KafkaTemplate<Object, Object> template) {
    DeadLetterPublishingRecoverer recoverer =
        new DeadLetterPublishingRecoverer(template,
            (record, ex) -> new TopicPartition(record.topic() + ".DLT", record.partition()));

    DefaultErrorHandler handler =
        new DefaultErrorHandler(recoverer, new FixedBackOff(1000L, 2L));

    handler.addNotRetryableExceptions(
        org.apache.kafka.common.errors.SerializationException.class,
        IllegalArgumentException.class
    );

    return handler;
}
```

여기서 `FixedBackOff(1000L, 2L)`는 최초 처리까지 포함해 제한된 횟수만 시도하게 만든다. 실패가 계속되면 recoverer가 `order-created.DLT` 같은 토픽으로 record를 보낸다. DLT partition을 원본 partition과 맞추면 같은 엔터티의 실패 흐름을 조사할 때 순서를 따라가기 쉽다.

실무에서는 예외 분류가 더 중요하다. 결제 API 503은 retryable일 수 있지만, `amount`가 음수라서 생긴 `IllegalArgumentException`은 재시도해도 소용이 없다. 재시도 정책은 예외 타입, downstream 응답 코드, 메시지 검증 실패 여부에 따라 나누어야 한다.

## 자주 하는 실수

첫 번째 실수는 무한 재시도를 안전하다고 생각하는 것이다. 무한 재시도는 메시지를 잃지 않는 것처럼 보이지만, poison pill에서는 파티션을 계속 막는다. consumer lag가 늘고, 정상 이벤트 처리도 늦어진다. 메시지를 잃지 않는 것과 시스템을 계속 진행시키는 것은 별개의 문제다.

두 번째 실수는 DLQ로 보낸 뒤 offset commit 의미를 확인하지 않는 것이다. 실패 record를 DLT로 성공적으로 publish했다면 원본 record는 더 이상 본 consumer가 붙잡지 않아야 한다. 반대로 DLT publish가 실패했는데 원본 offset을 진행시키면 실패 메시지를 잃을 수 있다. framework 설정이 recovered record의 offset을 어떻게 다루는지 확인해야 한다.

세 번째 실수는 DLT를 아무도 읽지 않는 창고로 두는 것이다. DLT 메시지 수, 오래된 메시지 나이, 예외 타입 분포, replay 성공률을 보지 않으면 장애가 "처리 지연"에서 "조용한 데이터 누락"으로 바뀐다.

네 번째 실수는 모든 예외 stack trace를 header에 과하게 싣는 것이다. 조사에는 도움이 되지만 민감 데이터나 너무 큰 header가 생길 수 있다. 운영에서는 필요한 오류 코드, exception class, 실패 단계, 원본 topic/partition/offset 정도를 우선 남기고 payload 보관 정책을 따로 정해야 한다.

## 언제 DLQ를 쓰면 좋은가

DLQ는 메시지 하나의 실패가 전체 스트림 진행을 막을 때 유용하다. 주문, 결제, 알림처럼 같은 파티션 안에 정상 이벤트가 계속 들어오고, 일부 잘못된 이벤트를 나중에 사람이 조사할 수 있는 업무라면 효과가 크다.

반대로 실패 메시지를 절대 건너뛰면 안 되는 정산 원장, 잔액 변경, 법적 감사 이벤트라면 DLQ로 진행시키는 기준을 더 엄격히 잡아야 한다. 이때는 consumer를 멈추고 수동 조치하는 편이 안전할 수 있다. DLQ는 무조건 정답이 아니라 "일부 record를 격리해 전체 흐름을 살릴 수 있는가"라는 판단의 결과다.

실무 기준은 이렇게 잡을 수 있다. 같은 메시지를 같은 코드로 다시 처리했을 때 성공 가능성이 낮고, 실패 record를 별도 추적해 복구할 수 있다면 DLQ로 보낸다. 성공 가능성이 있고 downstream이 회복 중이라면 backoff 재시도를 먼저 쓴다. 실패 record를 건너뛰면 비즈니스 정합성이 깨진다면 자동 DLQ보다 운영 중단 알림을 우선한다.

## 운영에서 볼 것

DLQ를 운영한다면 본 topic의 consumer lag만 보지 말고 DLT도 함께 봐야 한다.

- DLT로 들어오는 메시지 수와 증가율
- exception class, error code, schema version별 분포
- DLT에 가장 오래 남아 있는 메시지 나이
- 원본 topic, partition, offset별 실패 반복 여부
- replay 작업의 성공률과 재실패율

알림도 두 단계로 나누는 편이 좋다. DLT가 한두 건 생겼다고 바로 장애로 볼 필요는 없지만, 같은 예외가 짧은 시간에 급증하거나 오래된 DLT 메시지가 남아 있으면 조치가 필요하다. 특히 배포 직후 DLT가 늘면 schema 변경이나 역직렬화 문제가 먼저 의심된다.

## 정리

Kafka DLQ는 실패를 숨기는 통이 아니라 consumer group이 poison pill 하나에 멈추지 않게 하는 격리 장치다. 재시도 가능한 실패와 불가능한 실패를 나누고, DLT publish와 offset commit 의미를 확인하며, DLT 자체를 모니터링해야 한다. 가장 중요한 기준은 "이 메시지를 지금 건너뛰어도 나중에 식별하고 복구할 수 있는가"다.

참고한 공식 문서:

- [Spring for Apache Kafka - Handling Exceptions](https://docs.spring.io/spring-kafka/reference/kafka/annotation-error-handling.html)
- [Apache Kafka Documentation](https://kafka.apache.org/documentation/)
