---
title: "Kafka 이벤트 스키마 호환성은 필드 추가보다 consumer 배포 순서가 더 중요하다"
date: 2026-07-15 08:51:00 +0900
tags: [Kafka, Messaging, Event, Backend]
excerpt: "Kafka 토픽은 메시지를 오래 보관하므로 스키마 변경의 핵심은 새 코드가 컴파일되는지가 아니라 과거 이벤트와 구버전 consumer를 읽을 수 있는지입니다. backward·forward·full·transitive 호환성의 의미와 producer·consumer 배포 순서를 실무 기준으로 정리합니다."
---

## 문제 상황

Kafka 이벤트는 HTTP 응답처럼 전달 즉시 사라지지 않습니다. 토픽 보존 기간 동안 과거 이벤트를 다시 읽을 수 있고, 같은 이벤트를 여러 팀의 consumer가 서로 다른 배포 속도로 처리합니다. 그래서 producer의 DTO에 필드 하나를 추가하는 작업도 모든 consumer가 동시에 배포된다는 가정 위에서 진행할 수 없습니다.

개발 환경에서는 새 producer와 새 consumer만 함께 실행해 문제가 없어 보이지만, 운영에서는 구버전 consumer와 새 producer, 장애 복구를 위해 과거 offset을 읽는 consumer가 동시에 존재합니다. “필드는 추가만 했으니 안전하다”가 아니라 새 필드의 기본값, 읽기 방향, 스키마 검사 범위를 확인해야 합니다.

## 호환성의 방향을 먼저 정의한다

Schema Registry에서 호환성은 스키마가 예쁘게 생겼는지가 아니라 writer와 reader가 서로 다른 버전을 만났을 때 읽을 수 있는지를 설명합니다.

- Backward: 새 스키마를 사용하는 consumer가 이전 스키마로 기록된 데이터를 읽을 수 있습니다.
- Forward: 이전 스키마를 사용하는 consumer가 새 스키마로 기록된 데이터를 읽을 수 있습니다.
- Full: 두 방향을 모두 만족합니다.
- Transitive: 바로 직전 버전만이 아니라 등록된 모든 이전 버전과 비교합니다.

Confluent Schema Registry의 기본 호환성은 BACKWARD이며, 기본값은 transitive가 아닙니다. 즉 새 스키마가 직전 스키마와 호환되는지만 통과하고, 오래된 모든 버전과의 호환성까지 자동으로 보장하지는 않습니다. 토픽을 처음부터 다시 읽을 가능성이 있거나 오랫동안 남아 있는 이벤트를 처리해야 한다면 BACKWARD_TRANSITIVE를 선택할 이유가 생깁니다.

Avro를 예로 들면 기존 이벤트에 없던 필드를 새 스키마에 추가할 때 기본값을 함께 두어야 과거 데이터의 누락 필드를 채울 수 있습니다.

    {
      "type": "record",
      "name": "OrderCreated",
      "fields": [
        {"name": "orderId", "type": "string"},
        {"name": "totalAmount", "type": "long"},
        {"name": "currency", "type": "string", "default": "KRW"}
      ]
    }

새 consumer가 과거 이벤트를 읽을 때 currency가 없으면 기본값을 사용하므로 backward 호환이 될 수 있습니다. 반대로 기존 필드의 타입을 long에서 string으로 바꾸거나, 기본값이 없는 필수 필드를 추가하면 단순한 필드 추가가 아니라 호환성을 깨는 변경이 됩니다. JSON Schema와 Protobuf는 세부 규칙이 다르므로 Avro의 예시를 모든 포맷에 그대로 적용해서는 안 됩니다.

## 배포 순서는 호환성 모드가 결정한다

BACKWARD 또는 BACKWARD_TRANSITIVE라면 새 consumer가 과거 이벤트를 읽을 수 있다는 뜻이지, 구버전 consumer가 새 이벤트를 반드시 읽을 수 있다는 뜻은 아닙니다. 따라서 일반적인 순서는 consumer를 먼저 배포하고, 모든 중요한 consumer가 새 스키마를 읽을 준비가 된 뒤 producer가 새 필드를 기록하도록 바꾸는 것입니다.

실제 배포 흐름은 다음처럼 나눌 수 있습니다.

1. 새 스키마를 Registry에 호환성 검사와 함께 등록합니다.
2. 새 필드를 읽되 값이 없을 때의 동작을 정의한 consumer를 배포합니다.
3. consumer 인스턴스가 모두 새 버전인지 확인하고, lag과 역직렬화 오류를 관찰합니다.
4. producer가 새 필드를 기록하기 시작합니다.
5. 구버전 이벤트 재처리, 특정 partition rewind, DLQ 재주입을 작은 범위에서 시험합니다.

FULL 또는 FULL_TRANSITIVE라면 구버전 consumer가 새 이벤트를 읽고 새 consumer가 과거 이벤트를 읽는 양방향 조건을 만족할 수 있으므로 producer와 consumer를 독립적으로 배포하기 쉬워집니다. 그러나 FULL이 항상 모든 의미 변경을 막아주는 것은 아닙니다. 예를 들어 totalAmount의 단위가 원에서 센트로 바뀌어도 타입이 long으로 같다면 Registry가 알아내지 못할 수 있습니다.

호환성 검사와 의미 검사는 서로 다른 층입니다. Registry는 필드 존재, 타입, 기본값 같은 구조를 확인하지만 “이 값의 단위가 무엇인가”, “상태 값의 의미가 바뀌었는가”, “이벤트가 한 번만 발행되는가”까지 보장하지 않습니다. 이벤트 문서와 contract test가 필요한 이유입니다.

## 자주 발생하는 장애 패턴

첫 번째는 새 필드를 필수로 추가한 뒤 구버전 이벤트를 재처리하는 경우입니다. 실시간에서는 지나가도 earliest offset이나 장애 복구에서 역직렬화 예외가 납니다. 두 번째는 검사 실패를 해결하는 대신 호환성 모드를 NONE으로 바꾸는 경우입니다. 정말로 incompatible change가 필요하면 새 topic과 subject를 병행하고 이전 topic의 종료 조건을 정해야 합니다. 세 번째는 schema id와 파싱은 정상인데 단위나 상태 의미가 바뀌는 경우입니다. producer별 샘플과 필드 허용 범위가 필요합니다.

Kafka Streams는 input topic뿐 아니라 상태 저장소와 changelog의 과거 데이터도 읽을 수 있으므로 일반 consumer와 같은 재처리 테스트만으로 충분하지 않습니다.

## 적용 기준과 운영 체크리스트

필드 추가·삭제·기본값 변경을 자주 한다면 subject별 호환성 정책을 코드 저장소에서 관리하고 CI에서 실제 Registry 호환성 API를 호출합니다. 단위 테스트만으로는 포맷별 규칙과 transitive 비교를 충분히 재현하기 어렵습니다.

배포 중에는 다음 지표를 함께 봅니다.

- consumer별 records-lag-max와 lag 증가율
- 역직렬화 예외, schema not found, incompatible schema 오류 수
- DLQ 유입량과 재처리 성공률
- producer별 새 schema id 사용 비율
- replay 또는 backfill 작업에서 오래된 버전 이벤트 처리 시간

새 스키마가 호환된다고 해서 필드 삭제를 즉시 해도 되는 것은 아닙니다. 실제로 모든 consumer가 해당 필드를 더 이상 사용하지 않는지, 대시보드·데이터레이크·배치가 그 필드에 의존하지 않는지 확인한 뒤 여러 버전에 걸쳐 폐기해야 합니다. 반대로 계약을 완전히 바꾸어야 한다면 기존 이벤트를 억지로 다중 해석하기보다 새 topic으로 명확히 분리하는 것이 장기 운영 비용을 낮출 수 있습니다.

정리하면 다음과 같습니다.

- Kafka 이벤트는 과거 데이터와 여러 버전의 consumer가 공존하므로 스키마 변경을 동시 배포 문제로 보면 안 됩니다.
- BACKWARD는 새 consumer가 과거 이벤트를 읽는 방향이며, 기본 설정의 non-transitive 특성을 확인해야 합니다.
- 일반적인 안전한 순서는 consumer 배포 후 producer 전환이며, FULL 계열은 독립 배포의 선택지를 넓힙니다.
- 구조적 호환성 검사는 의미 변경, 단위 변경, 중복 발행과 정합성까지 대신 검증하지 않습니다.

## 참고한 공식 문서

- [Confluent Schema Evolution and Compatibility](https://docs.confluent.io/platform/current/schema-registry/fundamentals/schema-evolution.html)
- [Confluent Schema Registry schema management](https://docs.confluent.io/platform/current/schema-registry/schema.html)
