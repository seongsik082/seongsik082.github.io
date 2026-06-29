---
title: "Outbox pattern을 도입해야 하는 시점과 미루어도 되는 시점"
date: 2026-06-30 00:43:00 +0900
tags: [Distributed Systems, Architecture, Backend]
excerpt: "Outbox pattern은 만능 패턴이 아니라, DB 저장과 이벤트 발행의 불일치가 실제 장애로 이어질 때 도입 가치가 커집니다."
---

## 문제 상황

서비스가 단순 CRUD 단계에 있을 때는 DB에 저장하고 바로 메시지를 발행하는 코드가 크게 문제 없어 보입니다. 그런데 주문 생성, 결제 완료, 회원 상태 변경처럼 "DB 저장"과 "이벤트 발행"이 동시에 맞아야 하는 흐름이 생기면 이야기가 달라집니다. DB는 성공했는데 이벤트 발행이 실패하면 다운스트림은 변경 사실을 모릅니다. 반대로 DB는 롤백됐는데 이벤트만 나가면 더 위험합니다.

이 문제를 보통 dual write 문제라고 부릅니다. 한 요청 안에서 서로 다른 두 시스템에 쓰기를 해야 하는데, 둘 다 원자적으로 맞추기 어렵기 때문에 생깁니다. 운영에서 보이는 증상은 "가끔만 틀린다"는 점입니다. 그래서 더 늦게 발견되고, 재현도 어렵습니다.

Outbox pattern은 이 순간에 등장합니다. 하지만 모든 서비스에 무조건 넣는 것이 정답은 아닙니다. 테이블 하나 더 만들고, 발행 워커를 두고, 중복 처리와 순서 보장까지 고민해야 하므로 운영 복잡도가 분명히 올라갑니다. 그래서 "언제 도입해야 하는가"가 핵심입니다.

## 핵심 개념

AWS Prescriptive Guidance는 transactional outbox pattern을, 데이터베이스 업데이트와 메시지 또는 이벤트 알림이 함께 필요한 상황에서 dual write 문제를 해결하는 방식으로 설명합니다. 핵심은 비즈니스 테이블과 outbox 테이블을 **같은 트랜잭션** 안에서 저장하는 것입니다. 그러면 DB 저장은 성공했는데 outbox 기록이 없는 상태, 혹은 outbox는 있는데 비즈니스 저장이 실패한 상태를 줄일 수 있습니다.

이후 별도 프로세스가 outbox 테이블을 읽어 메시지 브로커로 보냅니다. 이 구조에서는 "메시지를 언제 보냈는가"보다 "커밋된 변경만 안전하게 발행하는가"가 더 중요합니다. AWS 문서도 duplicate message 가능성을 언급하면서, 소비자 쪽 idempotency를 함께 설계하라고 권장합니다.

또 하나 놓치기 쉬운 부분은 순서입니다. 이벤트 순서가 중요한 도메인이라면 outbox 레코드에 timestamp나 sequence를 두고, 같은 순서대로 발행되게 해야 합니다. 그렇지 않으면 데이터는 eventually consistent하더라도, 다운스트림이 더 오래 흔들립니다.

## 코드로 보기

가장 단순한 형태는 아래와 같습니다.

```sql
create table orders (
  id bigint primary key,
  status varchar(30) not null
);

create table order_outbox (
  id bigint primary key,
  aggregate_id bigint not null,
  event_type varchar(50) not null,
  payload json not null,
  created_at timestamp not null
);
```

애플리케이션에서는 주문 저장과 outbox 저장을 한 트랜잭션으로 묶습니다.

```java
@Transactional
public void createOrder(CreateOrderCommand command) {
    Order order = orderRepository.save(Order.create(command));
    outboxRepository.save(OutboxEvent.orderCreated(order));
}
```

그 다음 별도 발행기가 주기적으로 읽어 브로커에 보냅니다.

```java
@Scheduled(fixedDelay = 1000)
public void publishOutbox() {
    List<OutboxEvent> events = outboxRepository.findReadyEvents();
    for (OutboxEvent event : events) {
        messageBroker.publish(event);
        outboxRepository.markPublished(event.getId());
    }
}
```

실무에서는 `publish -> delete`보다 `publish -> published_at 기록`처럼 상태를 남기는 편이 보통 더 안전합니다. 실패 조사와 재처리가 쉬워지기 때문입니다.

## 자주 하는 실수

첫 번째 실수는 outbox를 넣었으니 정확히 한 번만 전달된다고 기대하는 것입니다. AWS 문서도 중복 메시지 가능성을 분명히 언급합니다. 따라서 소비자에서 이미 처리한 메시지를 구분할 수 있어야 합니다. outbox는 dual write를 줄여주지만, 중복 소비까지 자동으로 없애주지는 않습니다.

두 번째 실수는 실제로는 정합성 요구가 낮은데도 일찍 도입하는 것입니다. 예를 들어 실패해도 수동 재처리가 쉽고, 이벤트 누락이 큰 비즈니스 손실로 이어지지 않는 내부 알림 정도라면 outbox보다 간단한 재시도/보정 배치가 더 현실적일 수 있습니다.

세 번째 실수는 발행 워커를 만들고 모니터링을 안 붙이는 것입니다. outbox는 테이블이 쌓이기 시작하면 장애가 바로 보이지 않을 수 있습니다. 큐 적체처럼 outbox 적체도 별도 경보가 필요합니다.

## 언제 쓰면 좋은가

도입 가치가 큰 경우는 아래와 같습니다.

- DB 저장과 이벤트 발행 불일치가 금전, 주문, 권한 같은 실제 장애로 이어질 때
- 이벤트 누락을 사람이 나중에 수습하기 어려울 때
- 이미 이벤트 기반 아키텍처가 있고, 다운스트림 의존성이 커졌을 때

반대로 미뤄도 되는 경우는 아래에 가깝습니다.

- 이벤트 실패를 재실행 배치로 쉽게 복구할 수 있을 때
- 다운스트림이 핵심 흐름이 아니라 부가 기능일 때
- 아직 단일 서비스 단계라 운영 복잡도 증가가 더 큰 비용일 때

실무 판단 기준을 하나만 고르면 이렇습니다. "이벤트 한 건 누락이 운영자가 수동으로 메울 수 없는 비즈니스 불일치로 번지는가?" 이 질문에 자주 "그렇다"가 나오면 outbox 도입을 진지하게 검토할 시점입니다.

## 운영에서 볼 것

- outbox 테이블 미발행 건수
- 가장 오래된 미발행 레코드의 age
- 발행 성공률과 재시도 횟수
- 소비자 쪽 중복 처리 건수
- 같은 aggregate에 대한 이벤트 순서가 뒤바뀐 사례

로그에는 최소한 아래 정보가 있으면 좋습니다.

- outbox event id
- aggregate id
- event type
- publish attempt 수
- published_at 또는 failure reason

이 정보가 있어야 "이벤트가 왜 안 갔는지"와 "갔는데 소비가 안 됐는지"를 분리해서 볼 수 있습니다.

## 정리

Outbox pattern은 패턴 자체가 목적이 아니라, DB 저장과 이벤트 발행의 불일치를 줄이기 위한 운영 장치입니다. 정합성 요구가 높은 흐름에서 특히 가치가 크지만, 그만큼 발행기, 적체 모니터링, 중복 소비 대응까지 함께 가져와야 합니다. 도입 여부는 멋있는 아키텍처 여부보다, 이벤트 누락이 실제로 얼마나 큰 장애가 되는지로 판단하는 편이 맞습니다.

## 참고한 공식 문서

- AWS Prescriptive Guidance, Transactional outbox pattern: https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/transactional-outbox.html
