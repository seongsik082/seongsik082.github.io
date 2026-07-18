---
title: "Kafka consumer lag이 커졌을 때 partition hot spot과 처리량을 구분하는 방법"
date: 2026-07-18 08:51:00 +0900
tags: [Kafka, Messaging, Observability, Backend]
excerpt: "Kafka consumer lag이 커졌다고 consumer 인스턴스부터 늘리면 해결되지 않을 수 있습니다. 파티션별 lag 분포, key 편중, poll 간격, 처리량, rebalance를 함께 확인해 partition hot spot과 전체 처리 용량 부족을 구분하는 방법을 정리합니다."
---

## 문제 상황

주문 이벤트를 처리하는 Kafka consumer group의 lag이 계속 증가합니다. 운영자는 consumer Pod를 두 배로 늘렸지만 lag은 거의 줄지 않았고, 일부 인스턴스에서는 rebalance 로그까지 반복됩니다. 전체 lag 숫자만 보면 소비자가 느린 것 같지만, 실제 원인은 특정 파티션 하나에 메시지가 몰린 것일 수 있습니다.

Kafka에서 consumer를 늘리는 일이 항상 처리량을 늘려 주지는 않습니다. consumer group에서는 한 파티션이 한 시점에 한 consumer에게 할당되고, 파티션 안의 메시지는 순서를 유지하며 처리됩니다. 토픽의 파티션 수보다 consumer가 많으면 남는 consumer는 할 일이 없습니다. 반대로 파티션 수가 충분해도 특정 key가 한 파티션에 몰리면 그 파티션이 전체 처리 속도의 상한이 됩니다.

## lag은 하나의 숫자가 아니다

파티션별 lag은 보통 log end offset과 consumer group의 committed offset 사이의 차이로 볼 수 있습니다. 전체 lag을 합산하면 현재 쌓인 양은 알 수 있지만, 어디가 막혔는지는 숨겨집니다.

```bash
kafka-consumer-groups.sh \
  --bootstrap-server kafka-1:9092 \
  --describe \
  --group order-worker
```

출력이 다음과 같다고 가정해 보겠습니다.

```text
TOPIC   PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  CONSUMER-ID
orders  0          120000          120100          100  worker-1
orders  1          118900          118950           50  worker-2
orders  2          98500           198500       100000  worker-3
orders  3          121200          121260           60  worker-4
```

전체 lag은 100,210이지만 문제는 partition 2에 집중되어 있습니다. consumer를 추가해도 한 파티션을 동시에 두 consumer가 읽을 수는 없습니다. producer의 partition key가 특정 값으로 편중되었는지 먼저 확인해야 합니다.

## 두 가지 장애를 분리한다

### 1. 특정 파티션만 느린 경우

한두 파티션의 `records-lag-max`가 계속 커지고 다른 파티션은 안정적이면 key skew를 의심합니다. producer가 동일한 key를 사용하면 같은 key의 이벤트 순서를 지키기 위해 같은 파티션으로 보내는 것이 일반적입니다. 이 선택은 순서를 얻는 대신 병렬성을 포기하는 trade-off를 만듭니다.

해결책은 무조건 key를 없애는 것이 아닙니다. 주문별 순서가 필요한지, 고객별 순서면 충분한지 먼저 정합니다. 순서 범위를 줄일 수 있다면 key 분포를 넓히고 파티션 수를 늘릴 수 있지만, 기존 이벤트 순서와 downstream 저장 방식의 영향은 테스트해야 합니다.

### 2. 모든 파티션이 함께 느린 경우

모든 파티션의 lag이 함께 증가하면 producer 유입률이 consumer 처리량을 앞설 가능성이 큽니다. DB·외부 API 지연, CPU, 스레드 풀, 배치 크기와 `records-consumed-rate`를 확인합니다.

consumer가 `poll()`을 늦게 호출하면 처리 속도와 별개로 rebalance가 발생할 수 있습니다. `max.poll.interval.ms`를 넘기면 consumer가 실패한 것으로 간주될 수 있고, `max.poll.records`가 크면 한 번의 처리 시간이 길어집니다.

## 운영 지표를 같이 읽는 법

Kafka 공식 모니터링 문서의 consumer 지표를 다음 순서로 묶어 보는 편이 좋습니다.

- `records-lag-max`, 파티션별 `records-lag`: 특정 파티션에 적체가 몰렸는지 확인합니다.
- `records-consumed-rate`: consumer가 실제로 읽고 처리하는 속도를 봅니다.
- `assigned-partitions`: 인스턴스별 할당 수가 불균형하거나 파티션 수가 consumer 수보다 적은지 확인합니다.
- `time-between-poll-max`, `last-poll-seconds-ago`: 애플리케이션 처리 때문에 poll이 늦어지는지 확인합니다.
- rebalance rate와 commit latency: 소비자 장애, 긴 처리, coordinator 문제로 재할당이 반복되는지 확인합니다.

`records-consumed-rate`는 정상인데 특정 파티션 lag만 늘면 key 편중을 먼저 봅니다. 모든 rate가 떨어지고 `time-between-poll-max`가 커지면 처리 경로를, lag과 rebalance가 함께 튀면 처리 시간·재시작·poll 간격을 봅니다.

## 흔한 잘못된 해결

첫 번째는 lag 총합만 알림으로 거는 것입니다. 전체 lag, 최대 파티션 lag, lag 증가율을 분리해야 hot spot을 놓치지 않습니다.

두 번째는 consumer 수를 파티션 수보다 많이 늘리는 것입니다. 유휴 consumer와 rebalance 비용만 늘 수 있으므로 파티션 수, 처리 시간, downstream 한도를 함께 봅니다.

세 번째는 `max.poll.interval.ms`만 크게 늘리는 것입니다. rebalance를 늦출 뿐 처리량은 늘리지 않습니다. 배치 크기와 처리·poll 분리 여부를 먼저 설계하고, 비동기화는 순서 요구와 함께 검토해야 합니다.

## 적용 기준과 장애 대응 체크리스트

장애가 발생하면 다음 순서로 확인합니다.

1. consumer group을 describe해 전체 lag이 아니라 파티션별 lag을 확인합니다.
2. lag이 한 파티션에 몰렸는지, 모든 파티션에 고르게 증가하는지 나눕니다.
3. 해당 파티션의 key 분포와 최근 producer 트래픽을 비교합니다.
4. `records-consumed-rate`, 처리 시간, DB·외부 API 지연을 확인합니다.
5. `last-poll-seconds-ago`와 rebalance가 함께 증가했는지 확인합니다.
6. consumer를 늘리거나 파티션을 변경하기 전에 순서 보장과 downstream 동시성 한도를 검토합니다.

정리하면 다음과 같습니다.

- consumer lag은 총합보다 파티션별 분포를 먼저 봐야 합니다.
- 한 파티션의 hot spot은 consumer 수만 늘려서 해결되지 않습니다.
- 모든 파티션이 느리면 처리량과 downstream 병목을 측정해야 합니다.
- `max.poll.interval.ms` 조정은 rebalance를 줄일 수 있지만 실제 처리 용량 증가는 아닙니다.

## 참고한 공식 문서

- [Apache Kafka 4.3 - Monitoring](https://kafka.apache.org/43/operations/monitoring/)
- [Apache Kafka 4.2 - Consumer Configs](https://kafka.apache.org/42/configuration/consumer-configs/)
- [Apache Kafka - Basic Operations and consumer group offsets](https://kafka.apache.org/10/operations/basic-kafka-operations/)
