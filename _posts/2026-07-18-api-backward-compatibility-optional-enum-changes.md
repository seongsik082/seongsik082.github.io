---
title: "API 하위 호환성에서 optional field와 enum 변경을 안전하게 다루는 기준"
date: 2026-07-18 08:52:00 +0900
tags: [API, OpenAPI, Architecture, Backend]
excerpt: "API 스키마 변경은 필드 하나를 추가하는 작업처럼 보여도 구버전 client의 요청·응답 해석을 깨뜨릴 수 있습니다. required field, optional field, enum 값, 기본값과 응답 의미를 기준으로 하위 호환 변경과 버전업이 필요한 변경을 나누는 방법을 정리합니다."
---

## 문제 상황

주문 API에 `deliveryMemo` 필드를 추가한 뒤 일부 구버전 모바일 앱에서 응답 파싱 오류가 발생했습니다. 서버는 기존 응답에 필드 하나를 더 넣었을 뿐이라고 생각했지만, client는 예상한 필드만 허용하는 엄격한 역직렬화를 사용하고 있었습니다. 반대로 요청 스키마에 새 필드를 required로 추가했을 때는 업데이트하지 않은 client가 계속 400을 받았습니다.

enum도 자주 문제를 만듭니다. 서버가 `status`에 `ON_HOLD`라는 새 값을 추가했는데, 구버전 client가 알 수 없는 값을 예외로 처리하거나 `default` 분기로 잘못 분류할 수 있습니다. API 호환성은 “JSON이 문법적으로 파싱되는가”만의 문제가 아니라, 기존 client가 요청을 보내고 응답의 의미를 이전과 같이 해석할 수 있는가의 문제입니다.

## 호환성을 세 층으로 나눈다

Google API Improvement Proposal은 호환성을 source, wire, semantic 세 층으로 설명합니다. 백엔드 실무에서는 다음처럼 풀어볼 수 있습니다.

- Source compatibility: client 코드가 새 SDK나 타입 정의에서도 컴파일되고 호출되는가
- Wire compatibility: 기존 client의 HTTP 요청과 응답이 새로운 서버와 통신 가능한가
- Semantic compatibility: 통신은 성공해도 필드의 의미와 기본 동작이 바뀌지 않았는가

OpenAPI의 `required`는 객체의 필수 필드를, `enum`은 허용된 값의 집합을 표현합니다. 실제 client가 알 수 없는 필드와 enum 외 값을 안전하게 처리하는지도 확인해야 합니다.

## 안전한 추가와 위험한 변경

다음과 같은 주문 응답이 있다고 하겠습니다.

```yaml
components:
  schemas:
    Order:
      type: object
      required:
        - id
        - status
      properties:
        id:
          type: string
        status:
          type: string
          enum: [PENDING, PAID, CANCELED]
```

대체로 안전한 변경은 기존 client가 없어도 동작하는 optional response field를 추가하고, 새 request field를 보내지 않았을 때 기존과 같은 기본 동작을 유지하는 것입니다.

```yaml
properties:
  deliveryMemo:
    type: string
    description: 배송 요청 메모. 없으면 메모 없음으로 처리한다.
```

그러나 다음 변경은 버전 안에서 신중하게 다뤄야 합니다.

- 기존 request field를 `required` 목록에 추가합니다.
- 기존 response field를 제거하거나 이름·타입·직렬화 형식을 바꿉니다.
- response enum 값을 제거하거나, 구버전 client가 처리하지 못할 값을 갑자기 추가합니다.
- 값이 없을 때의 기본값이나 빈 문자열·필드 생략의 의미를 바꿉니다.
- 성공 응답을 오류 응답으로 바꾸거나, 같은 status code에서 payload 의미를 바꿉니다.

“response에 필드 추가는 항상 안전하다”라고 단정하면 안 됩니다. 일반적인 JSON client는 모르는 필드를 무시하지만, 엄격한 validator나 generated client는 실패할 수 있습니다. 외부 고객이나 오래된 앱이 있으면 계약 테스트로 확인해야 합니다.

## enum 변경은 수신자 기준으로 판단한다

요청의 enum과 응답의 enum은 위험도가 다를 수 있습니다. 요청을 보내는 client가 새 값을 모르면 서버에 보내지 않으므로, 요청 enum에 값을 추가하는 것 자체는 상대적으로 관리하기 쉽습니다. 하지만 응답 enum은 서버가 새 값을 보내는 순간 모든 client가 그 값을 받게 됩니다.

따라서 응답 enum은 다음처럼 확장 가능성을 문서와 코드에 남기는 편이 좋습니다.

```java
switch (order.status()) {
    case PENDING -> showPending(order);
    case PAID -> showPaid(order);
    case CANCELED -> showCanceled(order);
    default -> showUnknownStatus(order);
}
```

`default`가 있다고 충분한 것은 아닙니다. 알 수 없는 상태를 결제 완료로 오인하지 않고 안전한 화면이나 재조회 흐름으로 보내야 합니다. `unknown enum` 파싱 수와 잘못된 상태 분기를 관찰합니다.

## 변경을 배포하는 순서

첫째, OpenAPI 문서를 먼저 바꾸고 “optional 추가”, “기본값 유지”, “enum 응답 확장”처럼 호환성 분류를 기록합니다.

둘째, 서버가 이전 요청과 새 요청을 동시에 받아들이도록 합니다. 새 필드가 없을 때의 기본값은 기존 동작과 같아야 합니다. 저장이 필요하면 먼저 기본값이 있는 컬럼을 준비하고 client 배포 후 필수화 여부를 판단합니다.

셋째, 구버전·새 client fixture를 같은 API에 보내는 계약 테스트를 실행합니다. 필수 필드, unknown field, enum fallback, 오류 status와 payload를 확인합니다. OpenAPI diff만으로 semantic 변경을 모두 잡을 수는 없습니다.

넷째, 제거는 추가보다 늦게 합니다. deprecation 기간과 client version별 사용량을 확인하고, 캐시·배치·오래된 모바일 앱까지 확인한 뒤 제거합니다.

## 흔한 잘못된 접근과 운영 지표

첫 번째는 모든 변경을 `/v2`로 복사하는 것입니다. 버전업은 endpoint, 문서, 테스트, 보안 정책을 늘립니다. 단순한 optional 추가까지 버전업하면 client가 불필요하게 이동해야 합니다.

두 번째는 문서의 `required`만 보고 호환성을 판정하는 것입니다. optional이어도 기본값이나 응답 의미가 바뀌면 breaking change입니다. client generator 결과도 확인해야 합니다.

운영에서는 endpoint·client version별 4xx 비율, 스키마 검증 실패, unknown enum, deprecated field 사용량을 봅니다. 오류 로그에는 민감한 payload 대신 필드명과 client 버전만 남깁니다.

정리하면 다음과 같습니다.

- 하위 호환성은 파싱 가능 여부뿐 아니라 요청·응답의 의미까지 포함합니다.
- 기존 request에 required field를 추가하거나 response enum을 무계획하게 확장하면 구버전 client가 깨질 수 있습니다.
- optional 추가, 안정적인 기본값, 구버전·신버전 계약 테스트를 통해 변경 범위를 작게 유지합니다.
- 제거와 의미 변경은 deprecation과 사용량 관찰을 거친 뒤 진행하고, 정말 깨지는 변경만 명시적 버전업으로 분리합니다.

## 참고한 공식 문서

- [Google AIP-180 - Backwards compatibility](https://google.aip.dev/180)
- [OpenAPI Specification v3.1.1](https://spec.openapis.org/oas/v3.1.1.html)
