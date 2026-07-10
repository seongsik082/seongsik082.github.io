---
title: "Kafka consumer가 max.poll.interval.ms를 넘기면 중복 처리가 늘어나는 이유"
date: 2026-07-10 09:56:00 +0900
tags: [Kafka, Messaging, Backend]
excerpt: "Kafka consumer는 poll 사이 간격이 max.poll.interval.ms를 넘으면 consumer group에서 실패한 멤버로 취급될 수 있습니다. 긴 처리 시간, 큰 배치, 느린 외부 API가 겹치면 rebalance와 offset commit 실패가 이어져 중복 처리가 늘어납니다."
---

## 문제 상황

Kafka consumer가 평소에는 잘 돌다가 특정 시간대에만 같은 메시지를 다시 처리한다. 로그에는 외부 API timeout, 긴 DB update, offset commit 실패, rebalance 관련 메시지가 섞여 있다. 운영자는 처음에 "Kafka가 메시지를 중복으로 보냈다"고 생각하지만, 실제 원인은 consumer가 poll 이후 너무 오래 애플리케이션 처리에 묶인 경우가 많다.

Kafka consumer는 broker에서 record를 가져오는 `poll()` 호출과 가져온 record를 처리하는 애플리케이션 코드가 한 흐름 안에 놓인다. 처리 시간이 너무 길어져 다음 `poll()` 호출이 늦어지면, consumer group은 이 멤버가 정상적으로 진행하고 있는지 의심한다. 그 결과 partition ownership이 다른 consumer로 넘어가고, 아직 commit되지 않은 offset 범위가 다시 처리될 수 있다.

이 문제는 DLQ나 retry만으로 해결되지 않는다. poison pill처럼 항상 실패하는 메시지가 아니라, "한 번에 너무 많이 가져왔고 처리 경로가 가끔 오래 걸리는" 구조 문제일 수 있기 때문이다.

## 핵심 개념

`max.poll.interval.ms`는 consumer group management를 사용할 때 `poll()` 호출 사이의 최대 허용 간격이다. Apache Kafka의 client 설정 설명에 따르면 이 시간이 지나기 전에 `poll()`이 호출되지 않으면 consumer는 실패한 것으로 간주될 수 있고, group은 partition을 다른 멤버에게 재할당하기 위해 rebalance를 수행한다.

`session.timeout.ms`와 헷갈리기 쉽다. `session.timeout.ms`는 heartbeat가 broker에 도착하지 않을 때 client 실패를 감지하는 시간이다. 반면 `max.poll.interval.ms`는 애플리케이션이 record를 가져간 뒤 다음 poll까지 너무 오래 걸리는지 보는 상한이다. heartbeat thread가 살아 있어도 애플리케이션 처리가 막혀 poll이 늦으면 문제가 생길 수 있다.

static membership을 위해 `group.instance.id`를 설정한 consumer는 `max.poll.interval.ms`에 도달했을 때 partition이 즉시 재할당되지 않고 heartbeat를 멈춘 뒤 session timeout 이후 재할당되는 방식으로 동작할 수 있다. 하지만 이것은 긴 처리 시간을 마음대로 허용해도 된다는 뜻이 아니다. 재시작 때 불필요한 rebalance를 줄이는 데 도움이 될 뿐, offset commit과 처리 시간 설계를 대신하지 않는다.

## 흐름으로 보기

아래 consumer는 한 번에 최대 500개 record를 가져온다.

```properties
enable.auto.commit=false
max.poll.records=500
max.poll.interval.ms=300000
session.timeout.ms=45000
```

처리 코드는 단순해 보인다.

```java
while (true) {
    ConsumerRecords<String, OrderEvent> records = consumer.poll(Duration.ofSeconds(1));

    for (ConsumerRecord<String, OrderEvent> record : records) {
        orderService.apply(record.value());
    }

    consumer.commitSync();
}
```

문제는 `orderService.apply()` 안에 외부 결제 API 호출, DB lock 대기, 느린 재시도가 들어갈 때 생긴다. record 하나가 평균 300ms면 500개 처리는 150초다. 하지만 장애 시간대에 일부 record가 2초씩 걸리면 전체 배치 처리가 1,000초까지 늘 수 있다. 이때 다음 `poll()`은 `max.poll.interval.ms` 300초를 넘긴다.

그 사이 group은 이 consumer를 더 이상 정상 멤버로 보지 않고 rebalance를 시작한다. partition이 다른 consumer에게 넘어간 뒤 원래 consumer가 뒤늦게 `commitSync()`를 호출하면 commit이 실패할 수 있다. 이미 처리한 record의 offset이 저장되지 않았으므로 새 owner가 같은 record를 다시 읽는다. Kafka의 at-least-once 처리에서는 이것이 자연스러운 결과다.

## 자주 하는 실수

첫 번째 실수는 `max.poll.interval.ms`를 크게 늘려서만 해결하려는 것이다. 값을 늘리면 rebalance는 늦춰질 수 있지만, 장애 감지도 늦어진다. 실제로 consumer가 멈췄을 때 partition 재할당이 늦고 lag가 더 오래 쌓인다. 긴 배치 처리를 감추는 방식으로 쓰면 운영자는 문제를 늦게 본다.

두 번째 실수는 `max.poll.records`를 기본값 그대로 두는 것이다. record 하나의 처리 시간이 작아 보여도 batch 단위로 곱하면 poll 간격이 커진다. 외부 API를 호출하거나 DB transaction을 여는 consumer라면 `max.poll.records`를 처리 시간 예산에서 역산해야 한다.

```text
안전한 max.poll.records
= max.poll.interval.ms 안에서 처리 가능한 record 수
- commit, GC, DB lock 대기, 네트워크 지연 여유분
```

세 번째 실수는 offset commit을 처리 성공과 분리하는 것이다. auto commit을 켠 상태에서 긴 처리를 하면 아직 처리하지 않은 record의 offset이 먼저 commit될 수 있고, 반대로 수동 commit이 너무 늦으면 처리 성공 후 commit 실패로 중복이 늘 수 있다. 중요한 처리는 idempotent하게 만들고, commit 위치를 처리 성공 경계에 맞춰야 한다.

네 번째 실수는 rebalance 로그를 소음으로만 보는 것이다. `CommitFailedException`, partition revoked, generation 변경 로그는 처리 지연과 ownership 이동을 알려주는 증거다. 이 로그가 늘어난 시간대의 consumer lag, 외부 API latency, DB lock wait를 함께 봐야 한다.

## 언제 어떻게 조정할까

우선 record 처리 시간을 측정한다. 평균이 아니라 p95, p99를 본다. consumer는 보통 "대부분 빠른데 일부가 매우 느린" 형태로 장애가 난다.

예를 들어 `max.poll.interval.ms=300000`이고 안전 여유를 60초 남기고 싶다면, 한 batch는 240초 안에 처리되어야 한다. record p99 처리 시간이 800ms라면 `max.poll.records=500`은 위험하다. 단순 계산으로도 400초가 필요하다. 이 경우 `max.poll.records`를 줄이거나, record 처리 병렬화를 별도 worker pool로 분리하되 poll thread가 멈추지 않도록 설계해야 한다.

단, worker pool로 분리하면 offset commit이 더 어려워진다. partition별 처리 순서, 실패 record 재시도, 완료 offset 추적이 필요하다. 순서가 중요한 topic이면 같은 partition 안에서 무작정 병렬 처리하면 안 된다. 단순한 서비스라면 먼저 `max.poll.records`를 줄이고 처리 경로를 빠르게 만드는 편이 안전하다.

`group.instance.id`는 rolling restart나 짧은 process 재시작으로 불필요한 rebalance가 잦을 때 고려할 수 있다. 하지만 배포 시스템이 같은 instance id를 동시에 두 개 띄우지 않는지 보장해야 한다. 같은 id가 중복되면 group membership 자체가 꼬인다.

## 운영에서 볼 것

운영 지표는 네 묶음으로 본다.

- consumer lag: partition별 lag가 특정 consumer 처리 시간과 함께 증가하는가
- poll interval: 마지막 poll 이후 경과 시간이 `max.poll.interval.ms`에 가까워지는가
- rebalance 빈도: 배포가 아닌 시간대에 group rebalance가 반복되는가
- commit 실패: `CommitFailedException`, generation 변경, revoked partition 로그가 늘어나는가

애플리케이션 지표도 필요하다. record 처리 시간을 topic, partition, handler type별로 나누어 p95와 p99를 남긴다. 외부 API 호출이 있다면 timeout, retry 횟수, circuit breaker open 여부를 같이 본다. DB 작업이 있다면 lock wait와 transaction duration을 본다.

장애 대응 중에는 consumer 수를 무작정 늘리기 전에 partition 수와 rebalance 비용을 확인해야 한다. consumer 수가 partition 수보다 많으면 놀고 있는 consumer가 생긴다. 반대로 consumer를 자주 scale out/in하면 rebalance가 늘어 처리 중인 batch가 더 자주 끊길 수 있다.

## 정리

`max.poll.interval.ms` 초과는 Kafka가 이상하게 중복을 만든다는 뜻이 아니다. consumer가 record를 가져간 뒤 다음 poll까지 너무 오래 걸렸고, group이 partition을 다시 나누었다는 신호다.

실무에서는 `max.poll.records`, record p99 처리 시간, offset commit 경계, rebalance 로그를 함께 봐야 한다. 핵심 판단 기준은 한 batch가 여유 시간을 포함해 `max.poll.interval.ms` 안에 끝나는지다.

참고한 공식 문서:

- [Apache Kafka ConsumerConfig source](https://github.com/apache/kafka/blob/trunk/clients/src/main/java/org/apache/kafka/clients/consumer/ConsumerConfig.java)
- [Apache Kafka CommonClientConfigs source](https://github.com/apache/kafka/blob/trunk/clients/src/main/java/org/apache/kafka/clients/CommonClientConfigs.java)
