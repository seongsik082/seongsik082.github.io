---
title: "Kafka consumer offset commit을 잘못 잡으면 누락과 중복이 함께 생기는 이유"
date: 2026-06-30 08:58:00 +0900
tags: [Kafka, Messaging, Backend]
excerpt: "Kafka consumer는 offset을 언제 commit하느냐에 따라 같은 메시지를 다시 처리할 수도 있고, 반대로 아직 처리하지 않은 메시지를 건너뛸 수도 있습니다."
---

## 문제 상황

Kafka consumer 장애를 보면 겉으로는 단순해 보일 때가 많습니다. 메시지는 분명 토픽에 들어왔고, consumer도 살아 있는데 어떤 건 두 번 처리되고 어떤 건 아예 처리되지 않았다고 보고됩니다. 운영자는 "Kafka가 중복 전달했나?"라고 묻지만, 실제 원인은 브로커보다 consumer 애플리케이션의 offset commit 시점인 경우가 더 많습니다.

특히 실무에서는 `poll()`로 읽은 뒤 바로 비즈니스 로직이 끝나는 경우가 드뭅니다. DB 저장, 외부 API 호출, 캐시 갱신, 알림 발행처럼 처리 단계가 여러 개로 나뉘고, 그 사이에 예외나 재시작이 끼어들 수 있습니다. 이때 offset을 너무 빨리 commit하면 아직 처리하지 않은 레코드를 건너뛰게 되고, 너무 늦게 commit하면 이미 처리한 레코드를 다시 읽게 됩니다.

중요한 포인트는 Kafka가 "자동으로 정확히 한 번 처리"를 보장해 주지 않는다는 점입니다. consumer는 offset의 `position`과 `committed position`을 분리해서 관리합니다. 따라서 장애를 줄이려면 "언제 읽었는가"보다 "언제 처리 완료로 간주했는가"를 먼저 정의해야 합니다.

## 핵심 개념

Kafka 공식 문서는 consumer의 위치를 두 가지로 설명합니다. `position`은 다음에 읽을 레코드 위치이고, `committed position`은 재시작 후 복구 기준이 되는 안전한 위치입니다. 이 둘이 다르기 때문에 애플리케이션은 "읽음"과 "처리 완료"를 별개로 다뤄야 합니다.

`enable.auto.commit=true`이면 consumer는 백그라운드에서 주기적으로 offset을 commit합니다. 기본 `auto.commit.interval.ms`는 5초입니다. 문제는 auto commit이 "비즈니스 처리가 끝났는지"를 모르고, 단지 consumer가 돌고 있다는 사실만 기준으로 움직인다는 점입니다. Kafka 공식 문서도 auto commit을 쓰더라도 `poll()`로 받은 데이터를 다음 `poll()` 전에 모두 처리하지 않으면 committed offset이 실제 처리 위치보다 앞서갈 수 있고, 그 결과 메시지 유실이 생길 수 있다고 설명합니다.

반대로 manual commit은 처리 완료 이후에만 offset을 기록하게 해 줍니다. 대신 프로세스가 DB 저장 직후 죽고 commit 전에 재시작되면 같은 메시지를 다시 읽을 수 있습니다. 즉 manual commit은 보통 at-least-once에 가깝고, 중복 처리를 소비자 코드나 저장소 제약으로 흡수해야 현실적으로 안전합니다.

또 하나 봐야 할 값이 `max.poll.interval.ms`입니다. 이 시간을 넘길 만큼 처리가 길어지면 consumer는 그룹에서 이탈한 것으로 간주되고 rebalance가 일어납니다. Kafka 공식 문서와 javadoc은 이런 상황에서 `commitSync()`가 `CommitFailedException`으로 실패할 수 있다고 설명합니다. 처리 스레드가 오래 붙잡고 있는데 poll loop가 멈춰 있으면, commit 전략을 잘 짜도 결국 그룹 재조정 때문에 꼬일 수 있다는 뜻입니다.

## 코드로 보기

문제가 되기 쉬운 코드는 아래처럼 auto commit에 의존하면서 무거운 처리를 섞는 형태입니다.

```java
while (true) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(100));
    for (ConsumerRecord<String, String> record : records) {
        externalApi.call(record.value());
        orderRepository.save(convert(record));
    }
}
```

이 구조에서는 offset이 이미 자동 commit됐는데 `externalApi.call()`이나 DB 저장이 중간에 실패할 수 있습니다. 그러면 재시작 후에는 이미 지나간 offset부터 다시 시작하므로, 실패한 메시지가 사라진 것처럼 보일 수 있습니다.

더 안전한 기본형은 auto commit을 끄고, 처리 단위를 명확히 만든 뒤에 commit하는 것입니다.

```java
consumer.subscribe(List.of("orders"));

while (running) {
    ConsumerRecords<String, String> records = consumer.poll(Duration.ofMillis(200));

    for (TopicPartition partition : records.partitions()) {
        List<ConsumerRecord<String, String>> batch = records.records(partition);

        processBatch(batch);
        consumer.commitSync(
            Collections.singletonMap(partition, records.nextOffsets().get(partition))
        );
    }
}
```

Kafka javadoc은 commit할 offset이 "다음에 읽을 메시지의 offset"이어야 한다고 설명합니다. 그래서 마지막으로 처리한 레코드 offset이 아니라 `nextOffsets()`를 쓰는 편이 안전합니다.

## 자주 하는 실수

첫 번째 실수는 auto commit을 켜 둔 채로 비즈니스 처리 시간이 긴 consumer를 만드는 것입니다. 읽은 순간이 아니라 처리 완료 순간에 commit해야 하는데, 이 구분이 없으면 장애 때 누락이 생깁니다.

두 번째 실수는 manual commit으로 바꿨지만 중복 처리를 고려하지 않는 것입니다. DB unique key, idempotency key, 이미 처리한 이벤트 저장 테이블 같은 장치가 없으면 재시작 후 같은 메시지가 한 번 더 반영될 수 있습니다.

세 번째 실수는 poll loop 하나로 읽기와 무거운 처리를 모두 감당하게 두는 것입니다. Kafka 공식 문서는 처리 시간이 예측되지 않을 때 별도 스레드로 작업을 넘기고, 그 동안 consumer는 계속 `poll()`을 호출하게 하라고 권장합니다. 그렇지 않으면 `max.poll.interval.ms` 초과로 rebalance가 일어나기 쉽습니다.

## 언제 쓰면 좋은가

manual commit을 적극적으로 고려해야 하는 경우는 메시지 처리 후 DB 반영이나 외부 시스템 호출이 반드시 끝나야 "소비 완료"로 볼 수 있는 서비스입니다. 주문 상태 변경, 결제 후속 처리, 재고 차감처럼 재처리 또는 누락의 비용이 큰 흐름이 여기에 가깝습니다.

반대로 로그 수집이나 통계 집계처럼 일부 중복이나 지연이 상대적으로 덜 치명적인 파이프라인은 구조를 더 단순하게 가져갈 수 있습니다. 그래도 처리 시간이 길다면 auto commit만 믿지 말고, 최소한 한 번의 `poll()`에서 받은 데이터를 언제까지 끝낼 수 있는지 계산해 보는 편이 좋습니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "이 메시지를 다시 처리하는 비용보다, 놓쳤을 때 복구 비용이 더 큰가?" 그렇다면 auto commit 기본값보다 manual commit과 중복 허용 설계를 먼저 택하는 편이 안전합니다.

## 운영에서 볼 것

- consumer lag 증가 시점과 rebalance 발생 시점
- `CommitFailedException` 발생 건수
- 처리 시간 p95가 `max.poll.interval.ms`에 얼마나 가까운지
- 같은 비즈니스 키가 중복 반영된 횟수
- DLQ 또는 재처리 큐로 이동한 메시지 수

로그에는 최소한 아래 필드를 남기는 편이 좋습니다.

- topic
- partition
- offset
- consumer group id
- 처리 시작/종료 시간
- commit 성공/실패 여부

이 정보가 있어야 "Kafka가 중복 전달했는가"가 아니라 "우리 서비스가 언제 commit했고 언제 실패했는가"로 문제를 좁힐 수 있습니다.

## 정리

Kafka consumer에서 중요한 것은 메시지를 읽었다는 사실보다, 언제 처리 완료로 인정하고 offset을 남길 것인지입니다. auto commit은 편하지만 처리 완료와 무관하게 앞서갈 수 있고, manual commit은 안전하지만 중복 처리를 감수해야 합니다. 운영에서는 lag만 보지 말고 commit 실패, 처리 시간, rebalance 시점을 함께 봐야 실제 원인을 더 빨리 찾을 수 있습니다.

## 참고한 공식 문서

- Apache Kafka Consumer Configs: https://kafka.apache.org/43/configuration/consumer-configs/
- Apache Kafka `KafkaConsumer` Javadoc: https://kafka.apache.org/43/javadoc/org/apache/kafka/clients/consumer/KafkaConsumer.html
