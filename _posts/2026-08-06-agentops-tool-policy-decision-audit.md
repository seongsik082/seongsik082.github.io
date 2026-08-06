---
title: "AgentOps의 도구 권한은 requires_approval 하나로 결정하면 안 되는 이유"
date: 2026-08-06 08:55:00 +0900
tags: [AgentOps, Security, API, Backend]
excerpt: "AgentOps Board KR에서 Tool의 기술적 범위, Policy의 조건, Approval의 사람 판단, StepLog의 실제 호출 기록을 분리하는 설계 기록입니다. 에이전트가 요청한 도구 이름을 그대로 믿지 않고 호출 직전에 deny·승인·allow를 결정하는 기준을 설명합니다."
---

**사례 상태: 설계 시나리오.** 이 글은 구현·운영 중인 서비스의 장애 기록이 아니다. AgentOps Board KR의 `Agent`, `Tool`, `Policy(condition_json, action)`, `Run`, `Approval`, `StepLog` 모델과 `POST /tools`, `POST /policies`, `POST /runs`, `POST /runs/:id/approve`, `GET /runs/:id/logs` API를 바탕으로 한 설계다. 아래 테이블과 응답은 구현 전에 통합 테스트로 검증할 계약이다.

## “승인 필요” 체크 하나가 설명하지 못하는 순간

사내 문서 검색과 티켓 초안을 만드는 에이전트를 생각해 보자. `document.search`는 읽기 전용이고, `ticket.create`는 외부 시스템에 새 일을 만든다. 처음에는 Tool에 `requires_approval=true`만 두면 충분해 보인다. 검색은 바로 실행하고, 티켓 생성은 실행 전체를 승인 대기 상태로 보내면 된다.

하지만 운영자는 곧 더 구체적인 질문을 한다. 테스트 환경의 낮은 우선순위 티켓은 자동으로 만들어도 되는가? 운영 환경의 장애 티켓만 승인받을 것인가? 에이전트 A는 지원 프로젝트에만 티켓을 만들 수 있고, 에이전트 B는 같은 Tool을 전혀 쓰면 안 되는가? “어떤 Tool이냐”만으로는 답할 수 없고, **누가·어떤 범위에·어떤 Run 맥락에서 호출했는지**가 함께 필요하다.

가장 위험한 지름길은 에이전트가 생성한 계획의 `toolName`과 `scope`를 그대로 runner에 넘기는 방식이다. 에이전트가 “문서 검색”이라고 썼다고 해서 그 요청이 허용된 문서 공간을 가리킨다는 보장은 없다. 정책 평가는 모델 출력의 정직함을 확인하는 단계가 아니라, 실제 도구 호출의 마지막 관문이어야 한다.

이번 결정은 Tool의 등록 정보, Policy의 판단, 사람의 승인, 실제 호출 로그를 서로 다른 책임으로 둔다. 그래야 “승인받은 Run인데 왜 이 티켓 생성은 막혔나”, 반대로 “정책이 deny인데 어떤 경로로 호출됐나”를 나중에 추적할 수 있다.

## 네 가지를 섞지 않는 요청 흐름

| 구분 | AgentOps Board KR에서 답하는 질문 | 저장할 핵심 값 |
| --- | --- | --- |
| `Tool` | 이 시스템이 기술적으로 제공하는 동작은 무엇인가? | `name`, 고정된 `scope` 종류, 기본 승인 필요 여부 |
| `Policy` | 이 Agent가 이 Tool을 이 조건에서 써도 되는가? | `agent_id`, `tool_id`, `condition_json`, `action` |
| `Approval` | 사람이 이 Run 또는 고위험 호출을 허용했는가? | `run_id`, 승인자, 상태, 사유 |
| `StepLog` | 실제로 어느 Tool 호출이 시도·완료됐는가? | `run_id`, 순서, tool, 입출력 hash, 결과 |

`Tool.requires_approval`은 “이 Tool은 원칙적으로 사람 확인이 필요한가”라는 **기본 위험 표시**다. 이것이 Agent별 허용 목록도 아니고, 특정 프로젝트에 대한 권한도 아니다. `Policy.action`은 `allow`, `require_approval`, `deny` 중 하나를 선택해 Run의 맥락을 평가한다. `Approval`은 Policy가 요구한 사람의 결정을 기록하며, `StepLog`는 그 뒤 실제 runner가 호출한 사실을 남긴다.

호출 흐름은 다음처럼 고정한다. UI가 Policy 결과를 미리 보여 줄 수는 있어도, UI의 결과만 믿고 Tool endpoint를 직접 열면 안 된다.

```text
Run이 다음 Tool 호출을 준비
  → runner가 Tool ID·대상 범위·Run의 environment를 서버에서 확정
  → Policy evaluator가 각 Policy의 현재 revision만 평가하고 Decision을 저장
  → deny: Tool client를 호출하지 않음
  → require_approval: 해당 Decision을 가리키는 Approval 확인 전까지 대기
  → allow: 실행 시도 레코드를 만든 뒤 runner만 Tool client 호출
  → StepLog에 실행 시도와 실제 호출 결과를 연결해 기록
```

여기서 Policy evaluator는 정책을 계산하는 부분, runner의 Tool client 앞단은 실제 호출을 막는 부분이다. NIST SP 800-207의 정책 결정 지점과 정책 집행 지점이라는 구분을 작은 서비스 안에 적용한 것이다. 한 번 로그인했거나 Run 하나가 승인됐다는 사실만으로 이후 모든 Tool 요청을 신뢰하지 않고, 각 호출의 대상과 상태를 다시 본다.

## 조건 JSON은 자유로운 설정값이 아니라 작은 언어다

`Policy.condition_json`에 아무 JSON이나 저장하면 관리 화면은 유연해 보인다. 그러나 runner가 모르는 키를 조용히 무시하면 `{"env":"production"}` 같은 오타가 조건 없는 allow가 될 수 있다. 반대로 JSON 안에 임의 스크립트나 SQL 조건을 넣으면 정책 수정이 곧 코드 실행 경로가 된다.

첫 구현에서는 조건의 형태를 작게 제한한다. 예를 들어 environment, 프로젝트 식별자, 티켓 우선순위, 사용자 요청 유형만 지원하고, 새 조건은 코드와 테스트를 추가한 뒤에만 연다.

```http
POST /policies
Content-Type: application/json

{
  "agentId": "agent_support",
  "toolId": "tool_ticket_create",
  "priority": 100,
  "action": "require_approval",
  "condition": {
    "environment": "production",
    "projectIds": ["support"],
    "maxTicketPriority": "high"
  }
}
```

이 요청을 받으면 서버는 `action`의 enum, priority 범위, `condition`의 타입과 허용 키를 검사한다. JSON Schema를 쓴다면 `required`, `enum`, `additionalProperties: false`로 “필수 키가 있는지”와 “알 수 없는 키를 거부하는지”를 명시할 수 있다. 다만 Schema 통과는 정책의 업무 의미가 맞다는 증명이 아니다. `projectIds`에 어떤 ID를 넣을 수 있는지는 현재 사용자와 Agent의 소유 관계를 서버에서 별도로 확인해야 한다.

정책 행에는 사람이 읽을 수 있는 이름만 저장하지 않는다. 아래처럼 revision과 우선순위를 두고, 수정은 UPDATE로 덮어쓰지 않고 새 revision을 만든다. 그래야 Run 로그에 “어느 규칙으로 deny했는가”를 남길 수 있다.

```sql
CREATE TABLE policy_revision (
  id UUID PRIMARY KEY,
  policy_id UUID NOT NULL REFERENCES policy(id),
  agent_id UUID NOT NULL REFERENCES agent(id),
  tool_id UUID NOT NULL REFERENCES tool(id),
  priority INTEGER NOT NULL CHECK (priority BETWEEN 0 AND 1000),
  action VARCHAR(20) NOT NULL
    CHECK (action IN ('allow', 'require_approval', 'deny')),
  condition_json JSONB NOT NULL,
  enabled BOOLEAN NOT NULL,
  revision INTEGER NOT NULL,
  superseded_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL,
  UNIQUE (policy_id, revision)
);

CREATE TABLE run_tool_decision (
  id UUID PRIMARY KEY,
  run_id UUID NOT NULL REFERENCES run(id),
  tool_id UUID NOT NULL REFERENCES tool(id),
  policy_revision_id UUID REFERENCES policy_revision(id),
  requested_scope_hash CHAR(64) NOT NULL,
  decision VARCHAR(20) NOT NULL
    CHECK (decision IN ('allow', 'require_approval', 'deny')),
  reason_code VARCHAR(60) NOT NULL,
  decided_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE tool_execution_attempt (
  id UUID PRIMARY KEY,
  run_tool_decision_id UUID NOT NULL REFERENCES run_tool_decision(id),
  status VARCHAR(20) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);
```

`condition_json` 원문과 사용자 입력 원문을 StepLog에 통째로 복사하지 않는다. 감사 화면에는 Policy revision ID, `reason_code`, 대상 범위의 hash를 보인다. 원문 확인이 꼭 필요한 감사 절차는 별도 권한과 보존 정책을 둔 조회 경로에서 처리한다. hash는 “같은 입력인지 비교할 단서”일 뿐, 원문 복구나 변조 방지 장치라고 과장하지 않는다.

## 같은 Tool에 Policy가 여러 개면 어떻게 결정할까

정책 엔진이 여러 행을 읽고 마지막 행 하나를 우연히 선택하면, DB 정렬 순서나 새 Policy 추가 순서가 권한이 된다. 그래서 평가 순서를 문서와 코드에 같이 고정한다.

1. runner는 Agent ID, Tool ID, 요청 대상의 프로젝트·environment를 인증된 Run과 서버 데이터에서 만든다. 모델이 보낸 임의 `agentId`나 `projectId`를 신뢰하지 않는다.
2. `policy_id`마다 `superseded_at IS NULL`인 현재 revision 하나만 선택하고, 그중 enabled이며 조건이 맞는 것만 고른다. 과거 revision은 감사 조회에만 쓴다. 같은 action 안에서는 `priority`가 높은 규칙을 이유 설명에 사용한다.
3. 조건이 맞는 `deny`가 하나라도 있으면 최종 결과는 deny다. Tool client는 호출하지 않는다.
4. deny가 없고 `require_approval`이 있거나 Tool의 기본 위험 표시가 true면, **현재 `run_tool_decision.id`와 정확히 연결된** 유효 Approval을 확인한다. 명시적 allow는 Tool의 기본 승인 요구를 낮추지 않는다. 없으면 새 Decision을 남기고 승인 대기로 보낸다.
5. deny·승인 필요가 없고 명시적 allow가 있을 때만 실행 시도를 만든다. 일치한 Policy가 하나도 없으면 기본값은 deny다.

예를 들어 support 프로젝트에서는 티켓 생성 allow가 있어도, production이고 우선순위가 high 이상이면 더 높은 `require_approval` 규칙이 맞을 수 있다. 반대로 production 전체를 막는 deny가 있다면 allow보다 deny가 이긴다. 중요한 것은 “정책을 많이 쓰는 것”이 아니라, 새 규칙을 추가해도 결과가 예측 가능하다는 점이다.

`Run`을 만든 뒤 Policy가 바뀌는 경우도 있다. 7월 27일 재실행 글에서처럼 과거 설정을 비교용으로 식별할 수는 있지만, 새 Tool 호출을 옛 allow로 실행하면 안 된다. runner는 큐에서 꺼낼 때와 Tool client 바로 앞에서 현재 enabled revision을 다시 평가한다. 앞의 decision과 결과가 다르면 두 decision을 남기고, 더 엄격해진 결과를 따른다.

## 승인된 Run과 승인된 Tool 호출은 다를 수 있다

7월 20일의 승인 API는 Run 전체를 감사 가능한 상태 전이로 만드는 문제를 다뤘다. 이 글은 그 다음 경계다. Run이 문서 검색과 티켓 생성을 함께 계획했다면, 문서 검색은 즉시 allow일 수 있고 티켓 생성만 승인 대상일 수 있다. Run 하나를 승인했다고 모든 Tool이 자동으로 허용된다고 해석하면 권한 범위가 너무 넓어진다.

첫 구현에서는 Policy가 `require_approval`을 냈거나 Tool의 기본 위험 표시가 true일 때 `Approval.run_tool_decision_id`를 **필수**로 연결한다. 승인 화면에는 Tool 이름, 정제된 대상 설명, Policy revision, reason code를 보낸다. 승인자는 프롬프트 원문이나 비밀값이 아니라 “production support 프로젝트에 high 티켓을 생성하려는 요청”처럼 판단에 필요한 요약만 본다. 같은 Run의 다른 Tool Decision에는 이 Approval을 재사용하지 않는다.

승인 후에도 runner는 Policy revision을 다시 읽는다. 승인 대기 중 production Tool이 전면 deny로 바뀌었다면 기존 Approval을 실행 권한으로 사용하지 않고 `blocked_policy_changed`로 끝낸다. 이때 Approval을 삭제하지 않고, 당시 사람의 결정과 현재 정책으로 막힌 사실을 함께 남긴다. 호출 직전에는 `run_tool_decision_id`를 참조하는 `tool_execution_attempt`를 먼저 확정하고 runner만 이를 소비한다. 외부 호출 뒤에는 같은 attempt ID를 StepLog에 기록한다. 그래서 외부 호출은 성공했지만 로그 저장이 실패한 경우도 재시도·감사 대상임을 분리해 찾을 수 있다.

## 선택하지 않은 방식과 적용하지 않을 조건

첫 번째 대안은 Tool의 `requires_approval` boolean만 사용하는 방식이다. 읽기와 쓰기 정도만 있는 개인 도구에는 충분할 수 있다. 하지만 Agent별 범위와 환경 조건을 표현할 수 없고, boolean을 false로 바꾼 사람이 어떤 호출을 넓혔는지 설명하기 어렵다.

두 번째 대안은 Agent마다 고정 role을 하나 부여하는 방식이다. 구현은 단순하지만 `ticket-writer` role이 production의 어느 프로젝트·우선순위까지 가능한지 다시 role을 쪼개야 한다. 이 글의 작은 조건 JSON은 role 체계를 대체하려는 것이 아니라, 호출 맥락이 필요한 Tool에만 제한적으로 쓴다.

세 번째 대안은 모델 프롬프트에 “production 티켓을 만들지 마라”라고만 쓰는 것이다. 품질 가이드로는 필요하지만 집행 장치가 아니다. 모델이 잘못된 계획을 만들거나 Tool 호출 코드가 다른 경로를 타면 막지 못한다.

반대로 Tool이 하나뿐이고 항상 읽기 전용이며 대상 범위도 없는 개인 실험이라면 revision·decision 테이블까지 도입하는 비용이 과할 수 있다. 그 경우에도 Tool endpoint 안에서 기본 deny와 서버 측 대상 검증은 남긴다. 이 설계는 범용 정책 언어, 조직 전체 IAM, 실제 AI 규제 준수 인증을 구현했다는 주장이 아니다.

## 주니어가 먼저 만들 다섯 가지 테스트

정책은 화면에서 “허용” 배지가 보이는지보다 runner가 실제 호출을 멈추는지로 검증한다. Tool client를 spy 또는 test double로 두고 다음을 확인한다.

1. 일치하는 Policy가 없는 `ticket.create` 요청은 deny이며 Tool client 호출 횟수가 0인지 확인한다.
2. support·development 범위의 explicit allow는 호출되고, 같은 요청이 production이면 `require_approval` 또는 deny로 바뀌는지 확인한다.
3. allow와 deny가 동시에 맞을 때 priority와 무관하게 deny가 선택되고, `run_tool_decision.reason_code`와 Policy revision ID가 남는지 확인한다.
4. `condition_json`에 `projectID` 같은 알 수 없는 키, 잘못된 enum, 다른 소유자의 프로젝트 ID를 넣으면 `POST /policies`가 저장 전에 거절하는지 확인한다.
5. 승인 대기 뒤 Policy를 deny로 변경하고 worker를 재개한다. 기존 Approval이 있어도 StepLog보다 먼저 `blocked_policy_changed`가 남고 Tool client가 호출되지 않아야 한다.

deny인데 외부 티켓이 만들어졌다면 첫 확인 지점은 프롬프트나 대시보드가 아니다. Tool client를 호출하는 runner 경로가 evaluator 결과를 강제하는지, 그리고 직접 호출 가능한 우회 endpoint가 없는지부터 본다. 여기서 `run_tool_decision`은 “정책은 deny였는데 실행이 됐다”와 “정책 평가 자체가 allow였다”를 나누는 첫 번째 증거가 된다.

AgentOps Board KR에서 좋은 권한 설계는 승인 버튼을 많이 만드는 일이 아니다. Tool의 기술 범위, Policy의 조건, Approval의 사람 판단, runner의 실제 집행을 분리해야 한다. 주니어 개발자가 첫 구현에서 지킬 기준은 명확하다. 일치 규칙이 없으면 deny하고, 모델이 준 대상은 서버에서 다시 만들며, 모든 실제 Tool 호출 바로 앞에서 정책을 확인한다.

## 참고한 공식 문서

- [OWASP Authorization Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Authorization_Cheat_Sheet.html)
- [NIST SP 800-207: Zero Trust Architecture](https://doi.org/10.6028/NIST.SP.800-207)
- [JSON Schema: Object validation](https://json-schema.org/understanding-json-schema/reference/object)
