---
title: "JD Proof의 액션 과제는 왜 매칭 점수만 보고 바로 생성하면 안 되는가"
date: 2026-08-10 08:55:00 +0900
tags: [JD Proof, API, PostgreSQL, Backend]
excerpt: "JD Proof의 POST /action-tasks/generate를 점수 기반 할 일 덮어쓰기 API가 아니라, 검토된 Requirement·Evidence·MatchScore에서 제안을 만들고 사용자가 실제 과제로 채택하게 하는 설계 기록입니다. 재생성·동시 클릭·근거 변경에서 무엇을 보존해야 하는지 설명합니다."
---

**사례 상태: 설계 시나리오.** 실제 사용자의 과제 생성 기록이나 측정 결과가 아니다. JD Proof의 `JobPost`, `Requirement`, `PortfolioProject`, `Evidence`, `MatchScore`, `ActionTask` 모델과 `GET /matches?jobPostId=`, `POST /action-tasks/generate`, `PATCH /action-tasks/:id` API를 바탕으로 한다. `MatchScore.reason_json`의 후보와 `Evidence.verified`를 확인한다는 전제에서, 아래 테이블과 응답은 통합 테스트로 검증할 계약이다.

## "이 공고에 맞춰 보완할 점"을 누른 뒤 생기는 문제

JD Proof 화면에서 사용자는 공고 하나와 포트폴리오 프로젝트 하나를 고른 뒤 “보강 과제 만들기”를 누른다. 예를 들어 공고에는 `Spring Boot 운영 경험`이 있고, 프로젝트의 README에는 API 구현 근거가 있지만 운영 지표나 장애 대응 근거는 없다고 보자. 서비스는 “README에 health check와 장애 대응 절차를 추가하기”라는 제안을 만들 수 있다.

처음에는 `MatchScore.score`가 낮으면 곧바로 `ActionTask`를 INSERT하면 간단해 보인다. 하지만 같은 버튼을 두 번 눌렀을 때 과제가 두 개 생기면 사용자는 어느 것을 끝내야 하는지 모른다. 며칠 뒤 GitHub 동기화로 Evidence 발췌문이 바뀌었는데 예전 점수로 만든 과제가 그대로라면, 과제가 아직 유효한지도 설명하기 어렵다. 더 나쁜 경우는 사용자가 과제 제목·마감일·상태를 직접 조정했는데 재생성이 그 값을 덮어쓰는 경우다.

여기서 구분할 것은 “모델이나 규칙이 추천한 문장”과 “사용자가 실제로 하기로 한 일”이다. 점수는 우선순위를 정하는 신호일 수 있지만, 근거 자체도 아니고 할 일의 소유권도 아니다. 이번 설계의 결정은 **생성 요청은 먼저 재현 가능한 제안 묶음을 만들고, 사용자가 채택한 뒤에만 기존 `ActionTask`를 만든다**는 것이다.

## 기존 모델을 어떻게 확장할 것인가

프로젝트의 기본 `ActionTask(id, job_post_id, project_id, title, priority, due_date, status)`는 사용자가 관리하는 실제 할 일로 유지한다. 이 글의 확장에서는 어떤 Requirement에서 출발한 과제인지 연결할 `requirement_id`를 추가한다. 여기에 생성 과정을 설명하기 위한 두 테이블을 더한다. 이름이 비슷해 보여도 책임은 다르다.

| 대상 | 답하는 질문 | 수정 주체 |
| --- | --- | --- |
| `MatchScore` | 이 공고와 프로젝트의 연결을 어떻게 평가했는가 | 평가·검토 흐름 |
| `action_task_generation` | 어떤 입력 묶음으로 이번 제안을 만들었는가 | 서버 |
| `action_task_suggestion` | 이번 입력에서 어떤 보강 일을 제안했는가 | 서버, 사용자가 채택·폐기 |
| `ActionTask` | 사용자가 실제로 하기로 한 일은 무엇인가 | 사용자와 `PATCH /action-tasks/:id` |

`action_task_generation`에는 `MatchScore`의 숫자만 넣지 않는다. 선택한 `job_post_id`, `project_id`, 매칭 결과 ID, `reason_json`에서 찾은 Requirement·Evidence 식별자, `Evidence.verified` 값, 서버가 선택한 생성 규칙 버전으로 canonical JSON을 만든 뒤 `input_hash`를 저장한다. canonical JSON은 같은 의미의 입력이 항상 같은 순서와 형식으로 직렬화된 값이다. 이 hash는 원문을 복구하거나 진실을 증명하는 값이 아니라, “이번 제안이 어느 입력에서 나왔는가”를 비교하는 표식이다.

기존 행이 있으면 `requirement_id`를 즉시 `NOT NULL`로 더면 migration이 실패할 수 있다. 먼저 nullable 열과 `(id, job_post_id)` 복합 unique 제약을 추가하고 기존 ActionTask를 보정한 뒤, 외래 키와 `NOT NULL`을 적용한다. 아래는 그 뒤의 목표 스키마다.

```sql
ALTER TABLE requirement
  ADD CONSTRAINT requirement_id_job_post_key UNIQUE (id, job_post_id);

ALTER TABLE match_score
  ADD CONSTRAINT match_score_id_job_post_project_key
  UNIQUE (id, job_post_id, project_id);

CREATE TABLE action_task_generation (
  id UUID PRIMARY KEY,
  job_post_id UUID NOT NULL REFERENCES job_post(id),
  project_id UUID NOT NULL REFERENCES portfolio_project(id),
  match_score_id UUID NOT NULL,
  input_hash CHAR(64) NOT NULL,
  rule_version VARCHAR(40) NOT NULL,
  status VARCHAR(20) NOT NULL
    CHECK (status IN ('requested', 'ready', 'rejected', 'failed')),
  created_at TIMESTAMPTZ NOT NULL,
  UNIQUE (id, job_post_id),
  UNIQUE (job_post_id, project_id, input_hash, rule_version),
  FOREIGN KEY (match_score_id, job_post_id, project_id)
    REFERENCES match_score (id, job_post_id, project_id)
);

CREATE TABLE action_task_suggestion (
  id UUID PRIMARY KEY,
  generation_id UUID NOT NULL,
  job_post_id UUID NOT NULL,
  requirement_id UUID NOT NULL,
  title TEXT NOT NULL,
  priority VARCHAR(10) NOT NULL CHECK (priority IN ('high', 'medium', 'low')),
  rationale_json JSONB NOT NULL,
  status VARCHAR(20) NOT NULL
    CHECK (status IN ('proposed', 'accepted', 'discarded', 'superseded')),
  UNIQUE (generation_id, requirement_id),
  FOREIGN KEY (generation_id, job_post_id)
    REFERENCES action_task_generation (id, job_post_id),
  FOREIGN KEY (requirement_id, job_post_id)
    REFERENCES requirement (id, job_post_id)
);

ALTER TABLE action_task
  ADD COLUMN requirement_id UUID;

-- 기존 ActionTask의 출처를 보정한 뒤에만 아래 두 단계를 실행한다.

ALTER TABLE action_task
  ADD CONSTRAINT action_task_requirement_fk
  FOREIGN KEY (requirement_id, job_post_id)
  REFERENCES requirement (id, job_post_id);

ALTER TABLE action_task
  ALTER COLUMN requirement_id SET NOT NULL;
```

`action_task_suggestion.job_post_id`를 따로 둔 이유가 중요하다. ID마다 외래 키만 걸면 두 ID의 존재만 보장하고 같은 공고 소속은 보장하지 않는다. 같은 이유로 generation은 MatchScore가 해당 공고·프로젝트 쌍에 속하는지도 복합 외래 키로 확인한다. suggestion의 복합 외래 키는 generation과 Requirement의 공고가 같을 때만 저장한다. `UNIQUE (generation_id, requirement_id)`는 한 생성 안의 중복 후보를 막는다. 반면 `Evidence.verified`처럼 여러 행의 현재 상태는 생성 트랜잭션과 API가 확인해야 한다. [PostgreSQL 제약조건 문서](https://www.postgresql.org/docs/current/ddl-constraints.html)는 UNIQUE와 foreign key의 역할을 설명한다.

## 생성 API의 입력은 점수 하나가 아니다

`POST /action-tasks/generate`는 클라이언트가 제목과 priority를 보내서 저장하는 API가 아니다. 클라이언트가 선택한 공고·프로젝트·화면에서 본 매칭 결과 버전을 보내면 서버가 다시 현재 상태를 확인한다. 제안 문장을 만드는 규칙이나 LLM은 그 뒤에만 둔다.

```http
POST /action-tasks/generate
Content-Type: application/json

{
  "jobPostId": "job_backend_42",
  "projectId": "project_api_server",
  "matchScoreId": "match_171",
  "matchInputHash": "8c4e..."
}
```

서버는 다음 순서로 처리한다. 첫째, 로그인한 사용자가 해당 공고와 프로젝트를 볼 수 있는지 확인한다. 둘째, `matchScoreId`가 두 ID에 실제로 속하는지, 화면이 전달한 `matchInputHash`가 현재 매칭 입력과 같은지 확인한다. 셋째, `reason_json`이 가리킨 Requirement·Evidence가 각각 해당 공고·프로젝트에 속하는지, Evidence가 `verified=true`인지 확인한다. 하나라도 확인되지 않으면 그 항목은 과제 후보로 승격하지 않는다.

넷째, 서버가 새 hash를 계산하고 `rule_version`은 요청이 아니라 서버 배포 설정에서 선택한다. 같은 입력 generation이 이미 있으면 `requested`여도 그 ID를 돌려준다. 동시 요청은 `INSERT ... ON CONFLICT DO NOTHING` 뒤 새 SELECT로 기존 행을 읽는다. Read Committed는 statement마다 새 snapshot을 잡기 때문이다. 화면의 hash가 현재 값과 다르면 새 과제를 만들지 않고 `409 Conflict`와 새로고침 정보를 돌려준다. RFC 9110에서 409는 현재 리소스 상태와 충돌해 재요청으로 해결할 수 있는 경우다. [RFC 9110의 409 정의](https://www.rfc-editor.org/rfc/rfc9110.html#status.409)가 근거다.

```json
{
  "code": "stale_match_input",
  "message": "근거 또는 요구사항이 바뀌어 과제를 생성하지 않았습니다.",
  "currentMatchScoreId": "match_188",
  "refreshRequired": true
}
```

이 응답은 “생성에 실패했다”가 아니라, 사용자가 보던 판단 근거가 더는 현재 것이 아니라는 뜻이다. 자동으로 최신 점수로 바꿔 생성하면 편해 보이지만, 사용자는 다른 근거와 우선순위를 보고 있었을 수 있다. 새 화면에서 근거를 다시 열어 본 뒤 생성하는 편이 안전하다.

## 제안 채택과 실제 과제를 같은 INSERT로 묶지 않는다

generation이 `ready`가 되면 화면은 후보 목록과 각 후보가 연결한 Requirement·Evidence 요약을 보여 준다. 사용자는 후보를 `accepted` 또는 `discarded`로 바꾼다. 현재 프로젝트 API 목록에는 채택 endpoint가 없으므로, 이 설계는 `POST /action-task-suggestions/:id/accept`를 **제안하는 API 확장**으로 둔다. 기존 `PATCH /action-tasks/:id`는 이미 만들어진 사용자의 과제를 수정하는 용도로 그대로 남긴다. 새 accept 요청이 하나의 트랜잭션에서 suggestion 상태와 `ActionTask`를 함께 확정한다.

```sql
CREATE UNIQUE INDEX one_open_task_per_requirement
  ON action_task (job_post_id, project_id, requirement_id)
  WHERE status IN ('todo', 'doing');

-- accept 처리의 핵심: suggestion을 잠근 뒤 ActionTask를 한 번만 만든다.
SELECT * FROM action_task_suggestion WHERE id = :suggestion_id FOR UPDATE;

INSERT INTO action_task (id, job_post_id, project_id, requirement_id,
                         title, priority, status)
VALUES (:task_id, :job_post_id, :project_id, :requirement_id,
        :title, :priority, 'todo')
ON CONFLICT DO NOTHING;
```

두 브라우저 탭에서 같은 후보를 채택해도 partial unique index가 열린 동일 Requirement 과제를 하나로 제한한다. `ON CONFLICT DO NOTHING` 뒤에는 새 SELECT로 기존 과제 ID를 응답한다. Read Committed에서는 충돌 행이 INSERT의 최초 snapshot에 보이지 않아도 다음 SELECT는 새 snapshot을 쓰므로 같은 트랜잭션에서 재조회할 수 있다. “0행 INSERT면 없는 과제”라고 판단하지 말고 insert·조회 결과를 함께 처리한다. DB 오류·rollback처럼 행을 확정하지 못한 경우만 전체 요청을 재시도한다. [PostgreSQL 트랜잭션 격리 문서](https://www.postgresql.org/docs/current/transaction-iso.html)의 동작과 맞춘다.

중요한 경계는 재생성이다. 새 Evidence가 동기화되면 새 generation과 새 suggestion은 만들 수 있다. 그러나 기존 `ActionTask`의 제목·마감일·`doing` 상태를 generator가 UPDATE하지 않는다. 이미 사용자가 할 일로 채택한 행은 사용자의 업무 기록이다. 새 제안이 더 적절하면 `superseded`라는 이유와 함께 보여 주고, 사용자가 기존 과제를 수정·완료·새로 채택하도록 한다.

## 선택하지 않은 두 방식과 적용하지 않을 때

첫 번째 대안은 `POST /action-tasks/generate`가 바로 `ActionTask`를 생성하고, 다음 생성 때 같은 행을 UPDATE하는 방식이다. 테이블 수는 적고 화면도 빠르게 만들 수 있다. 그러나 추천 규칙 변경, 근거 변경, 사용자의 직접 수정이 한 행에서 섞인다. “이 과제는 어떤 근거로 생겼나”와 “누가 마감일을 바꿨나”를 구분하기 어려워서 선택하지 않았다.

두 번째 대안은 매칭 점수 임계값만 두고, 예를 들어 70점 미만이면 모든 Requirement를 과제로 만드는 방식이다. 초기 데모에서 후보를 빠르게 채우기에는 좋다. 하지만 점수는 프로젝트 전체의 요약이고, `Evidence.verified=true`인 Requirement까지 같은 우선순위로 내보낼 수 있다. JD Proof가 보여 주려는 것은 부족한 키워드 목록이 아니라 근거를 열어 볼 수 있는 보강 제안이므로, Requirement 단위의 Evidence 확인 여부를 먼저 본다.

반대로 개인 포트폴리오 하나에 대해 한 번만 수동으로 할 일을 적는 작은 도구라면 generation·suggestion 테이블까지 만들 필요는 없다. 이 설계는 여러 번의 공고 동기화, 과제 재생성, 사용자의 진행 상태 보존이 필요한 경우의 비용을 감수하는 선택이다. LLM이 만든 모든 문장을 정확한 과제로 보장하거나, 자동으로 지원 우선순위를 결정하는 기능도 이 범위에 넣지 않는다.

## 구현 전에 할 다섯 가지 검증

이 설계는 생성 문장이 자연스러운지보다, 오래된 근거와 중복 클릭이 사용자의 할 일을 망치지 않는지 먼저 검증해야 한다.

1. 같은 공고·프로젝트·입력 hash로 generate를 두 번, 또 동시에 두 번 호출해 generation과 suggestion이 각각 한 묶음만 생기고 모두 같은 generation ID를 받는지 확인한다.
2. 화면이 `match_171`을 읽은 뒤 `reason_json`이 가리키는 Evidence의 확인 값 또는 입력을 바꾸고 generate를 호출한다. `409 stale_match_input`이 오며 generation이 새로 생기지 않는지 확인한다.
3. `verified=false`인 Evidence만 가리키는 Requirement는 suggestion에 포함되지 않는지 확인한다. 후보가 0개여도 generation은 `ready`와 빈 목록으로 끝낼지, `rejected`로 끝낼지 제품 계약에서 하나로 정하고 테스트한다.
4. 같은 suggestion의 accept 요청을 두 트랜잭션에서 동시에 실행한다. 열려 있는 `ActionTask`가 하나만 남고, 두 응답이 같은 task ID 또는 명확한 이미-채택됨 결과를 주는지 확인한다.
5. 사용자가 생성된 ActionTask의 title·due_date·status를 수정한 뒤 입력을 바꿔 다시 generate한다. 새 suggestion은 생기되 기존 ActionTask의 값이 변경되지 않는지 확인한다.

과제가 중복됐다면 첫 확인 지점은 LLM 프롬프트나 점수 계산식이 아니다. 먼저 `action_task_generation.input_hash`, suggestion의 status, partial unique index와 복합 외래 키가 실제 migration에 존재하는지, accept 요청이 동일 트랜잭션인지 확인한다. 과제가 오래됐다면 generation의 input hash와 현재 `MatchScore`·`Evidence.verified` 값이 어떤 지점에서 달라졌는지부터 비교한다. 이 두 조회가 있으면 "추천이 이상하다"를 재생성 중복, 근거 변경, 사용자의 직접 수정 중 어느 문제인지 나눌 수 있다.

JD Proof의 액션 과제는 낮은 점수의 부산물이 아니다. 검토된 Requirement와 Evidence를 바탕으로 만든 제안, 사용자가 채택한 실제 업무, 나중에 바뀐 근거를 분리해야 한다. 주니어 개발자가 첫 구현에서 지킬 기준은 세 가지다. 생성 입력을 hash와 ID로 남기고, 제안은 실제 과제와 분리하며, 재생성이 사용자의 진행 상태를 덮어쓰지 못하게 한다.

## 참고한 공식 문서

- [PostgreSQL: Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)
- [PostgreSQL: Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)
- [RFC 9110: 409 Conflict](https://www.rfc-editor.org/rfc/rfc9110.html#status.409)
