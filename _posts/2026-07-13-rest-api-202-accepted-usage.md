---
title: "REST API에서 202 Accepted를 써야 하는 작업과 아닌 작업"
date: 2026-07-13 08:50:00 +0900
tags: [REST API, HTTP, Distributed Systems, Backend]
excerpt: "HTTP 202 Accepted는 작업이 끝났다는 응답이 아니라 처리를 접수했다는 약속입니다. 상태 조회 URL, 작업 상태 모델, 재시도와 만료 정책을 함께 설계하지 않으면 클라이언트는 성공과 중복을 구분하지 못합니다."
---

## 문제 상황

대용량 보고서 생성 API가 있습니다. 요청을 받으면 데이터를 모으고 파일을 만들기까지 30초가 걸립니다. 처음에는 HTTP 연결을 계속 열어 둔 채 작업이 끝나면 200 OK를 반환했지만, 중간 프록시의 timeout과 클라이언트 재시도가 겹치면서 문제가 생겼습니다. 서버에서는 작업이 끝났는데 클라이언트는 timeout을 보고 실패로 판단했고, 같은 보고서를 다시 생성하는 POST를 보냈습니다.

이때 단순히 응답을 빨리 보내기 위해 모든 요청에 202를 붙이면 문제가 해결되지 않습니다. 클라이언트가 “요청을 접수했는지”, “실제 작업이 성공했는지”, “어디서 결과를 확인할지”를 알 수 있어야 하기 때문입니다. 202는 비동기 작업을 위한 시작점이지, 비동기 작업 전체의 계약을 대신하는 상태 코드가 아닙니다.

## 202의 정확한 의미

RFC 9110에서 202 Accepted는 요청을 처리 대상으로 받아들였지만 처리가 끝나지 않았다는 의미입니다. 더 중요한 점은 서버가 나중에 반드시 성공한다고 보장하는 상태가 아니라는 것입니다. 검증이나 실행이 뒤에서 진행되므로, 최종적으로 거부될 가능성도 남아 있습니다. HTTP 자체에는 비동기 작업이 끝난 뒤 원래 응답의 상태 코드를 다시 보내는 기능이 없기 때문에, 상태를 확인할 별도 리소스가 필요합니다.

따라서 202 응답에는 최소한 다음 세 가지가 있어야 합니다.

1. 접수된 작업을 식별할 수 있는 operation id
2. 현재 상태를 조회할 URL
3. 클라이언트가 다음 조회를 언제 할지 판단할 정보

작업 상태는 `queued`, `running`, `succeeded`, `failed`, `cancelled`처럼 문서화된 유한한 값으로 관리하는 편이 좋습니다. 특히 `succeeded`와 `failed`를 구분하지 않고 `done` 하나로 끝내면, 클라이언트가 성공 결과와 처리 실패를 다시 해석해야 합니다.

## 코드로 보기

보고서 생성 요청을 다음처럼 설계할 수 있습니다.

```http
POST /v1/report-exports
Idempotency-Key: customer-42:report-20260713
Content-Type: application/json

{"reportType":"monthly-sales","month":"2026-06"}
```

서버는 요청 형식, 권한, 중복 키를 동기적으로 확인한 뒤 작업 레코드와 큐 메시지를 저장합니다. 이 단계까지 성공했을 때만 202를 반환합니다.

```http
HTTP/1.1 202 Accepted
Location: /v1/operations/op_01JZ7R6C
Retry-After: 5
Content-Type: application/json

{
  "operationId": "op_01JZ7R6C",
  "status": "queued",
  "statusUrl": "/v1/operations/op_01JZ7R6C",
  "createdAt": "2026-07-13T00:50:01Z"
}
```

`Location`은 상태 조회 리소스를 가리키고 `Retry-After`는 polling 간격에 대한 힌트입니다. 이 값이 있어도 클라이언트가 반드시 정확한 시점에 호출한다고 가정하면 안 됩니다. 클라이언트는 지수 백오프와 최대 polling 시간도 가져야 하며, 서버는 짧은 간격의 반복 조회가 상태 저장소와 API 서버를 압박하지 않는지 확인해야 합니다.

상태 조회는 작업이 아직 끝나지 않았더라도 HTTP 200과 상태 표현을 반환할 수 있습니다.

```http
GET /v1/operations/op_01JZ7R6C

HTTP/1.1 200 OK
Content-Type: application/json

{
  "operationId": "op_01JZ7R6C",
  "status": "running",
  "percentComplete": 60,
  "lastUpdatedAt": "2026-07-13T01:02:10Z"
}
```

완료되면 결과 리소스 링크를 포함합니다.

```json
{
  "operationId": "op_01JZ7R6C",
  "status": "succeeded",
  "resultUrl": "/v1/report-exports/exp_1004",
  "completedAt": "2026-07-13T01:05:42Z"
}
```

실패한 경우에는 `errorCode`, 사용자에게 보여줄 메시지, 재시도 가능 여부를 구조화해 남깁니다. 작업이 이미 큐에 들어간 뒤 HTTP 응답이 유실될 수 있으므로, 동일한 `Idempotency-Key`가 다시 오면 새 작업을 만들지 않고 기존 operation을 반환해야 합니다. 여기서 멱등성 키의 보관 기간과 payload가 달라졌을 때의 오류도 계약에 포함해야 합니다.

## 201, 200, 202를 어떻게 나눌까

새 리소스가 요청 처리와 함께 실제로 만들어졌고 응답에서 그 위치를 알려줄 수 있다면 201 Created가 더 적절합니다. 서버가 요청을 완전히 처리했고 반환할 표현이 있다면 200 OK를 사용합니다. 성공적으로 처리했지만 응답 본문이 필요하지 않다면 204 No Content를 검토할 수 있습니다.

202는 다음 조건을 모두 만족할 때 선택합니다.

- 요청 처리 시간이 길어 HTTP 연결을 유지하는 것이 불안정하다.
- 접수 시점에 동기적으로 검증할 수 있는 입력과 권한 검사가 끝났다.
- 서버가 작업 상태를 저장하고 나중에 조회할 수 있다.
- 최종 성공·실패를 전달할 수 있는 상태 리소스가 있다.

반대로 검증을 아직 하지 않았거나 큐에 넣는 것조차 보장하지 못한 상태에서 202를 반환하면 안 됩니다. “나중에 알아서 처리하겠다”는 메시지를 202로 포장하면, 실제로는 요청을 잃어버려도 클라이언트가 성공으로 오해할 수 있습니다. 짧은 DB 저장이나 즉시 완료되는 CRUD에 202를 쓰는 것도 API 의미를 흐립니다.

## 자주 하는 실수

첫 번째는 202 응답에 작업 id만 넣고 상태 URL을 문서화하지 않는 것입니다. 클라이언트가 id를 받았지만 어느 API를 호출해야 할지 알 수 없으면, 결국 원래 POST를 반복 호출하거나 내부 DB를 추측하게 됩니다.

두 번째는 상태 리소스를 영구히 보관하는 것입니다. 작업 이력과 결과를 언제 삭제할지 retention을 정하지 않으면, 대용량 payload와 실패 로그가 상태 테이블을 계속 키웁니다. 반대로 너무 빨리 지우면 클라이언트가 정상적으로 polling하는 중에도 404를 받습니다. 상태 조회의 보관 기간과 404의 의미를 함께 문서화해야 합니다.

세 번째는 `queued`를 반환했지만 실제 큐 publish가 별도 트랜잭션이라 유실되는 경우입니다. DB에 operation을 저장하고 메시지 발행이 실패하면 작업은 영원히 queued에 남습니다. 같은 트랜잭션에서 outbox를 저장하고 publisher가 재발행하게 하거나, 최소한 queued 상태의 최대 대기 시간을 감시해 복구할 수 있어야 합니다.

네 번째는 polling만 제공하면서 작업 취소를 고려하지 않는 것입니다. 사용자가 이미 화면을 닫았거나 비용이 큰 작업을 잘못 요청했을 수 있습니다. 취소가 가능한 작업이라면 `DELETE /v1/operations/{id}` 같은 요청을 제공하되, 이미 실행된 외부 부작용을 완전히 되돌릴 수 있는지와 보상 작업이 필요한지를 구분해야 합니다.

## 운영에서 볼 것

202 기반 API는 HTTP 응답 시간만 보면 건강해 보입니다. 실제 상태는 다음 지표에서 드러납니다.

- 시간대별 `queued`, `running`, `succeeded`, `failed` 작업 수
- 가장 오래 queued 상태인 작업의 age
- 작업 접수부터 실행 시작, 실행 시작부터 완료까지의 p95·p99
- operation 상태 조회 API의 4xx·5xx와 polling 요청 비율
- 동일 idempotency key 충돌 수와 중복 작업 차단 수
- 실패 후 재시도 횟수, 영구 실패 작업, 만료된 상태 리소스 수

장애 때는 먼저 “202를 얼마나 빨리 반환했는가”가 아니라 “접수된 operation이 어느 상태에서 멈췄는가”를 봅니다. 큐 depth가 늘고 oldest age가 함께 증가하면 worker 처리량이나 downstream이 병목일 가능성이 큽니다. 상태는 `running`인데 lastUpdatedAt이 오래됐다면 worker heartbeat나 lease 만료를 확인해야 합니다. 상태 조회 404가 갑자기 늘면 보관 정책 변경이나 상태 저장소 장애를 의심할 수 있습니다.

## 정리

HTTP 202 Accepted는 작업 완료가 아니라 비동기 처리를 접수했다는 응답이다.
상태 URL, 상태 모델, 최종 결과·실패 표현을 하나의 API 계약으로 설계해야 한다.
응답 유실에 대비해 초기 POST의 멱등성 키와 operation 저장·큐 발행의 정합성을 함께 다뤄야 한다.
운영에서는 HTTP latency보다 queue age, 상태별 작업 수, 처리 지연, stuck operation을 먼저 본다.

## 참고한 공식 문서

- [RFC 9110 HTTP Semantics - 202 Accepted](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.3)
- [Microsoft Learn - Asynchronous Request-Reply pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/asynchronous-request-reply)
