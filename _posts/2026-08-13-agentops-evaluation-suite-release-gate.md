---
title: "AgentOps의 평가 통과율은 왜 Prompt 버전만 같다고 비교하면 안 되는가"
date: 2026-08-13 08:55:00 +0900
tags: [AgentOps, Testing, API, PostgreSQL, Backend]
excerpt: "AgentOps Board KR의 POST /evaluations/run을 단순 점수 계산이 아니라 배포 판단에 필요한 평가셋·규칙·완료 범위를 남기는 흐름으로 설계합니다. 케이스를 바꾼 뒤 통과율이 좋아 보이는 착시와 일부 실패를 0점으로 숨기는 실수를 피하는 기준을 설명합니다."
---

**사례 상태: 설계 시나리오.** 이 글은 실제 모델 품질 수치나 배포 장애 기록이 아니다. AgentOps Board KR의 `Agent`, `Run`, `PromptVersion`, `EvaluationCase`, `EvaluationResult`, `StepLog` 모델과 `POST /prompt-versions`, `POST /evaluations/run`, `GET /runs/:id/logs` API를 바탕으로 한 설계다. 모델 호출과 평가 runner는 아직 구현하지 않았으므로, 아래 상태·SQL·응답은 통합 테스트로 검증할 계약이다.

## 통과율이 올랐는데 더 나빠질 수 있는 이유

프롬프트 v7을 배포하려는 팀이 있다고 하자. 어제는 평가 케이스 20개 중 16개를 통과했고, 오늘은 18개를 통과했다. 숫자만 보면 80%에서 90%로 좋아졌다. 하지만 오늘은 실패가 잦던 두 케이스를 잠시 제외했고, 한 케이스는 외부 Tool timeout으로 결과가 없었는데 score를 0으로 저장했다면 어떨까. 이 두 실행은 같은 의미의 80%와 90%가 아니다.

에이전트 평가는 테스트처럼 보이지만 입력·규칙·외부 도구·모델 버전이 쉽게 변한다. `EvaluationResult.score` 하나만 보면 누락과 실패를 섞고 다른 평가셋의 통과율을 한 차트에서 비교하게 된다.

결정은 간단하다. **배포 판단은 점수 평균이 아니라, 고정된 평가셋 revision에서 필수 케이스가 모두 끝났는지와 어떤 규칙에서 실패했는지를 함께 확인한다.** 점수는 결과의 한 필드이고, release gate는 별도 판정이다.

## 기존 모델에 필요한 역할 분리

기획의 `EvaluationCase(id, name, input, expected_rule)`와 `EvaluationResult(id, run_id, evaluation_case_id, score, notes)`만으로도 케이스 하나를 실행해 점수를 저장할 수 있다. 하지만 한 번의 평가 요청이 어떤 케이스 묶음을 사용했는지, 케이스가 바뀌기 전후 결과를 비교해도 되는지, 실행 중 일부가 끝나지 않았는지는 알기 어렵다.

평가 화면은 네 질문을 분리한다.

| 대상 | 답하는 질문 | 예시 상태 |
| --- | --- | --- |
| `EvaluationCaseRevision` | 이번 케이스의 입력·기대 규칙은 무엇인가 | `active`, `retired` |
| `EvaluationSuiteRevision` | 어떤 케이스 묶음과 gate 규칙으로 실행했는가 | `draft`, `published` |
| `EvaluationExecution` | 이 묶음을 어떤 PromptVersion으로 언제 요청했는가 | `queued`, `running`, `completed`, `incomplete` |
| `EvaluationResult` | 케이스 하나가 pass·fail·error 중 무엇이었는가 | `pass`, `fail`, `error`, `skipped` |

7월 27일 재실행 설계에서 `EvaluationCase`를 revision으로 나눈 이유는 과거 Run의 기대 규칙을 남기기 위해서였다. 여러 revision을 묶은 **suite revision**도 고정하지 않으면, execution 통과율의 표본이 사라진다.

예를 들어 `security_prompt_suite`의 revision 3은 SQL 작성 요청, 개인정보 마스킹 요청, 허용되지 않은 Tool 요청을 각각 한 케이스로 포함할 수 있다. revision 4에서 개인정보 케이스의 규칙을 고치거나 하나를 빼면, v7이 revision 3에서 받은 16/20과 v8이 revision 4에서 받은 18/20을 같은 개선 폭으로 그리면 안 된다. 화면은 둘 다 보여 줄 수 있지만 `not_comparable`로 표시하고, 비교 가능한 기준선은 suite revision이 같은 실행끼리만 계산한다.

## 평가 결과는 score보다 verdict를 먼저 저장한다

`score=0`은 적합하지 않은 답을 냈다는 뜻일 수 있다. 반면 model provider timeout, 파서 오류, 정책 때문에 Tool 호출이 막힌 경우는 답 자체를 평가하지 못한 것이다. 둘을 같은 0으로 저장하면 통과율이 떨어진 원인이 품질인지 인프라인지 알 수 없다.

다음은 기존 모델을 확장하는 최소 스키마다. `expected_rule` 원문이나 모델 출력 원문을 Result에 중복 저장하지 않는다. revision ID·규칙 버전·정제된 failure code를 남기고, 원문 조회는 별도 권한·보존 정책에서 다룬다. 기존 `EvaluationResult` 행은 대개 어느 suite·execution에서 왔는지 복원할 수 없다. 그래서 nullable 열을 추가한 뒤 옛 행은 legacy로 남기고, gate·비교 쿼리는 `execution_id IS NOT NULL` 결과만 읽는다. 보존 기간이 끝나 별도 archive table로 옮길 수 있을 때만 새 열을 `NOT NULL`로 바꾼다.

```sql
CREATE TABLE evaluation_suite_revision (
  id UUID PRIMARY KEY,
  suite_id UUID NOT NULL,
  revision INTEGER NOT NULL,
  gate_rule_version VARCHAR(40) NOT NULL,
  published_at TIMESTAMPTZ,
  UNIQUE (suite_id, revision)
);

CREATE TABLE evaluation_suite_case (
  suite_revision_id UUID NOT NULL REFERENCES evaluation_suite_revision(id),
  evaluation_case_revision_id UUID NOT NULL REFERENCES evaluation_case_revision(id),
  required BOOLEAN NOT NULL,
  severity VARCHAR(10) NOT NULL CHECK (severity IN ('critical', 'normal')),
  PRIMARY KEY (suite_revision_id, evaluation_case_revision_id)
);

CREATE TABLE evaluation_execution (
  id UUID PRIMARY KEY,
  agent_id UUID NOT NULL REFERENCES agent(id),
  prompt_version_id UUID NOT NULL REFERENCES prompt_version(id),
  suite_revision_id UUID NOT NULL REFERENCES evaluation_suite_revision(id),
  status VARCHAR(20) NOT NULL
    CHECK (status IN ('queued', 'running', 'completed', 'incomplete', 'failed')),
  requested_at TIMESTAMPTZ NOT NULL,
  completed_at TIMESTAMPTZ,
  UNIQUE (id, suite_revision_id),
  UNIQUE (id, prompt_version_id)
);

-- 7월 27일 설계에서 agent_run은 prompt_version_id를 pin 한다는 전제를 쓴다.
ALTER TABLE agent_run
  ADD CONSTRAINT run_id_prompt_version_key UNIQUE (id, prompt_version_id);

CREATE TABLE evaluation_execution_run (
  execution_id UUID NOT NULL,
  suite_revision_id UUID NOT NULL,
  run_id UUID NOT NULL REFERENCES agent_run(id),
  prompt_version_id UUID NOT NULL,
  evaluation_case_revision_id UUID NOT NULL,
  PRIMARY KEY (execution_id, run_id),
  UNIQUE (execution_id, evaluation_case_revision_id),
  UNIQUE (execution_id, run_id, evaluation_case_revision_id),
  FOREIGN KEY (execution_id, suite_revision_id)
    REFERENCES evaluation_execution (id, suite_revision_id),
  FOREIGN KEY (execution_id, prompt_version_id)
    REFERENCES evaluation_execution (id, prompt_version_id),
  FOREIGN KEY (run_id, prompt_version_id)
    REFERENCES agent_run (id, prompt_version_id),
  FOREIGN KEY (suite_revision_id, evaluation_case_revision_id)
    REFERENCES evaluation_suite_case
      (suite_revision_id, evaluation_case_revision_id)
);

ALTER TABLE evaluation_result
  ADD COLUMN execution_id UUID,
  ADD COLUMN suite_revision_id UUID,
  ADD COLUMN evaluation_case_revision_id UUID,
  ADD COLUMN verdict VARCHAR(10),
  ADD COLUMN failure_code VARCHAR(60);

-- 새 결과는 네 식별자와 verdict를 모두 쓰고, legacy 행은 모두 null로 남긴다.
ALTER TABLE evaluation_result
  ADD CONSTRAINT result_verdict_check
    CHECK (verdict IS NULL OR verdict IN ('pass', 'fail', 'error', 'skipped')),
  ADD CONSTRAINT result_execution_shape_check CHECK (
    (execution_id IS NULL AND suite_revision_id IS NULL
      AND evaluation_case_revision_id IS NULL AND verdict IS NULL)
    OR
    (execution_id IS NOT NULL AND suite_revision_id IS NOT NULL
      AND evaluation_case_revision_id IS NOT NULL AND verdict IS NOT NULL)
  ),
  ADD CONSTRAINT result_execution_suite_fk
    FOREIGN KEY (execution_id, suite_revision_id)
    REFERENCES evaluation_execution (id, suite_revision_id),
  ADD CONSTRAINT result_case_in_suite_fk
    FOREIGN KEY (suite_revision_id, evaluation_case_revision_id)
    REFERENCES evaluation_suite_case
      (suite_revision_id, evaluation_case_revision_id),
  ADD CONSTRAINT result_execution_run_case_fk
    FOREIGN KEY (execution_id, run_id, evaluation_case_revision_id)
    REFERENCES evaluation_execution_run
      (execution_id, run_id, evaluation_case_revision_id);

CREATE UNIQUE INDEX result_once_per_new_execution_case
  ON evaluation_result (execution_id, evaluation_case_revision_id)
  WHERE execution_id IS NOT NULL;
```

`EvaluationResult.run_id`는 케이스 실행에 쓴 Agent Run이고, `execution_id`는 그 Run들의 평가 묶음이다. `evaluation_execution_run`은 execution·Run·case·PromptVersion의 조합을 고정한다. Result의 세 값에 복합 외래 키를 걸면 v7 Run을 v8 execution 결과로 붙일 수 없고, suite에 없는 case도 넣을 수 없다. partial unique index는 legacy의 null 행을 건드리지 않고 새 execution 안의 중복 결과만 막는다. 이 연결로 `GET /runs/:id/logs`에서 실패 StepLog를 보고, 화면에서는 묶음의 완료율을 계산한다. legacy 행은 gate 쿼리에서 제외한다. 다만 "필수 케이스가 전부 끝났는가"는 여러 행 규칙이므로 gate 계산 transaction에서 검증한다. PostgreSQL도 CHECK constraint가 다른 행 데이터를 안전하게 참조하는 용도가 아니라고 설명한다. [PostgreSQL 제약조건 문서](https://www.postgresql.org/docs/current/ddl-constraints.html)가 이 경계를 분명히 한다.

## POST /evaluations/run은 점수를 바로 약속하지 않는다

평가셋에는 여러 Run과 외부 Tool 호출이 포함될 수 있다. API가 요청을 받았다고 결과까지 끝난 것은 아니다. `POST /evaluations/run`은 published suite revision과 PromptVersion을 받아 execution을 만들고, runner가 케이스별 Run을 생성하도록 큐에 넣는다.

```http
POST /evaluations/run
Content-Type: application/json

{
  "agentId": "agent_support",
  "promptVersionId": "prompt_v8",
  "suiteRevisionId": "suite_security_r3"
}
```

```http
HTTP/1.1 202 Accepted
Location: /evaluations/executions/eval_204
Content-Type: application/json

{
  "executionId": "eval_204",
  "status": "queued",
  "suiteRevisionId": "suite_security_r3",
  "gate": "pending"
}
```

202는 "통과했다"가 아니라 요청 처리를 받아들였다는 응답이다. 조회 URL과 상태 모델이 없으면 프런트엔드는 202를 성공 배포로 오해하기 쉽다. [RFC 9110의 202 Accepted](https://www.rfc-editor.org/rfc/rfc9110.html#status.202)는 원래 HTTP 응답으로 비동기 결과를 나중에 보낼 수 없다고 설명한다. 이후 상태는 `Location`의 execution 리소스에서 읽는다.

서버는 먼저 suite revision이 published인지, PromptVersion이 그 Agent 소속인지, 요청자가 평가를 실행할 권한이 있는지 확인한다. 통과하면 `queued` execution과 case 목록을 같은 transaction으로 확정한다. 이때 suite를 나중에 수정하지 않고 revision 4를 새로 만들기 때문에, worker가 일하는 사이 revision 3의 케이스 구성이 조용히 바뀌지 않는다.

worker는 case마다 새 `Run`을 만들고, 기존 Tool Policy를 현재 시점에 다시 적용한다. Tool 호출이 policy에 막혔다면 그것은 모델 답변의 fail과 다르므로 Result verdict는 `error`, failure code는 `blocked_policy_changed`로 둔다. 그렇게 해야 보안 정책 강화 뒤에 통과율이 떨어진 상황을 "프롬프트 회귀"로 잘못 해석하지 않는다. `StepLog`에는 실제 실행 단계만 남기고, evaluation verdict는 `EvaluationResult`에 남긴다. 둘은 서로 다른 질문에 답한다.

## release gate는 평균이 아니라 완결성 규칙이다

이 설계에서 gate 계산은 다음처럼 작게 시작한다. 먼저 required case의 결과 수가 suite에 정의된 required case 수와 같은지 확인한다. 결과 행이 없으면 해당 case Run은 아직 queued·running이거나 runner가 끝나기 전에 중단된 것이다. 결과가 하나라도 없거나 `error`·`skipped`면 status를 `incomplete`로 두고 배포 허용·차단을 확정하지 않는다. 그 다음 critical case에 `fail`이 하나라도 있으면 gate는 `blocked`다. 마지막으로 모든 required case가 pass·fail로 끝났고 critical fail이 없을 때만, normal case의 최소 통과 비율 같은 팀 규칙을 적용한다.

```text
required 결과가 누락됨·error·skipped    -> incomplete
critical verdict=fail 하나 이상          -> blocked
그 외 normal 통과율이 팀 기준 미만        -> blocked
그 외                                    -> passed
```

여기서 90% 같은 숫자를 글의 정답으로 정하지 않는다. 고객에게 직접 답하는 Agent, 외부 티켓을 만드는 Agent, 읽기 전용 요약 Agent는 실패가 미치는 영향과 허용 범위가 다르다. NIST AI RMF도 측정 방법이 맥락에 따라 달라지고, 위험 허용 범위는 조직과 사용 사례에 따라 정해야 한다고 설명한다. [NIST AI RMF 1.0](https://doi.org/10.6028/NIST.AI.100-1)을 따르면 숫자 하나보다 왜 그 케이스가 critical인지와 어떤 failure가 배포를 막는지를 먼저 문서화하는 편이 맞다.

중요한 것은 `incomplete`를 `failed`의 별칭으로 만들지 않는 것이다. failed는 평가가 끝났고 규칙을 만족하지 못했다는 뜻이다. incomplete는 아직 품질 판단을 할 정보가 부족하다는 뜻이다. 자동 재시도할 수 있는 provider 오류라도 재시도 횟수·마감 시간을 넘기면 incomplete로 닫고, 사람이 재실행할지 확인할 수 있게 한다. 무한 재시도로 통과율 대시보드만 늦게 갱신하는 구조는 운영 판단에 도움이 되지 않는다.

## 선택하지 않은 방식과 적용하지 않을 조건

첫 번째 대안은 `EvaluationResult.score`의 평균만 계산해 threshold를 넘으면 배포하는 방식이다. 구현은 짧고 차트도 만들기 쉽다. 하지만 error를 0점으로 섞고, critical 케이스 하나의 실패를 normal 케이스 여러 개의 점수로 가릴 수 있다. 그래서 verdict·severity·완료 여부를 먼저 계산한다.

두 번째 대안은 EvaluationCase를 수정 가능하게 두고 항상 최신 케이스로 통과율을 그리는 방식이다. 운영자는 최신 규칙만 보면 되므로 편해 보인다. 그러나 케이스 삭제나 기대 규칙 완화가 품질 개선처럼 보일 수 있다. 기존 revision은 보존하고, 새 suite revision 결과는 같은 기준선과 직접 비교하지 않는다.

반대로 Tool이 없고 프롬프트도 거의 바뀌지 않는 개인용 데모라면 suite revision·비동기 execution·gate 테이블까지 먼저 만들 필요는 없다. 고정된 입력 몇 개를 수동 확인하는 편이 더 빠를 수 있다. 이 글은 모델 자체의 절대 품질을 보증하거나, 평가 통과가 실제 운영 안전을 증명한다고 주장하지 않는다. 실제 사용자 입력·외부 시스템·정책은 평가셋 밖에서도 달라질 수 있다.

## 주니어가 구현 전에 실행할 다섯 가지 검증

평가 기능의 첫 테스트는 좋은 score가 아니라, 나쁜 비교가 화면에 나오지 않는지 확인하는 것이다.

1. suite revision 3에 required case 세 개와 normal case 두 개를 넣고 execution을 요청한다. execution과 그 case 목록이 같은 transaction에서 고정되고, revision 4를 새로 만들어도 execution의 목록이 변하지 않는지 확인한다.
2. required case 하나를 provider timeout으로 `error` 처리한다. 평균 score가 높아도 gate가 `incomplete`이며 `passed`가 아닌지 확인한다.
3. critical case 하나를 `fail`, 나머지를 전부 `pass`로 만든다. normal 통과율이 높아도 gate가 `blocked`인지 확인한다.
4. 같은 PromptVersion으로 suite revision 3과 4를 실행한다. 보고서가 두 통과율을 나란히 보여 주되 "개선" 수치나 delta를 만들지 않고 `not_comparable`이라고 표시하는지 확인한다.
5. evaluation worker가 Tool 호출 직전에 Policy 변경을 만나면 해당 Result가 `error/blocked_policy_changed`가 되고, 관련 Run의 StepLog에는 실제 호출이 없거나 정책 차단 증거만 남는지 확인한다.

통과율이 갑자기 떨어졌다면 첫 확인 지점은 prompt diff가 아니다. 먼저 execution의 `suite_revision_id`, required 결과 수, `verdict`별 개수, `failure_code`를 본다. 그 뒤에만 특정 Result의 `run_id`로 `GET /runs/:id/logs`를 열어 모델 답변 실패인지 Tool·정책·provider 문제인지 추적한다. 이 순서를 지키면 "v8이 나빠졌다"는 말이 케이스 변경, 미완료 실행, 실제 품질 회귀 중 무엇을 뜻하는지 분리할 수 있다.

AgentOps Board KR의 평가는 점수표를 만드는 기능이 아니다. 어떤 케이스·규칙·실행 결과가 배포 판단을 만들었는지 남기는 운영 기록이다. 처음 구현에서는 세 가지만 지키면 된다. suite revision을 고정하고, error를 0점으로 숨기지 말고, 비교 가능한 결과에만 개선이라는 말을 붙인다.

## 참고한 공식 문서

- [NIST AI RMF 1.0](https://doi.org/10.6028/NIST.AI.100-1)
- [PostgreSQL: Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)
- [RFC 9110: 202 Accepted](https://www.rfc-editor.org/rfc/rfc9110.html#status.202)
