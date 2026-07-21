---
title: "에이전트 실행 승인 API는 왜 Run 상태만 바꾸면 안 되는가"
date: 2026-07-20 08:55:00 +0900
tags: [API, PostgreSQL, Security, Backend]
excerpt: "AgentOps Board KR의 실행 승인 API를 Run 상태, Approval 기록, StepLog 감사 경계로 나눠 설계합니다. 중복 클릭·재시도·동시 승인에서도 누가 무엇을 승인했는지 남기는 기준을 정리합니다."
---

**사례 상태: 설계 시나리오.** 이 글은 아직 운영 중인 서비스의 장애 기록이 아니다. AgentOps Board KR의 `Run`, `Approval`, `StepLog` 데이터 모델과 `POST /runs/:id/approve`, `GET /runs/:id/logs` API 설계를 바탕으로, 실행 승인을 어떻게 감사 가능한 상태 전이로 만들지 정리한 기록이다. 여기서 말하는 SQL과 응답은 구현 전에 검증할 계약이며, 실제 승인 정책·보존 기간·권한 체계는 아직 확정하지 않았다.

에이전트가 티켓을 만들거나 문서에서 답을 찾는 작업을 시작하기 전, 화면에 “승인” 버튼 하나만 있으면 충분해 보인다. 하지만 사용자가 버튼을 두 번 누르거나, 첫 요청 뒤 응답을 받지 못해 브라우저가 재시도하거나, 두 명의 운영자가 같은 실행을 동시에 열면 질문이 바뀐다. 단순히 `run.status = 'approved'`로 바꾸는 것이 아니라 **누가 어느 정책 아래 어떤 실행을 승인했고, 같은 결정을 다시 보낸 것인지**를 설명할 수 있어야 한다.

목표는 결과 품질이 아니라, 같은 `run_id`를 나중에 봐도 상태·승인자·실행 단계가 모순되지 않게 만드는 것이다. 핵심 질문은 “재시도된 POST에서 어떤 행을 먼저 읽고 무엇을 두 번 쓰지 않을까”다.

## 이번 결정의 범위: 승인 자체와 실행 로그를 섞지 않는다

AgentOps Board KR에서는 `POST /runs`가 `pending_approval` Run을 만들고, 승인 transaction이 Approval·`approved` 상태·outbox event를 함께 저장한다. publisher는 commit 뒤 event를 전달하고, runner는 `approved → running`을 선점한 경우에만 도구를 호출한다. 이 transaction이 보장하는 것은 승인 상태의 원자성이지 runner 전달 자체가 아니다.

```text
POST /runs
  → Run(status=pending_approval, policy_version=...) 생성
POST /runs/{id}/approve
  → Approval 기록 + Run(status=approved) + outbox event 확정
outbox publisher
  → commit된 run_approved event 전달
runner
  → approved → running 선점 후 StepLog 기록 + Run 종료
GET /runs/{id}/logs
  → Approval.created_at, StepLog.occurred_at·step_no 순으로 감사 화면 구성
```

`Approval`은 사람이 내린 통제 결정이고, `StepLog`는 실제 도구 호출 단계다. 둘을 섞으면 “승인은 났지만 runner를 시작하지 못함”과 “실행은 시작됐지만 첫 도구 호출이 실패함”을 구분하기 어렵다. 승인마다 StepLog를 만들면 `tool_name`, 입출력 해시, 비용 시간의 의미도 흐려진다. 승인 이벤트는 `Approval`, 실행 증거는 `StepLog`, 현재 상태는 `Run`에 둔다.

포트폴리오의 `Run`, `Approval(run_id, approver_id, status, reason)`, `StepLog(run_id, step_no, tool_name, input_hash, output_hash, cost_ms)`는 각각 상태·승인자·실행 증거에 답한다. 이 설계에서는 StepLog에 `occurred_at`도 더해 timeline을 `occurred_at, step_no`로 읽는다.

## 승인 POST의 계약부터 정한다

이번 시나리오에서 클라이언트는 요청을 다시 보내도 되는 난수 `Idempotency-Key`를 함께 보낸다. 이는 표준이라고 가정하는 헤더가 아니라, 이 서비스가 정한 재시도 식별자다. 키의 보관 기간과 형식도 API 계약으로 명시해야 한다. 예를 들어 같은 승인 화면의 네트워크 재시도는 같은 키를 쓰고, 사용자가 새로 결정을 시도하면 새 키를 만든다.

```http
POST /runs/01JZ.../approve
Idempotency-Key: 7d8aa7e0-4f5a-4e17-8c49-8c9f7a7c12ab
Content-Type: application/json

{
  "status": "approved",
  "reason": "티켓 생성 범위와 대상 프로젝트를 확인함"
}
```

성공 응답은 승인 자체가 저장됐음을 보여 준다. runner가 이미 끝났다는 뜻으로 `succeeded`를 돌려주면 안 된다.

```json
{
  "runId": "01JZ...",
  "status": "approved",
  "approvalId": "01KA...",
  "replayed": false
}
```

서버는 `status`와 정제한 `reason`을 canonical form으로 만들어 `request_hash`를 계산한다. 같은 `run_id`·승인자·key가 다시 오면 hash가 같을 때만 기존 `approvalId`를 `replayed: true`로 돌려준다. hash가 다르면 `idempotency_key_reused_with_different_payload` 409다. 다른 키로 이미 승인된 Run도 409다. RFC 9110의 409는 현재 리소스 상태와 충돌해 요청을 완료할 수 없을 때 쓰는 응답이다.

| 요청 | 서버 결정 | 응답 기준 |
| --- | --- | --- |
| 같은 승인자·같은 키·같은 본문 재전송 | 기존 Approval 결과를 읽는다. | `200`, `replayed: true` |
| 같은 키·다른 본문 | 키 재사용 오류로 상태를 바꾸지 않는다. | `409` |
| 다른 키로 이미 승인된 Run 재승인 | 상태를 바꾸지 않고 현재 상태를 보여 준다. | `409` |
| 권한 없는 사용자의 승인 | Approval을 만들지 않는다. | `403` |
| `pending_approval`이 아닌 Run | 정책상 허용되지 않은 상태 전이다. | `409` |
| 없는 Run | Approval을 만들지 않는다. | `404` |
| 키가 없거나 형식이 틀림 | 재시도 계약을 만들지 않는다. | `400` |

key는 재시도만 묶는다. 권한·현재 상태·Policy version은 다시 확인하며, 키 범위는 `run_id + approver_id + key`다. key 보관이 끝나면 과거 재시도와 같은 결과를 준다는 보장도 끝난다.

## Approval과 Run을 한 트랜잭션에서 바꾸는 이유

아래는 단일 승인자 정책의 예시다. `request_key`와 `request_hash`는 중복 POST와 다른 본문 재사용을 구분한다.

```sql
CREATE TABLE approval (
  id UUID PRIMARY KEY,
  run_id UUID NOT NULL REFERENCES agent_run(id),
  approver_id UUID NOT NULL,
  status VARCHAR(20) NOT NULL CHECK (status = 'approved'),
  reason TEXT,
  policy_version VARCHAR(40) NOT NULL,
  request_key UUID NOT NULL,
  request_hash CHAR(64) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  UNIQUE (run_id),
  UNIQUE (run_id, approver_id, request_key)
);
```

서비스 transaction은 Run 행을 먼저 잠근다. PostgreSQL의 `SELECT ... FOR UPDATE`는 같은 행을 갱신·잠그려는 다른 transaction을 기다리게 한다. 이 글의 409 흐름은 PostgreSQL 기본인 Read Committed를 가정한다. Repeatable Read·Serializable에서 `40001` 또는 deadlock이 나면 현재 transaction을 rollback하고 처음부터 재시도해야 한다.

```sql
BEGIN;

SELECT id, status, agent_id, policy_version
FROM agent_run
WHERE id = :run_id
FOR UPDATE;

-- 먼저 기존 Approval의 request_hash를 읽는다.
-- hash가 같으면 같은 approvalId를 반환하고, 다르면 ROLLBACK 후 409이다.
-- 없으면 권한·정책·status = 'pending_approval'을 검증한다.

INSERT INTO approval (
  id, run_id, approver_id, status, reason,
  policy_version, request_key, request_hash, created_at
) VALUES (
  :approval_id, :run_id, :approver_id, 'approved', :reason,
  :policy_version, :request_key, :request_hash, now()
);

UPDATE agent_run
SET status = 'approved'
WHERE id = :run_id AND status = 'pending_approval';

INSERT INTO outbox_event (id, event_type, aggregate_id, created_at)
VALUES (:event_id, 'run_approved', :run_id, now());

COMMIT;
```

Approval만 commit하면 감사 화면과 실행 가능 상태가 갈라진다. 그래서 Approval·Run·outbox를 같은 transaction에 둔다. `UPDATE`가 0행이면 **ROLLBACK** 뒤 현재 상태를 읽어 409를 만든다. publisher가 죽어도 outbox는 남고, runner는 `UPDATE agent_run SET status='running' WHERE id=:run_id AND status='approved' RETURNING id`가 1행일 때만 시작한다.

## 선택하지 않은 두 가지 방식

| 방식 | 장점 | 이 글에서 선택하지 않은 이유 |
| --- | --- | --- |
| `run.status`만 `approved`로 UPDATE | 구현이 짧고, 자동 승인만 있는 작은 도구에는 충분할 수 있다. | 승인자·사유·정책 버전·중복 요청의 근거가 남지 않는다. |
| Approval을 별도 저장하지만 Run 갱신은 비동기 처리 | 승인 이력을 먼저 쌓기 쉽다. | 두 저장이 갈라진다. outbox·재조정 규칙 없이는 쓰지 않는다. |
| 모든 상태를 event sourcing으로만 재구성 | 변경 이력과 재생이 강점이다. | 이 프로젝트의 첫 구현에는 projection, 순서, 재처리 비용이 너무 크다. Approval 테이블과 Run 상태로 시작한다. |

이 선택은 승인 한 번으로 실행을 허용하는 정책에 맞춘 것이다. 여러 승인자·철회·마감은 quorum과 역할 모델이 별도로 필요하다. 장기 불변 보존도 일반 애플리케이션 테이블만으로 충분하다고 단정하지 않는다.

## 감사 화면에 남길 것과 남기지 않을 것

승인 화면에는 `approvalId`, 승인자, 결정 시각, status, policy version을 보이고, 실행 타임라인은 `occurred_at, step_no`로 정렬한다. 원문 prompt·토큰·민감 응답은 저장하지 않는다. OWASP도 세션 식별자·토큰·민감 정보·비밀값의 마스킹·해시·암호화를 권한다. 해시는 변경 탐지나 불변성을 보장하지 않으므로, 애플리케이션 역할의 audit row 수정·삭제 권한을 제한하고 더 강한 보증이 필요하면 모니터링되는 append-only 또는 외부 저장소를 쓴다.

`approval.replayed` 증가는 프런트엔드 재시도·네트워크 오류를, `approval.conflict` 증가는 동시 조작을 먼저 의심한다. 실행이 안 됐다는 신고는 Run 상태, Approval, outbox publish 상태, 첫 StepLog 순서로 본다.

## 주니어가 먼저 만들 검증 시나리오

구현 전에 PostgreSQL을 쓰는 통합 테스트로 다음을 검증한다. mock만으로 동시성 순서를 가정하지 말고, 두 transaction이 같은 Run을 승인하려는 상황을 만든다.

1. 같은 key·같은 본문 POST는 Approval 1행과 `replayed: true`를, 같은 key·다른 reason은 409를 돌려야 한다.
2. 서로 다른 키의 동시 승인에서는 하나만 `approved`가 되고 다른 하나는 409를 받아야 한다. stronger isolation이면 40001을 새 transaction으로 재시도한다.
3. 권한 없는 승인자·없는 Run·잘못된 key는 Approval·StepLog를 만들지 않아야 한다.
4. Approval·Run·outbox 중 하나를 실패시키면 모두 rollback돼야 한다. commit 직후 publisher를 중단했다가 재개해도 outbox가 전달되고 runner가 한 번만 `running`을 선점해야 한다.
5. 승인 사유에 토큰처럼 보이는 문자열·줄바꿈을 넣어 원문 미저장과 로그 정제를 확인한다.

2번 실패의 첫 확인 지점은 lock과 isolation level, 4번은 outbox가 같은 transaction인지다. 이는 중복 승인이나 승인 뒤 미실행을 재시도 횟수 제한으로 덮기 전에 볼 경계다.

결국 승인 API의 완료 조건은 200 응답 하나가 아니다. 같은 Run에 대해 현재 상태가 하나이고, 그 상태를 만든 Approval이 하나의 감사 흔적으로 남으며, 실제 실행 StepLog와 연결돼야 한다. AgentOps Board KR에서는 그 세 가지를 분리해 저장하는 편이, 나중에 재실행·리포트·권한 검토 기능을 붙일 때도 책임 경계를 지키기 쉽다.

## 참고한 공식 문서

- [PostgreSQL: Explicit Locking](https://www.postgresql.org/docs/current/explicit-locking.html)
- [PostgreSQL: Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)
- [PostgreSQL: Error Codes](https://www.postgresql.org/docs/current/errcodes-appendix.html)
- [RFC 9110: HTTP Semantics — 409 Conflict](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.10)
- [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html)
