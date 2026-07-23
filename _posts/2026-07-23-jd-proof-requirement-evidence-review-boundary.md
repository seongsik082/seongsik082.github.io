---
title: "JD Proof의 매칭 점수는 왜 Requirement와 Evidence를 분리한 뒤에 계산해야 하는가"
date: 2026-07-23 08:55:00 +0900
tags: [LLM, API, PostgreSQL, Backend]
excerpt: "JD Proof에서 채용공고의 Requirement와 포트폴리오의 Evidence를 분리해 저장하고, 근거를 열어 볼 수 있는 MatchScore를 만드는 설계 기록입니다. 추출 결과·지원 근거·사람의 검토를 한 점수에 섞지 않는 이유와 검증 절차를 설명합니다."
---

**사례 상태: 설계 시나리오.** 운영 기록이 아니다. JD Proof의 `JobPost`, `Requirement`, `PortfolioProject`, `Evidence`, `MatchScore` 모델과 `GET /job-posts/:id/requirements`, `POST /projects/sync-github`, `GET /matches?jobPostId=` API를 바탕으로 한 설계 기록이다. LLM 호출·동기화·점수 산출은 미구현이므로, 아래 SQL과 응답은 검증할 계약이다.

## 점수가 틀렸다는 문의는 대개 숫자부터 시작하지 않는다

채용공고에 “Kubernetes 환경에서 배포 경험”이 있고, 포트폴리오 README에는 “Docker Compose로 로컬 실행”만 적혀 있다고 해 보자. 단어 유사도만 높게 나온 화면은 둘 다 컨테이너 기술이므로 어느 정도 관련 있다고 말할 수 있다. 하지만 지원자가 “왜 Kubernetes 경험으로 표시됐나요?”라고 물으면, 서비스는 숫자 74점보다 먼저 **어느 공고 문장을 어떤 저장소의 어느 링크가 뒷받침했는지** 보여 줄 수 있어야 한다.

흔한 지름길은 공고 원문과 README를 LLM에 한 번 넣고 `{ score: 74, reason: "관련 경험 있음" }`을 저장하는 방식이다. 데모는 빠르지만 요구사항·근거·모델 판단이 한 JSON에 섞여, 링크가 바뀐 뒤 무엇을 다시 계산·검토할지 알기 어렵다.

JD Proof가 만들려는 가치는 단순 추천이 아니라 “이 공고를 위해 프로젝트 A를 어떻게 보강할까”라는 실행 가능한 피드백이다. 그러려면 매칭 결과는 결론 화면이 아니라 검토 가능한 주장이어야 한다. 이번 결정은 **Requirement는 공고가 요구한 사실, Evidence는 프로젝트에 실제로 존재하는 확인 대상, MatchScore는 둘을 연결한 잠정 평가**로 역할을 나누는 것이다.

## 먼저 고정할 세 가지 질문

`Requirement`는 “공고가 무엇을 원했는가”, `Evidence`는 “지원자가 무엇을 제시했는가”, `MatchScore`는 “둘이 어느 정도 연결되는가”에 답한다. 이를 분리하면 모델 문장 하나가 지원자의 역량 사실이 되는 일을 막을 수 있다.

| 항목 | JD Proof에서 맡는 책임 | 화면에서 사용자가 확인할 값 |
| --- | --- | --- |
| `Requirement` | 공고 원문에서 추출·정규화한 요구 | 원문 인용, category, skill, importance, `evidence_rule` |
| `Evidence` | 저장소 README·커밋·데모 링크에서 찾은 확인 대상 | project, type, path 또는 URL, excerpt, `verified` |
| `MatchScore` | 특정 공고와 프로젝트를 연결한 평가 | score, `reason_json`, 연결된 requirement/evidence 식별자, 검토 상태 |

포트폴리오 기획에는 `Requirement(id, job_post_id, category, skill, importance, evidence_rule)`와 `Evidence(id, project_id, type, path_or_url, excerpt, verified)`가 이미 분리돼 있다. 여기서 `Evidence.verified`는 **현재 링크와 발췌문을 다시 열어 보고, 저장된 출처가 실제로 존재하는지 확인했는가**만 뜻한다. 특정 Requirement를 충족한다는 판단은 `match_evidence.review_status`의 책임이다. 링크가 살아 있다는 것과 요구사항 충족은 다른 판단이다.

예를 들어 `Requirement.skill = 'Kubernetes'`인데 README 발췌문에 Docker만 있으면 Evidence 행은 유효하게 저장한다. 그러나 관계는 `needs_review`이지 `matched`가 아니다. 실제 매니페스트 경로가 `evidence_rule`을 만족할 때만 줄 위치를 남겨 검토 후보로 올린다.

## API는 모델의 답을 바로 반환하지 않고 검토 화면을 만든다

첫 번째 산출물은 공고 요구사항 API다. 공고 업로드 뒤 파서 결과는 확정 사실처럼 보이면 안 된다. `GET /job-posts/:id/requirements`는 원문 문장·추출값·검토 상태를 함께 돌려준다.

```http
GET /job-posts/jp_01/requirements
```

```json
{"id":"req_08","skill":"Kubernetes","sourceQuote":"Kubernetes 환경 배포 경험 우대","reviewStatus":"needs_review"}
```

`sourceQuote`가 있으면 사용자는 어떤 공고 문장 때문에 `skill` 수정이 필요한지 볼 수 있다. JSON Schema는 `category`, `skill`, `sourceQuote`의 필수 여부·타입과, 필요하면 `minLength` 같은 형식 제약을 검사한다. 통과했다고 공고 의도를 정확히 읽었다는 뜻은 아니다.

두 번째 산출물은 GitHub 동기화 경계다. `POST /projects/sync-github`가 README·커밋·데모 링크를 읽어 `Evidence` 후보를 만들더라도 MatchScore를 확정해서는 안 된다. 구현 시 `Evidence`에 정규화한 원문에서 계산한 `source_hash`를 추가한다. 같은 `project_id`, `type`, `path_or_url`의 hash가 달라졌다면 새 근거가 아니라 **기존 근거의 새 버전**으로 보고 발췌문·hash를 갱신하고 `verified=false`로 되돌린다. 연결 권한과 수집 범위에 동의하지 않았다면 동기화 기능을 제공하지 않는다.

동기화 뒤에는 새 후보의 `Evidence.verified`를 `false`로 두고, 변경된 Evidence와 연결된 `match_evidence`만 재검토 대기열에 넣는다. `GET /matches?jobPostId=jp_01`은 Requirement별 후보 Evidence와 `reason_json`을 주되, 사람이 확인한 관계가 없으면 최종 점수를 확정하지 않는다.

`Evidence.verified = false`는 실패가 아니라 출처 미확인 상태다. 검토자는 먼저 URL·발췌문·수집 범위를 확인해 이 값을 `true`로 바꾼다. 그다음 Requirement와의 관계를 열어 `match_evidence.review_status`를 검토한다. 후보 점수는 정렬에 쓸 수 있어도, **Evidence가 verified이고 관계가 verified이며 relation이 `supports`인 경우에만** “충족” 표시나 `ActionTask` 완료를 허용한다. `partial`은 보강 과제를 만들 수 있지만 충족으로 올리지 않는다. NIST AI RMF가 말하는 인간의 역할·검증 구분을 이 작은 경계로 적용한다.

## DB는 점수보다 연결의 재검증 가능성을 지켜야 한다

기획의 `MatchScore(id, job_post_id, project_id, score, reason_json)`만으로 프로젝트 단위 점수는 만들 수 있다. 하지만 근거를 보여 주려면 requirement와 evidence를 잇는 행이 필요하다. 아래 `match_evidence`는 구현 때 검토할 세부 근거 초안이고, `MatchScore`는 그 요약이다.

```sql
CREATE TABLE match_evidence (
  id UUID PRIMARY KEY,
  requirement_id UUID NOT NULL REFERENCES requirement(id),
  evidence_id UUID NOT NULL REFERENCES evidence(id),
  relation VARCHAR(20) NOT NULL
    CHECK (relation IN ('supports', 'partial', 'does_not_support')),
  review_status VARCHAR(20) NOT NULL
    CHECK (review_status IN ('needs_review', 'verified', 'rejected')),
  source_hash_at_review CHAR(64) NOT NULL,
  reason_json JSONB NOT NULL,
  reviewed_at TIMESTAMPTZ,
  reviewer_id UUID,
  created_at TIMESTAMPTZ NOT NULL,
  UNIQUE (requirement_id, evidence_id)
);
```

`UNIQUE (requirement_id, evidence_id)`는 동기화 재시도에 따른 중복 연결을 막는다. `source_hash_at_review`는 관계를 검토한 Evidence 버전이다. 동기화 transaction에서 현재 `Evidence.source_hash`와 이 값이 다르면 해당 연결을 `needs_review`로 되돌리고 `reviewed_at`, `reviewer_id`를 비운다. `CHECK`는 상태 문자열 오타를 막지만 reviewer 권한처럼 다른 행·테이블의 상태를 보장하지는 못한다.

Requirement의 `skill`·`evidence_rule`이 바뀌어도 연결 행은 `needs_review`로 되돌린다. 이 전환과 Evidence hash 비교를 하나의 동기화 transaction으로 처리해야, 새 발췌문인데 옛 관계가 verified로 남지 않는다. 사람이 관계를 다시 `verified`로 바꾸기 전 `ActionTask`는 “확인 필요”로만 만든다.


## 비교했던 대안과 선택하지 않은 이유

첫 번째 대안은 **공고와 README의 임베딩 유사도만으로 점수를 만드는 방식**이다. 문서가 많을 때 후보를 줄이는 용도로는 좋지만, “Kubernetes”와 “Docker”처럼 인접한 단어도 높게 나올 수 있고 파일 근거를 설명하기 어렵다. JD Proof에서는 유사도를 `reason_json`의 후보 신호로만 둔다.

두 번째 대안은 **LLM 출력 JSON을 Evidence로 간주하는 방식**이다. 구현량은 적지만 모델 요약은 저장소 산출물이 아니다. `model_summary`는 파생 데이터일 뿐 README·커밋·데모 링크를 대체할 수 없고, 재실행 뒤 무엇이 변했는지도 설명하기 어렵다.

세 번째 대안은 **사람이 모든 Requirement와 Evidence를 직접 입력하는 방식**이다. 공고 수가 적고 품질이 최우선이면 타당하지만, 업로드·동기화가 주는 시간 절약을 잃는다. 그래서 후보 연결은 자동화하고 확정·액션 생성은 검토 뒤에 한다.

## 이 설계를 적용하지 않을 조건

이 구조는 합격 가능성이나 지원자 역량을 자동 판정하는 데 쓰면 안 된다. 점수는 포트폴리오 보강 순서를 돕는 신호이지 탈락·순위 확정 근거가 아니다. 근거를 검토할 사람이 없고 개인 메모로만 쓴다면 `match_evidence` 정규화 비용이 과할 수 있지만, 그때도 원문 링크와 “자동 추출 초안” 표시는 남긴다.

비공개 저장소·채용공고 원문·개인 식별 정보가 섞이는 환경도 별도 정책 없이는 대상이 아니다. 수집 범위, 보관 기간, 삭제 요청, 접근 권한을 먼저 정하지 못했다면 기능을 제한해야 한다. 이 글은 그러한 개인정보·외부 제공자 권한 설계를 완료했다고 주장하지 않는다.

## 구현 전에 할 수 있는 검증: 한 점이 아니라 연결을 테스트한다

첫 검증은 모델 응답을 많이 받는 실험이 아니다. 작은 고정 데이터로 Requirement와 Evidence가 섞이지 않는지 보는 통합 테스트다. PostgreSQL을 쓴다면 실제 migration을 적용한 테스트 DB에서 재현한다.

1. 공고 문장 “Kubernetes 환경 배포 경험 우대”를 넣어 `Requirement` 한 행과 `sourceQuote`를 만든다. JSON Schema 검증은 필수 필드 누락을 막고, 서비스 테스트는 원문 인용이 빈 문자열이면 저장하지 않는지 확인한다.
2. Docker Compose만 적힌 README 발췌문으로 `Evidence(verified=false)`를 저장한다. `match_evidence.relation = 'partial'`, `review_status = 'needs_review'`가 되고, 화면이 이를 “충족”으로 표시하지 않아야 한다.
3. Kubernetes manifest 경로를 가진 두 번째 Evidence를 추가한다. 먼저 링크·발췌문을 확인해 `Evidence.verified=true`로, 이어서 관계를 확인해 `match_evidence.review_status='verified'`·`relation='supports'`로 바꾼 뒤에만 보강 필요 상태가 해제되는지 검사한다.
4. 같은 동기화 요청을 다시 수행한다. `(requirement_id, evidence_id)` unique 제약 때문에 세부 근거가 중복되지 않는지, 원문 변경으로 `source_hash`가 달라지면 `source_hash_at_review`가 다른 연결이 `needs_review`로 돌아가는지 확인한다.
5. `GET /matches?jobPostId=` 응답에서 각 점수에 연결된 Requirement ID, Evidence URL, review 상태가 빠짐없이 있는지 계약 테스트로 확인한다. URL이나 발췌문이 없으면 score가 있어도 최종 상태를 만들지 않아야 한다.

2번이 “충족”으로 보이면 첫 확인 지점은 프롬프트가 아니다. `match_evidence.review_status`를 화면 쿼리가 읽는지와 `verified=false`를 final로 승격하는 조건을 먼저 본다. 4번 중복은 unique 제약과 Evidence 식별 기준을 확인한다.

JD Proof에서 좋은 매칭 점수는 정답을 단정하는 숫자가 아니다. 공고 요구·실제 근거·미검토 연결을 분리한 과정의 요약이다. 이 경계를 지키면 모델·규칙·임베딩을 바꿔도 사용자는 어느 문장과 링크가 판단에 쓰였는지 다시 확인할 수 있다.

## 참고한 공식 문서

- [PostgreSQL: Constraints](https://www.postgresql.org/docs/current/ddl-constraints.html)
- [JSON Schema: string validation](https://json-schema.org/understanding-json-schema/reference/string)
- [NIST AI RMF: Human-AI Interaction](https://airc.nist.gov/airmf-resources/airmf/appendices/app-c-ai-risk-management-and-human-ai-interaction/)
