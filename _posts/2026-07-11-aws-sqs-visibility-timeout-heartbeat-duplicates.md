---
title: "SQS visibility timeout을 늘려도 중복 처리가 사라지지 않는 이유"
date: 2026-07-11 08:52:00 +0900
tags: [AWS, SQS, Messaging, Distributed Systems, Backend]
excerpt: "Amazon SQS visibility timeout은 처리 중인 메시지를 잠시 숨기는 시간이지 exactly-once 처리 보장이 아닙니다. 처리 시간에 맞춘 timeout, heartbeat 연장, 삭제 시점, idempotency와 DLQ를 함께 설계해야 중복 처리와 재시도 지연을 줄일 수 있습니다."
---

## 문제 상황

주문 생성 이벤트를 SQS에서 받아 결제 예약을 만드는 워커가 있다고 하자. 한 건을 처리하는 데 평소 8초가 걸려 queue의 visibility timeout을 30초로 설정했다. 그런데 외부 결제사 지연과 DB lock 경합이 겹친 날에는 처리 시간이 35초를 넘고, 같은 메시지가 다른 워커에 다시 보이기 시작한다.

운영자는 timeout을 10분으로 늘리면 중복이 해결될 것이라고 생각할 수 있다. 하지만 이렇게 하면 실제 장애가 발생했을 때 실패한 메시지가 다시 나타나기까지 10분을 기다려야 한다. 반대로 timeout을 너무 짧게 두면 첫 번째 워커가 아직 작업 중인데 두 번째 워커가 같은 메시지를 가져가 결제를 두 번 시도할 수 있다.

SQS의 핵심은 메시지를 받았다고 해서 삭제된 것이 아니라는 점이다. `ReceiveMessage` 이후 메시지는 큐에 남아 있지만 일정 시간 다른 consumer에게 보이지 않을 뿐이다. 성공적으로 처리한 뒤 `DeleteMessage`를 호출해야 해당 전달이 끝난다. 이 구조는 장애가 나도 메시지를 잃지 않게 해 주지만, 네트워크 단절이나 처리 시간 초과에 따른 중복 가능성도 애플리케이션이 감당해야 한다.

## 핵심 개념

visibility timeout은 메시지가 consumer에게 전달된 순간 시작된다. 기본 queue 설정은 30초이며, queue 전체의 기본값과 개별 메시지의 timeout을 다르게 설정할 수 있다. timeout이 끝나기 전에 삭제하지 않으면 메시지는 다시 visible 상태가 되어 같은 consumer나 다른 consumer가 다시 받을 수 있다.

중요한 점은 visibility timeout이 at-least-once delivery를 exactly-once 처리로 바꿔 주지 않는다는 것이다. AWS 문서도 timeout 동안에도 메시지가 한 번 이상 전달될 가능성을 절대적으로 제거하지 않는다고 설명한다. 따라서 timeout을 충분히 길게 잡는 것은 “정상 처리 중인 메시지가 너무 빨리 재등장하는 문제”를 줄이는 조정이지, 부작용 없는 단 한 번의 실행을 보장하는 장치가 아니다.

처리 시간의 분포가 비교적 일정하면 최대 정상 처리 시간과 삭제 API 호출에 필요한 여유를 포함해 timeout을 정한다. 처리 시간이 크게 흔들리면 처음부터 아주 긴 timeout을 넣기보다, 짧은 초기 timeout으로 시작하고 작업이 계속 살아 있음을 heartbeat로 알리면서 개별 메시지의 timeout을 연장한다. SQS visibility timeout은 최초 수신 시점부터 최대 12시간이라는 상한이 있으므로, 그보다 긴 작업은 작은 단계로 나누거나 Step Functions 같은 장기 실행 흐름으로 분리해야 한다.

## 코드 흐름으로 보기

워커의 성공·실패 경계를 먼저 명확히 한다.

```text
ReceiveMessage
  -> 처리 상태를 idempotency 저장소에 기록하거나 확인
  -> 비즈니스 작업 수행
  -> 성공한 경우에만 DeleteMessage
  -> 처리 중이라면 ChangeMessageVisibility로 연장
  -> 재시도 가능한 실패는 삭제하지 않고 timeout 만료를 기다림
```

AWS SDK를 사용하는 워커의 의사 코드는 다음과 같은 형태가 된다.

```java
Message message = receiveMessage();
String token = message.messageId();

try {
    // 처리 시간이 길면 주기적으로 heartbeat를 실행한다.
    scheduleVisibilityHeartbeat(message.receiptHandle());

    if (idempotencyStore.alreadyCompleted(token)) {
        deleteMessage(message.receiptHandle());
        return;
    }

    processOrder(message.body());
    idempotencyStore.markCompleted(token);
    deleteMessage(message.receiptHandle());
} catch (RetryableException e) {
    // 삭제하지 않는다. visibility timeout 뒤 다시 처리한다.
    recordFailure(token, e);
} catch (PermanentException e) {
    // 재시도 횟수와 DLQ 정책에 따라 삭제 또는 별도 격리를 선택한다.
    recordFailure(token, e);
}
```

여기서 `messageId`를 그대로 idempotency key로 쓸 수 있는지는 producer와 재발행 흐름에 달려 있다. 같은 비즈니스 주문이 producer 재시도로 새 메시지 ID를 가질 수 있다면 `orderId + eventVersion`처럼 비즈니스 중복을 식별할 수 있는 키를 함께 사용해야 한다. 결제 예약 같은 부작용은 DB unique constraint, 결제사 idempotency key, 처리 이력 테이블 중 하나 이상으로 중복 실행을 막는 편이 안전하다.

heartbeat는 작업이 정상적으로 진행 중일 때만 실행해야 한다. 작업 스레드가 멈췄는데 별도 heartbeat가 계속 timeout을 연장하면 메시지가 장시간 보이지 않아 장애 복구가 늦어진다. heartbeat 실패를 작업 실패로 취급하고, 처리 완료와 삭제 사이에 프로세스가 죽어도 재전달된 메시지를 안전하게 다시 확인할 수 있어야 한다.

## 자주 하는 실수

첫 번째 실수는 timeout을 평균 처리 시간만 보고 정하는 것이다. 평균이 8초여도 p99가 40초라면 10초 timeout은 긴 꼬리 구간에서 중복을 만든다. 평균, p95, p99, DB 대기, 외부 API timeout, DeleteMessage 지연을 함께 보고 정상 처리의 상한을 잡아야 한다.

두 번째 실수는 작업이 성공하기 전에 메시지를 삭제하는 것이다. 삭제를 먼저 호출하면 이후 DB commit이나 외부 API 호출이 실패했을 때 SQS는 메시지를 다시 주지 않는다. 반대로 작업 성공 후 삭제가 실패하면 중복 전달이 생길 수 있으므로, 성공 작업을 idempotent하게 만들고 삭제 실패를 관측해야 한다.

세 번째 실수는 모든 실패를 같은 방식으로 재시도하는 것이다. JSON 형식 오류, 필수 필드 누락, 지원하지 않는 이벤트 버전은 계속 재시도해도 성공하지 않는 poison message일 수 있다. 이런 메시지는 DLQ로 보내고 원본 payload, 오류 분류, receive count, 코드 버전을 남겨야 한다. 일시적인 네트워크 오류와 영구적인 데이터 오류의 재시도 정책은 달라야 한다.

네 번째 실수는 visibility timeout을 무조건 길게 만드는 것이다. timeout이 길면 메시지가 실패한 뒤 다시 나타나는 시간이 길어지고, 처리 중인 in-flight 메시지가 많이 쌓인다. Standard queue는 in-flight 메시지 수가 대략 120,000 수준의 제한에 영향을 받을 수 있고, long polling에서는 한도에 도달해도 새 메시지가 오지 않는 형태로 보일 수 있다. 처리 완료 후 즉시 삭제하는 것이 throughput에도 중요하다.

다섯 번째 실수는 FIFO를 사용하면 비즈니스 작업도 중복되지 않는다고 생각하는 것이다. FIFO의 deduplication은 정해진 중복 제거 조건과 시간 범위 안에서 중복 메시지 발행을 줄이는 기능이다. consumer가 같은 메시지를 다시 처리하는 상황, 외부 side effect가 두 번 호출되는 상황, timeout 만료 뒤 재전달되는 상황까지 모두 없애 주지는 않는다. FIFO의 MessageGroupId로 순서를 설계하더라도 consumer 작업은 여전히 idempotent해야 한다.

## 언제 쓰면 좋은가

SQS visibility timeout은 처리 시간이 수초에서 수분이고, 실패한 메시지를 나중에 재시도해도 되는 비동기 작업에 적합하다. 이미지 변환, 이메일 발송, 주문 후속 처리처럼 요청 응답과 작업을 분리하고, consumer 장애 때 메시지를 다시 받을 수 있어야 하는 흐름에 잘 맞는다.

판단 기준은 “작업 실패 뒤 얼마나 빨리 재시도해야 하는가”와 “정상 작업이 끝나는 데 얼마나 오래 걸리는가”를 함께 보는 것이다. 정상 p99 처리 시간이 25초이고 장애 시 재시도가 1분 안에 필요하다면 5분 timeout을 고정하기보다 40~60초 초기 timeout과 heartbeat를 검토한다. 반대로 작업이 항상 2초 안에 끝나고 실패를 빨리 재처리해야 한다면 30초 기본값을 그대로 두기보다 실제 분포에 맞춘 더 짧은 값을 검토할 수 있다.

작업이 12시간 이상 걸리거나 중간 진행 상태를 잃으면 안 되는 경우에는 SQS 한 메시지를 오래 숨기는 방식이 적합하지 않다. 작업을 여러 단계의 메시지로 나누고 각 단계의 완료 상태를 저장하거나, 장기 실행 오케스트레이션으로 옮기는 편이 장애 복구와 운영 알림을 설계하기 쉽다.

## 운영에서 볼 것

큐 대시보드에는 대기 메시지 수뿐 아니라 in-flight 메시지 수, 오래된 메시지의 age, receive count, 처리 성공·실패 수, DeleteMessage 실패 수를 함께 둔다. 대기 메시지는 줄어드는데 in-flight가 계속 증가하면 consumer가 받기는 하지만 처리 완료와 삭제를 못 하고 있을 가능성이 크다. 반대로 age와 receive count가 같이 늘면 timeout 만료에 따른 재처리나 poison message를 의심한다.

CloudWatch의 `ApproximateNumberOfMessagesVisible`와 `ApproximateNumberOfMessagesNotVisible`를 나눠 보자. 전자는 아직 받지 않은 대기량이고, 후자는 받았지만 삭제되지 않은 in-flight에 가까운 신호다. 둘을 합쳐 보지 않으면 consumer가 메시지를 처리하고 있는지, 단지 숨겨 두고 멈춰 있는지 구분하기 어렵다.

애플리케이션 로그에는 메시지 ID만 남기지 말고 비즈니스 키, receive attempt, visibility deadline, processing duration, 삭제 결과를 기록한다.

```text
sqs.receive queue=order-events businessKey=order-42 attempt=1 deadline=09:00:30
sqs.visibility_extend businessKey=order-42 elapsedMs=25000 nextTimeoutSec=30
order.process success businessKey=order-42 durationMs=41000
sqs.delete failed businessKey=order-42 error=TimeoutException
sqs.receive queue=order-events businessKey=order-42 attempt=2
idempotency.skip businessKey=order-42 reason=already_completed
```

장애 대응 순서는 단순하게 가져간다. 첫째, 처리 p99와 현재 visibility timeout을 비교한다. 둘째, heartbeat가 실제 작업 생존 여부와 연결되어 있는지 확인한다. 셋째, 삭제 실패 뒤 중복 실행을 막는 idempotency 저장소가 작동했는지 본다. 넷째, receive count가 높은 메시지와 DLQ를 분리해 영구 오류인지 일시 오류인지 판단한다.

timeout 값을 변경할 때는 queue 전체 기본값만 바꾸지 말고 consumer의 처리 시간, 동시성, in-flight 한도, 재시도 지연을 함께 부하 테스트한다. consumer 수를 늘리면서 각 작업 시간이 길어지면 in-flight가 먼저 한도에 가까워질 수 있다. 운영 목표는 “중복을 0으로 만들기”가 아니라, 중복이 발생해도 부작용 없이 완료되고 실패 메시지가 예측 가능한 시간 안에 복구되는 구조를 만드는 것이다.

## 정리

visibility timeout은 메시지를 잠시 숨기는 시간이지 exactly-once 처리 보장이 아니다.
처리 시간이 길거나 흔들리면 개별 메시지 timeout을 heartbeat로 연장하되 작업 생존과 묶어야 한다.
성공 후 삭제, 재시도 가능한 실패, 영구 실패와 DLQ를 서로 다른 경로로 설계하자.
운영에서는 visible·in-flight·message age·receive count·삭제 실패와 idempotency 결과를 함께 본다.

## 참고한 공식 문서

- [Amazon SQS visibility timeout](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-visibility-timeout.html)
- [Processing messages in a timely manner in Amazon SQS](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/best-practices-processing-messages-timely-manner.html)
- [Preventing duplicate processing in a multiple-producer/consumer system](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/avoding-processing-duplicates-in-multiple-producer-consumer-system.html)
