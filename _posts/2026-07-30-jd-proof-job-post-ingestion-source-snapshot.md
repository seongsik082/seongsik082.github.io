---
title: "JD Proof의 채용공고 수집은 왜 URL·파일·파싱 결과를 한 JobPost에 덮어쓰면 안 되는가"
date: 2026-07-30 08:55:00 +0900
tags: [API, Security, PostgreSQL, Backend]
excerpt: "JD Proof의 공고 URL 수집과 파일 업로드를 비동기 요청, 원본 스냅샷, 추출 결과로 나누는 설계 기록입니다. 원문 변경·재처리·안전하지 않은 URL과 파일을 같은 흐름에서 다룰 때 무엇을 저장하고 어디서 중단해야 하는지 설명합니다."
---

**사례 상태: 설계 시나리오.** 이 글은 운영 장애 기록이 아니다. JD Proof의 `JobPost(id, title, company, source_url, raw_text, status)`, `Requirement`, `POST /job-posts/import-url`, `POST /job-posts/upload-file`, `GET /job-posts/:id/requirements` 설계를 바탕으로 한 구현 전 결정 기록이다. 아직 URL 수집기·파일 추출기·파서가 구현되지 않았으므로, 아래 API·SQL·상태 전이는 통합 테스트로 확인할 계약이다.

## 버튼은 둘인데, 서버가 맡는 일은 세 가지다

JD Proof 화면에는 “공고 URL 가져오기”와 “공고 파일 올리기” 버튼이 있다. 처음에는 두 요청이 끝나면 `JobPost.raw_text`를 채우고 `status='ready'`로 바꾸면 될 것처럼 보인다. 하지만 URL 본문은 바뀔 수 있고, 업로드 PDF의 실제 내용은 브라우저의 `Content-Type`과 다를 수 있다. 같은 URL을 두 번 눌렀을 때 어느 결과가 `raw_text`를 덮는지도 정해야 한다.

파서 v1이 “Java 17 경험”을 하나로 만들었는데 v2가 “Java 17”과 “Spring Boot”를 나눠 낸다면, 과거 매칭 점수는 어느 공고 본문을 기준으로 한 것일까? 원문·추출 텍스트·파싱 결과를 한 행에 덮어쓰면 이전 `Requirement`와 `MatchScore`의 근거를 다시 설명할 수 없다.

서버 책임은 세 가지다. 입력 접수에는 재시도 식별자를, 원본 확보에는 스냅샷·크기·해시를, 텍스트 추출에는 추출기 버전과 `Requirement` 출처를 남긴다. 그래야 같은 클릭인지, 파서가 무엇을 읽었는지, 왜 skill이 생겼는지 답할 수 있다.

이 글의 선택은 **`JobPost`를 화면에서 보는 공고의 안정적인 ID로 두고, 외부에서 받은 원본과 그 원본을 해석한 결과는 별도 행으로 남기는 것**이다. URL과 파일은 들어오는 방식만 다를 뿐, 원본을 저장하고 추출 worker가 읽는 뒤쪽 흐름은 합친다.

## 요청 응답은 완료가 아니라 접수 사실을 말해야 한다

JD Proof의 두 POST는 **접수된 새 처리 대상**을 만들고 `202 Accepted`를 돌려준다. RFC 9110의 202는 완료가 아니라 처리 접수이므로, `requirementsReady: true` 같은 값을 넣으면 안 된다.

```http
POST /job-posts/import-url
Content-Type: application/json

{ "sourceUrl": "https://careers.example.com/jobs/42" }
```

```http
HTTP/1.1 202 Accepted
Location: /job-posts/jp_01/ingestions/ing_01

{ "jobPostId": "jp_01", "ingestionId": "ing_01", "status": "received" }
```

파일 업로드도 같은 응답을 쓴다. 서버는 `Idempotency-Key`와 request hash를 저장해 같은 사용자·key·요청에는 같은 `ingestionId`를, 다른 입력에는 409을 돌려준다. 상태 API는 `received`부터 `ready`·`rejected`·`failed`까지를 보여 주되 내부 예외나 원문은 반환하지 않는다.

## JobPost에는 현재 화면을, 별도 행에는 근거를 둔다

기획의 `JobPost.raw_text`와 `status`만으로 데모를 만들 수는 있다. 그러나 그 값을 최신 원문으로 계속 UPDATE하면 파서 버전 변경이나 원본 변경 뒤에 과거 결과를 검토하기 어렵다. 구현할 때는 `JobPost`를 공고 보드의 ID로 유지하고, 수집한 문서와 추출 결과를 다음처럼 분리한다.

```sql
CREATE TABLE job_post_source (
  id UUID PRIMARY KEY, job_post_id UUID NOT NULL REFERENCES job_post(id),
  source_kind VARCHAR(10) NOT NULL CHECK (source_kind IN ('url', 'upload')),
  requested_url TEXT, stored_object_key TEXT NOT NULL,
  detected_content_type TEXT, byte_size BIGINT NOT NULL CHECK (byte_size >= 0),
  source_sha256 CHAR(64) NOT NULL, received_at TIMESTAMPTZ NOT NULL,
  UNIQUE (id, job_post_id), UNIQUE (job_post_id, source_sha256)
);

CREATE TABLE job_post_ingestion (
  id UUID PRIMARY KEY, actor_id UUID NOT NULL,
  job_post_id UUID NOT NULL REFERENCES job_post(id),
  idempotency_key UUID NOT NULL, request_hash CHAR(64) NOT NULL,
  status VARCHAR(20) NOT NULL CHECK (status IN ('received','fetching','stored','extracting','ready','rejected','failed')),
  source_id UUID, error_code VARCHAR(50), created_at TIMESTAMPTZ NOT NULL,
  UNIQUE (actor_id, idempotency_key),
  FOREIGN KEY (source_id, job_post_id) REFERENCES job_post_source(id, job_post_id)
);

CREATE TABLE job_post_extraction (
  id UUID PRIMARY KEY, job_post_id UUID NOT NULL REFERENCES job_post(id),
  source_id UUID NOT NULL, extractor_version VARCHAR(40) NOT NULL,
  normalized_text TEXT,
  status VARCHAR(20) NOT NULL CHECK (status IN ('extracting', 'ready', 'rejected', 'failed')),
  created_at TIMESTAMPTZ NOT NULL,
  FOREIGN KEY (source_id, job_post_id) REFERENCES job_post_source(id, job_post_id),
  UNIQUE (source_id, extractor_version), UNIQUE (job_post_id, id),
  CHECK ((status = 'ready' AND normalized_text IS NOT NULL) OR
         (status <> 'ready' AND normalized_text IS NULL))
);

ALTER TABLE job_post ADD COLUMN current_extraction_id UUID;
ALTER TABLE job_post ADD CONSTRAINT current_extraction_same_post
  FOREIGN KEY (id, current_extraction_id) REFERENCES job_post_extraction(job_post_id, id);
ALTER TABLE requirement ADD COLUMN extraction_id UUID;
ALTER TABLE requirement ADD CONSTRAINT requirement_extraction_same_post
  FOREIGN KEY (job_post_id, extraction_id) REFERENCES job_post_extraction(job_post_id, id);
```

`job_post_source`는 받은 원본의 **스냅샷**이다. URL 수집도 얻은 바이트를 서버가 만든 object key에 보관하고 SHA-256을 계산한다. `requested_url`은 추적용이며 원문 재구성 수단이 아니다.

`job_post_ingestion`이 202 응답의 `ingestionId`와 재시도 계약을 실제로 저장한다. `(actor_id, idempotency_key)`가 이미 있으면 서버는 request hash를 비교해 같을 때만 기존 결과를 반환하고, 다르면 409으로 끝낸다. `(source_id, job_post_id)` 복합 FK는 다른 공고의 source를 연결하는 실수를 막는다. 같은 바이트를 다른 key로 다시 접수하면 source는 공유될 수 있고 ingestion 이력은 둘 다 남는다.

`job_post_extraction`은 같은 원본을 어떤 버전으로 텍스트화했는지 기록한다. 추출기를 고친 뒤 새 `extractor_version` 결과를 추가할 수 있다. `ready`가 아니면 `normalized_text`는 NULL이고, ready일 때만 본문이 있어야 한다. `JobPost.current_extraction_id`는 transaction에서 같은 공고의 `status='ready'` 행만 선택하도록 갱신한다. 기본 요구사항 API는 이 값을 쓰고, 과거 추출 조회도 `?extractionId=`가 같은 공고의 ready 행인지 검사한다.

`job_post_extraction`에 `job_post_id`를 한 번 더 두는 이유는 두 단계 FK를 DB에서 묶기 위해서다. `Requirement(job_post_id, extraction_id)`와 `JobPost(id, current_extraction_id)`의 복합 FK는 다른 공고의 extraction을 가리키는 실수를 막는다. 기존 테이블은 nullable 열 추가 → 출처 backfill → 검증 뒤 `NOT NULL` 순서로 옮긴다.

`UNIQUE (job_post_id, source_sha256)`는 같은 바이트의 중복 스냅샷을 막는다. URL이 같아도 본문이 바뀌면 새 source가 되고, URL 문자열만 unique로 두면 실제 변경을 놓친다.

`JobPost.raw_text`는 migration 동안 현재 extraction의 `normalized_text`를 보여 주는 **읽기 전용 화면 캐시**로만 둔다. 매칭·검토·재처리 코드는 이 열을 읽지 않으며, migration이 끝나면 제거한다. `JobPost.status`도 요약 상태일 뿐이며 MatchScore는 어떤 `Requirement.extraction_id`를 썼는지 저장해야 한다.

## URL 가져오기는 작은 HTTP client가 아니라 권한 있는 외부 호출이다

`sourceUrl`을 받는 순간 서버는 사용자를 대신해 네트워크 요청을 보낸다. 그래서 단순한 URL 문자열 검증만으로 충분하지 않다. 잘못 설계하면 사용자가 JD Proof 서버를 경유해 내부 서비스나 메타데이터 주소를 읽게 하는 SSRF(Server-Side Request Forgery) 경로가 될 수 있다.

첫 구현에서는 지원하는 채용 사이트 도메인 allowlist를 두고 `https`만 받는 편을 권한다. 지원하지 않는 일반 URL을 “나중에 잘 가져오겠다”며 수집 worker에 넘기지 말고, 사용자가 파일 업로드나 텍스트 입력 같은 별도 경로를 쓰게 한다. 기능 범위는 좁아지지만 어떤 외부 시스템으로 요청을 보내는지 분명해진다.

URL worker는 URL 파싱 → https·지원 host 확인 → DNS A/AAAA의 공개 주소 확인 → redirect 없는 요청 → 크기 제한 안에서 바이트 저장 → 해시 계산 → 추출 queue 순서로 처리한다.

OWASP SSRF 가이드는 domain의 A·AAAA 주소 확인과 redirect 비허용을 권한다. 그러나 worker가 그 확인 뒤 일반 HTTP client에게 DNS 해석을 다시 맡기면, 연결 순간 주소가 바뀌는 DNS rebinding을 막지 못한다.

그래서 이 설계에서 worker의 외부 요청은 egress gateway 한 곳만 통과한다. gateway는 **연결 시점에** host를 해석하고, private·loopback·link-local·메타데이터 주소로 가는 연결을 거부한다. worker가 직접 socket을 열지 못하게 하는 네트워크 규칙이 이 검사 지점이다. URL validator는 빠른 거절을, gateway는 마지막 연결 강제를 맡는다.

응답의 `Content-Type: text/html`도 정답이 아니다. URL 수집에는 최대 크기, 연결·읽기 timeout, 허용 MIME type, 압축 해제 뒤 크기 제한을 둔다. 기준은 지원 형식과 worker 자원으로 정하고, 초과하면 원문을 응답에 돌려주지 않은 채 `rejected`로 끝낸다.

## 파일 업로드는 이름과 헤더를 신뢰하지 않는다

파일 경로에서는 사용자가 정한 파일명·확장자·Content-Type을 저장 경로의 근거로 쓰지 않는다. OWASP 파일 업로드 가이드도 allowlist 기반의 허용 형식, 파일 크기 제한, 서버가 만든 파일명, 웹 루트 밖 또는 분리된 저장소 보관을 권한다.

JD Proof의 첫 범위가 PDF와 plain text라면, `application/pdf`와 `text/plain`만 사업 규칙으로 허용한다. 요청 헤더의 MIME type은 빠른 안내에는 쓰되, 서버가 읽은 파일 signature와 추출기가 실제 처리 가능한 형식을 함께 확인한다. 둘이 다르면 추출 worker에 보내지 않는다. `resume-final.pdf`라는 이름은 화면 표시용 메타데이터일 뿐, 저장은 `sourceId`처럼 서버가 만든 key로 한다.

PDF가 안전한 텍스트만 담는 것은 아니다. 추출 프로세스에는 파일 크기·페이지 또는 처리 시간·메모리 상한을 두고, 실패하면 사유 코드만 남긴다. 검사나 sandbox를 바로 만들기 어렵다면 지원 형식을 더 줄인다.

## 비교했던 선택지와 이번 범위에서 피할 것

첫 번째 대안은 **controller가 임의 URL을 즉시 GET하고 파싱까지 끝내는 방식**이다. 구현은 짧고 작은 데모에서는 결과를 바로 보여 주기 쉽다. 그러나 HTTP 요청 시간과 파서 시간이 API 응답 시간을 결정하고, SSRF·redirect·파일 크기 검증이 business logic 사이로 흩어진다. JD Proof에서는 접수 API와 worker를 나누고 202 상태 리소스를 둔다.

두 번째 대안은 **원본을 버리고 `JobPost.raw_text`만 최신 값으로 보관하는 방식**이다. 저장 비용은 적지만, 원격 페이지 변경 뒤 파서 오류를 재현할 수 없고 Requirement가 어느 문장에서 나왔는지 검토하기 어렵다. 이 글의 설계는 원본 object와 extraction을 연결한다. 다만 원문 보관은 개인정보·저작권·보존 기간 정책이 필요한 비용이므로 무기한 저장을 기본으로 하지 않는다.

세 번째 대안은 **브라우저가 URL을 읽어 텍스트만 서버에 보내는 방식**이다. 서버의 외부 요청을 줄일 수 있지만, CORS와 로그인 페이지 때문에 수집 범위가 달라지고 사용자가 어느 시점의 어떤 원문을 보냈는지 검증하기 어렵다. 신뢰할 수 없는 일반 URL까지 지원하고 싶다면 이 우회 경로를 몰래 추가하기보다, 별도 텍스트 입력 기능의 신뢰 수준과 고지 문구를 설계해야 한다.

## 적용하지 않을 조건과 먼저 돌릴 테스트

이 설계는 모든 채용 URL을 크롤링하는 범용 수집기가 아니다. 지원 도메인 또는 원문 보관·삭제 정책을 정하지 못했다면 URL import를 열지 않는다. PDF 파서 취약점이나 외부 사이트 약관 문제까지 해결한다고 주장하지 않으며, 수집 대상 확대는 네트워크·보관·권한·허용 범위를 함께 검토한 뒤에만 한다.

구현을 시작하면 모델 품질보다 아래 다섯 가지를 먼저 통합 테스트로 확인한다.

1. URL과 파일 요청 모두 같은 형식의 `202`, `jobPostId`, `ingestionId`, 상태 조회 URL을 돌려주고, 요구사항이 준비되기 전에는 `GET /job-posts/:id/requirements`가 빈 성공 결과로 가장하지 않는지 확인한다.
2. 같은 Idempotency-Key·같은 요청을 두 번 보내도 ingestion 행과 source 행이 하나만 생기는지, 같은 key에 다른 URL을 넣으면 새 작업을 만들지 않고 409을 주는지 확인한다.
3. allowlist 밖 host, `http` URL, redirect 응답은 gateway 호출 전에 `rejected`인지 확인한다. resolver가 검사 뒤 private·link-local 주소를 돌려주는 DNS rebinding 상황도 gateway가 연결을 거부해야 한다. 이 실패의 **첫 확인 지점은 파서가 아니라 URL validator와 egress 규칙**이다.
4. PDF가 아닌 바이트에 PDF Content-Type만 붙인 파일, 크기 제한을 넘는 파일, 사용자 경로처럼 보이는 파일명을 각각 올린다. stored object key가 서버 생성값인지, 추출 queue에 들어가지 않는지 검사한다.
5. 같은 원본을 extractor v1·v2로 처리해 source는 하나, extraction은 두 개인지와 각 Requirement의 `extraction_id`를 확인한다. v2를 현재 화면으로 선택해도 v1 매칭 근거가 덮어써지면 안 된다.

JD Proof에서 공고 수집의 완료는 화면에 제목 하나를 보여 주는 시점이 아니다. 요청을 다시 보내도 같은 작업으로 묶이고, 파서가 읽은 원문을 식별할 수 있으며, 안전하지 않은 URL·파일은 추출 전에 멈춰야 한다. 주니어 개발자가 첫 구현에서 지킬 기준은 세 가지면 충분하다. `JobPost`에 원문을 덮어쓰지 말 것, 202을 완료로 표시하지 말 것, 외부 URL과 파일을 신뢰된 입력처럼 다루지 말 것.

## 참고한 공식 문서

- [RFC 9110: 202 Accepted](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.3)
- [OWASP: Server-Side Request Forgery Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [OWASP: File Upload Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html)
