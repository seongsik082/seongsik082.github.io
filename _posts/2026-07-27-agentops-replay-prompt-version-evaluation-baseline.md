---
title: "에이전트 재실행은 왜 Run을 복사하는 대신 실행 기준을 고정해야 하는가"
date: 2026-07-27 08:55:00 +0900
tags: [AgentOps, API, PostgreSQL, Backend]
excerpt: "AgentOps Board KR에서 재실행을 과거 출력의 복제가 아니라 PromptVersion·도구 범위·평가 기준을 식별 가능한 새 Run으로 만드는 설계로 다룹니다. 현재 승인 정책을 우회하지 않으면서 비교 가능한 재실행을 만드는 경계를 설명합니다."
---

**사례 상태: 설계 시나리오.** AgentOps Board KR의 `Run`, `StepLog`, `PromptVersion`, `EvaluationCase`, `EvaluationResult` 모델과 재실행·프롬프트·평가 API를 바탕으로 한 설계다. 모델 호출·외부 도구·권한 체계는 미구현이므로, 아래 상태·SQL·응답은 통합 테스트로 검증할 계약이다.

## “재실행했는데 왜 결과가 달라졌나요?”에 먼저 답할 것

운영자가 지난주 실행한 문서 검색 Run을 열고 재실행 버튼을 눌렀다고 하자. 그 사이 프롬프트는 v3에서 v4로 바뀌었고, 문서 검색 도구의 범위도 좁아졌으며, 승인 정책은 더 엄격해졌을 수 있다. 이때 새 Run이 최신 설정으로 실행됐다면 그것은 과거 Run의 재현일까, 현재 설정으로 한 번 더 실행한 것일까? 둘을 같은 “재실행”이라고 부르면 결과가 달라졌을 때 비교 기준이 사라진다.

LLM이나 외부 도구가 같은 출력 문자열을 다시 준다고 약속할 수도 없다. 모델·검색 인덱스·도구 응답은 시간이 지나며 바뀔 수 있다. 그래서 이 글에서 말하는 재현은 **과거 출력의 완전한 복제**가 아니라, 어떤 프롬프트 버전·도구 범위·평가 기준으로 요청했는지를 나중에 식별할 수 있게 만드는 일이다.

AgentOps Board KR에는 Run 히스토리·재실행·프롬프트 버전·평가셋이 함께 있다. 이를 따로 만들면 “v4가 좋아졌다”는 결과가 v3 Run과 v4 Run을 섞은 비교가 될 수 있다. 재실행은 기존 Run을 수정하지 않고 **원본을 가리키는 새 Run과 실행 기준**을 만든다.

## 재실행에는 두 종류가 있다

재실행 버튼에는 과거 기준을 다시 요청하는 의도와 최신 설정의 개선 효과를 비교하는 의도가 섞이기 쉽다. API와 데이터에 이 차이를 남겨야 한다.

| 모드 | 새 Run이 고정할 기준 | 사용 목적 | 결과 해석 |
| --- | --- | --- | --- |
| `baseline` | 원본 Run의 PromptVersion·ToolScopeRevision·EvaluationCaseRevision ID | 과거 설정으로 다시 요청해 차이를 조사 | 출력이 달라도 요청 기준은 같았는지 확인한다. |
| `compare_current` | 명시적으로 선택한 최신 revision ID | 프롬프트·정책 변경의 영향 비교 | 원본과 새 Run이 다른 설정임을 화면에 표시한다. |

`baseline`은 “무조건 과거 권한으로 실행한다”는 뜻이 아니다. 프롬프트와 도구 범위는 분석 기준으로 보존하지만, 현재 권한과 승인 정책은 새 Run을 만들 때와 worker가 시작을 선점할 때 모두 확인한다. 예전에는 허용됐던 도구가 지금 금지됐다면 `blocked_policy_changed`로 끝내야 한다. 과거 Run을 근거로 현재 통제를 우회하게 만들면 재현 기능이 권한 우회 기능이 된다.

`compare_current`는 새 설정의 실험 Run이다. 응답과 보고서에 원본·새 Run과 source·target revision을 함께 표시한다. **과거 원인은 baseline, 변경 효과는 compare_current로 확인하며 둘 다 기존 Run은 수정하지 않는다.**

## Run은 현재 상태만이 아니라 비교의 출발점이다

기획의 기본 `Run(id, agent_id, user_id, input_summary, status, start_at, end_at)`에는 프롬프트와 파생 관계가 없다. 아래는 재실행을 위한 최소 확장안이며 원문 prompt·사용자 입력 원문은 넣지 않는다. 기존 Run이 있는 DB에는 바로 `NOT NULL`을 추가하지 않는다. nullable 열 추가 → legacy 설정 backfill 또는 baseline 불가 표시 → null 검사 → `NOT NULL`·CHECK 적용 순서로 migration한다.

```sql
ALTER TABLE agent_run
  ADD COLUMN source_run_id UUID REFERENCES agent_run(id),
  ADD COLUMN prompt_version_id UUID NOT NULL
    REFERENCES prompt_version(id) ON DELETE RESTRICT,
  ADD COLUMN tool_scope_revision_id UUID NOT NULL
    REFERENCES tool_scope_revision(id) ON DELETE RESTRICT,
  ADD COLUMN evaluation_case_revision_id UUID
    REFERENCES evaluation_case_revision(id) ON DELETE RESTRICT,
  ADD COLUMN config_hash CHAR(64) NOT NULL,
  ADD COLUMN replay_mode VARCHAR(20) NOT NULL DEFAULT 'initial'
    CHECK (replay_mode IN ('initial', 'baseline', 'compare_current')),
  ADD CONSTRAINT replay_source_required CHECK (
    (replay_mode = 'initial' AND source_run_id IS NULL) OR
    (replay_mode <> 'initial' AND source_run_id IS NOT NULL)
  );
```

`replay_mode='initial'`은 최초 Run이고, 나머지 모드는 `source_run_id`가 필수다. `PromptVersion`은 published 뒤 template을 UPDATE하지 않는 append-only 행으로 정한다. 템플릿 원문은 Run에 복사하지 않고 버전 ID로 가리킨다. `ToolScopeRevision(id, agent_id, revision, definition_json, definition_hash)`에는 허용 도구·scope·정책 revision을 복원 가능한 형태로 저장한다. `config_hash`는 비교용 보조값일 뿐 scope 원본이 아니다.

평가는 `EvaluationCase(id, name)`와 `EvaluationCaseRevision(id, case_id, revision, input, expected_rule)`로 나눈다. Run과 EvaluationResult는 revision ID를 참조하므로 다른 case의 revision 1을 섞지 않는다. 이 행과 ToolScopeRevision도 append-only다. `ON DELETE RESTRICT`는 삭제만 막으므로 기존 revision UPDATE는 application 쓰기 경로와 DB 역할에서 금지한다.

## API는 “새 Run을 만들었다”와 “실행이 끝났다”를 구분한다

원본 Run을 직접 `queued`로 되돌리거나 StepLog를 지우면 감사 화면의 시간이 거꾸로 간다. `POST /runs/:id/replay`는 항상 새 Run을 만들고 원본을 참조한다. 외부 도구 호출은 비동기일 수 있으므로, 생성 직후 성공 결과를 반환하지 않는다.

```http
POST /runs/run_2026_001/replay
Content-Type: application/json

{ "mode": "baseline" }
```

```json
{
  "runId": "run_2026_014",
  "sourceRunId": "run_2026_001",
  "status": "pending_approval",
  "mode": "baseline",
  "baseline": {
    "promptVersionId": "pv_3",
    "toolScopeRevisionId": "ts_7",
    "evaluationCaseRevisionId": "ec_11"
  }
}
```

이 API는 transaction 안에서 새 Run을 insert하므로 `201 Created`와 `Location: /runs/run_2026_014`를 반환한다. baseline은 구성 선택 값을 받지 않고 원본 revision을 쓴다. `compare_current`만 target revision ID를 모두 명시한다. 평가하지 않는 Run은 source·target 모두 `evaluationCaseRevisionId: null`로 두며 score 비교를 만들지 않는다. 이후 상태는 Run 조회로 읽고 StepLog는 새 Run만 보여 준다.

서버 transaction은 원본 Run·세 revision ID를 읽고 현재 정책으로 요청 권한을 확인한다. 허용되면 새 `agent_run`을 insert하고 승인 대상이면 `pending_approval`로 둔다. backfill하지 못한 옛 Run처럼 기준 revision이 없으면 최신 실행으로 바꾸지 말고 `409 replay_baseline_unavailable`을 준다. foreign key의 `ON DELETE RESTRICT`는 참조 행 삭제만 막으며, 불변성·현재 권한은 보장하지 않는다.

```text
source Run 조회 → 기준 snapshot 확인 → 현재 정책·권한 확인
  → 새 Run INSERT(source_run_id=원본, replay_mode=...)
  → 승인 필요: pending_approval / 불필요: queued
  → worker 선점 직전 현재 정책 재확인 후 running·차단·재승인
  → 새 Run에만 StepLog와 EvaluationResult 기록
```

## StepLog와 EvaluationResult는 서로 다른 질문에 답한다

`StepLog(run_id, step_no, tool_name, input_hash, output_hash, cost_ms)`는 실행 단계를 보여 준다. 해시는 원문 노출을 줄이는 비교 단서일 뿐, 외부 도구·모델·검색 데이터가 같다는 증명은 아니다.

`EvaluationResult(run_id, evaluation_case_revision_id, score, notes)`는 Run이 어느 평가 규칙에서 받은 점수인지 보여 준다. 화면에는 score와 prompt·case·tool scope revision ID, 상태를 같이 둔다. 기준이 다르면 같은 차트에 보여도 `not_comparable`로 표시한다.

## 선택하지 않은 방식과 비용

첫 번째 대안은 **원본 Run 행을 최신 설정으로 덮어쓰는 방식**이다. 구현은 짧지만 원본 기준과 StepLog timeline이 사라진다. 재실행은 새 Run INSERT여야 한다.

두 번째 대안은 **항상 최신 PromptVersion으로 실행하는 방식**이다. 개선 확인은 편하지만 과거 오류의 기준을 조사할 수 없다. 이 기능은 `compare_current`로만 제공한다.

세 번째 대안은 **prompt·policy·도구 설정 전체를 매 Run에 원문 복사하는 방식**이다. 오래된 설정을 보기 쉽지만 저장량·민감정보 노출·복사본 이력 비용이 커진다. 첫 구현은 immutable revision 참조와 hash로 시작하고, 장기 보존이 필요할 때 암호화 snapshot을 검토한다.

## 이 설계를 적용하지 않을 조건

외부 검색 인덱스나 티켓 시스템까지 되돌릴 수 없으면 “완전 재현”이라고 주장하면 안 된다. 승인·권한이 없는 개인 playground에는 이 테이블 확장이 과할 수 있지만, 최신 설정 실행을 과거 Run의 재현으로 표시하지 않는 규칙은 남긴다.

## 구현 전에 확인할 다섯 가지

통합 테스트에서는 실제 모델 품질을 측정하기 전에 상태와 기준이 섞이지 않는지 먼저 확인한다.

1. Prompt v3·ToolScopeRevision 7·EvaluationCaseRevision 11 원본에서 baseline child를 만들고, v4 추가 뒤에도 3·7·11과 원본이 보존되는지 확인한다.
2. `compare_current` child는 선택한 target revision ID를, baseline 응답은 원본 ID를 모두 반환해야 한다. 평가를 빼면 양쪽 평가 ID는 null이고 score 비교가 없어야 한다.
3. child가 `queued`가 된 뒤 Policy를 강화한다. worker는 StepLog 전에 `pending_approval` 또는 `blocked_policy_changed`로 바꾸고, 재승인 또는 허용 뒤에만 `running`을 선점해야 한다.
4. EvaluationCaseRevision 12를 추가한 두 결과는 revision ID가 다르면 동일 기준의 점수 변화로 표시되지 않아야 한다.
5. backfill하지 못해 기준 revision이 없는 원본은 child를 만들지 않고 409을 주는지 확인한다.

1번에서 child가 v4를 가리킬 때 첫 확인 지점은 모델 로그가 아니라 source Run과 세 revision ID를 읽는 transaction이다. 3번에서 승인 없이 도구가 실행됐다면 worker의 `queued → running` 선점 직전 정책 조회를 본다.

결국 AgentOps Board KR의 재실행은 “다시 눌러 보기” 기능이 아니다. 과거 기준을 식별하는 새 Run, 현재 통제를 통과하는 상태 전이, 평가 기준까지 함께 남겨야 나중에 결과 차이를 설명할 수 있다. 주니어 개발자가 처음 구현할 때는 원본 Run 수정 금지, version 참조 저장, 기준이 다른 결과의 비교 금지 세 가지부터 지키는 편이 가장 안전하다.

## 참고한 공식 문서

- [RFC 9110: 201 Created](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.2)
- [PostgreSQL: Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)
- [NIST AI RMF Core: Measure](https://airc.nist.gov/airmf-resources/airmf/5-sec-core/)
