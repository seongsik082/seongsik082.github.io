---
title: "JD Proof의 외부 계정 연결: PKCE와 state를 어디까지 검증해야 하는가"
date: 2026-07-19 08:50:00 +0900
tags: [Security, OAuth2, PKCE, Backend]
excerpt: "JD Proof가 GitHub 저장소 메타데이터를 동기화할 때, callback 요청에서 state·redirect URI·만료를 확인하고 token은 서버에서 암호화해 저장하는 경계를 설계 시나리오로 정리합니다."
---

## 문제 상황: 저장소 동기화 버튼 하나가 여는 경계

**사례 상태: 설계 시나리오.** 이 글은 JD Proof의 `POST /projects/sync-github` 요구사항, 즉 사용자의 포트폴리오 저장소 메타데이터를 읽어 `README`, 커밋, 데모 링크를 근거로 연결하는 흐름을 바탕으로 한다. 아직 구현·운영 중인 코드가 아니며, PKCE와 callback의 규칙은 [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636.html)과 [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700.html)을 근거로 정했다.

사용자가 JD Proof에서 “GitHub 프로젝트 동기화”를 누르면, 브라우저는 외부 authorization server의 로그인·동의 화면을 거쳐 다시 JD Proof의 callback URL로 돌아온다. 이때 서버가 받은 `code`를 곧바로 token으로 바꾸고, 그 token으로 저장소 메타데이터를 읽는 그림이 가장 단순해 보인다. 하지만 callback URL은 브라우저를 경유한다. 다른 로그인 시도에서 나온 `code`가 섞이거나, 이미 끝난 시도의 callback이 다시 도착하거나, 의도하지 않은 redirect URI로 시작한 요청이 token 저장까지 가면 사용자 A의 연결 시도와 사용자 B의 외부 계정이 잘못 이어질 수 있다.

여기서 결정해야 할 것은 “PKCE를 넣을까”가 아니다. **누가 OAuth client인지, callback에서 무엇을 한 묶음으로 확인한 뒤에만 token을 저장할지**가 결정 경계다. JD Proof의 이 시나리오에서는 브라우저가 아니라 서버가 authorization request를 만들고 callback을 받으며 token 교환도 한다. 따라서 서버는 짧은 시간 동안 로그인 시도 한 건의 상태를 보관해야 한다.

## 먼저 구분할 것: 웹 서버와 public client의 역할

모바일 앱·SPA·데스크톱 앱처럼 앱 자체가 OAuth client인 경우를 public client라고 한다. 앱에 넣은 `client_secret`은 사용자가 추출할 수 있으므로 비밀로 믿기 어렵다. 이 경우 앱은 매 authorization request마다 `code_verifier`를 만들고, 자기 메모리나 플랫폼의 안전한 임시 저장소에 보관한 뒤 token endpoint에 직접 보낸다. 앱과 authorization server 사이의 PKCE 검증은 그 규격을 지원하는 통합에서 이루어진다.

JD Proof의 설계는 다르다. 브라우저는 사용자의 화면일 뿐 OAuth client는 서버다. 서버가 `GET /integrations/{provider}/authorize`에서 `state`와 `code_verifier`를 만들고, `code_challenge`와 `code_challenge_method=S256`을 authorization request에 붙인다. callback도 서버의 `GET /integrations/{provider}/callback`으로 받는다. verifier는 브라우저 cookie·localStorage·URL에 넣지 않는다. 서버가 token 교환 때 원문 verifier를 다시 보내야 하기 때문이다.

## 한 번의 연결 시도에 저장할 값

`state`와 `code_verifier`는 모두 민감하지만, callback에서 필요한 형태가 다르다. `state`는 callback으로 온 값을 다시 해시해 저장값과 비교하면 되므로 원문을 남길 이유가 없다. 반대로 `code_verifier`는 token 교환에 원문이 필요하다. 해시만 저장하면 verifier를 복구할 수 없어 PKCE token 요청을 만들지 못한다.

그래서 JD Proof의 시나리오는 `state`는 SHA-256 해시로, `code_verifier`는 애플리케이션의 암호화 키로 암호문으로 저장한다. 둘 다 짧은 만료 시간과 한 번만 사용한다는 조건을 갖는다. `state`가 URL에 보인다는 사실도 원문 DB 저장의 이유가 되지 않는다. callback에서 받은 원문을 해시해 찾고, 일치하면 그 시도를 소비 처리한다.

```sql
CREATE TABLE oauth_link_attempt (
  id UUID PRIMARY KEY,
  user_id UUID NOT NULL,
  provider VARCHAR(30) NOT NULL,
  state_hash CHAR(64) NOT NULL UNIQUE,
  code_verifier_ciphertext BYTEA NOT NULL,
  redirect_uri TEXT NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  consumed_at TIMESTAMPTZ
);
```

이 테이블은 외부 계정 자체나 장기 token을 저장하는 곳이 아니다. “사용자 42가 provider X에 연결을 시작했고, 정확히 이 redirect URI로 돌아와야 한다”는 임시 거래 기록이다. `provider`와 `user_id`는 callback이 어느 통합과 어느 로그인 사용자에게 속하는지 확인할 때 쓴다. `redirect_uri`는 authorize 요청에 사용한 완전한 값을 저장하며, callback 주소의 path 일부만 비교하는 용도가 아니다.

`code_verifier_ciphertext`는 callback 처리 중에만 복호화한다. token 교환이 성공하면 암호화된 access token·필요하면 refresh token을 별도의 자격 증명 저장소에 기록하고 verifier 암호문을 즉시 삭제한다. token 교환이 실패해도 동일하게 삭제하고 시도는 소비 처리한다. 네트워크 재시도로 verifier를 오래 붙잡아 두면 탈취될 시간과 재사용 경로만 늘어난다. 사용자는 실패 화면에서 새 연결을 시작하게 한다.

## callback에서 멈춰야 하는 순서

흐름을 요청 단위로 적으면 다음과 같다.

```text
브라우저 → GET /integrations/{provider}/authorize
서버 → state와 code_verifier를 한 번만 사용할 수 있게 저장
브라우저 → authorization server → GET /integrations/{provider}/callback
서버 → state·redirect URI·만료·사용 여부 확인 → code 교환 → 암호화된 token 저장
```

첫 요청에서 서버는 예측 불가능한 `state`와 RFC 7636 형식의 높은 엔트로피 `code_verifier`를 만든다. `code_challenge`는 `BASE64URL(SHA256(ASCII(code_verifier)))`이며, authorization request에는 challenge만 보낸다. RFC 7636은 S256을 쓸 수 있는 client는 S256을 사용하도록 정의한다. RFC 9700도 authorization request에서 verifier를 드러내지 않는 방식으로 현재 S256을 지목한다.

callback의 `state`를 받으면 서버는 우선 SHA-256 해시로 `oauth_link_attempt`를 찾는다. 이어서 현재 로그인 세션의 사용자와 `user_id`가 같은지, URL path parameter의 `{provider}`가 저장된 provider와 같은지, 저장한 `redirect_uri`가 이번 통합의 등록된 callback URI와 정확히 같은지, `expires_at`이 지나지 않았는지, `consumed_at`이 비어 있는지를 확인한다. 하나라도 다르면 token endpoint를 호출하지 않는다.

검증을 통과한 시도는 동시 callback도 한 번만 통과하도록 소비 상태를 선점한다. 그 뒤에만 verifier를 복호화해 authorization code·동일한 redirect URI·verifier로 token 교환을 한다. token 응답을 암호화해 저장할 때도 transaction을 명확히 잡는다. token 저장이 실패하면 성공한 것처럼 연결 완료를 보여주지 않고, verifier를 삭제한 뒤 새 시도를 안내한다. 이 순서가 “code를 받았으니 token을 저장한다”와 다른 지점이다.

PKCE는 이 거래에서 code를 가로챈 쪽이 verifier 없이 token으로 바꾸는 일을 어렵게 만든다. 하지만 JD Proof가 `state`를 생략해도 된다는 뜻은 아니다. 이 글의 설계는 callback을 시작한 브라우저 세션·사용자·한 번뿐인 `state`를 함께 확인해, 다른 연결 시도의 결과를 현재 세션에 주입하는 문제를 분리해 막는다. PKCE만으로 CSRF를 막는다고 전제하지 않는다.

## 피하는 대안과 이유

| 위험한 대안 | 왜 부족한가 | 이 시나리오의 선택 |
| --- | --- | --- |
| `state`를 저장하지 않거나 callback에서 비교하지 않음 | 공격자가 자기 authorization code를 피해자 세션의 callback에 넣는 연결 혼동을 걸러낼 상관관계가 없다. | 무작위 state의 해시를 저장하고, 세션 사용자·만료·미사용 상태와 함께 확인한다. |
| `https://service.example/callback/*` 같은 redirect URI 와일드카드 | 예상보다 넓은 주소가 code를 받을 수 있고, 요청 때 사용한 URI와 token 교환 URI를 정확히 묶기 어렵다. | authorize 때 쓴 완전한 redirect URI를 저장하고 정확히 비교한다. |
| access token 원문을 애플리케이션 로그에 기록 | 로그 조회 권한이나 외부 로그 전송 경로가 곧 저장소 읽기 권한의 노출 경로가 된다. | 원문 token·authorization code·verifier는 로그에 남기지 않고 request id와 실패 단계만 기록한다. |

RFC 9700은 authorization server가 PKCE downgrade를 막으려면, verifier가 있다는 이유만으로 token 요청을 받지 말고 최초 요청에 challenge가 있었는지 연결해 확인해야 한다고 권고한다. 이 시나리오도 “verifier가 있으니 안전하다”가 아니라, 처음 저장한 시도와 지금 callback이 같은 한 건인지 확인한다.

## 주니어 개발자가 먼저 돌릴 검증

아래 표는 provider 호출을 mock으로 둔 controller·service 테스트의 기준이다. 실패 행에서는 token endpoint 호출 횟수가 0인지까지 확인한다.

| 상황 | 준비 | 기대 결과 |
| --- | --- | --- |
| 만료된 state | `expires_at`이 과거인 시도를 만들고 정상 형태의 callback을 보낸다. | callback은 실패하고 token endpoint·token 저장소를 호출하지 않으며 verifier 암호문을 삭제한다. |
| 재사용된 callback | 같은 state로 첫 callback을 성공 처리한 뒤 같은 요청을 한 번 더 보낸다. | 두 번째 요청은 `consumed_at` 때문에 실패하고 새 token을 저장하지 않는다. |
| 다른 redirect URI | 시도에는 A URI를 저장하고 token 교환 요청에는 B URI가 쓰이도록 만든다. | 교환 전에 실패하며 provider에 code를 보내지 않는다. |
| verifier 누락 요청 | PKCE challenge가 있는 시도에서 복호화 결과가 없거나 token 요청의 `code_verifier`를 빼 본다. | token 교환을 시작하지 않거나 provider 오류로 실패 처리하고, token을 저장하지 않은 채 verifier를 삭제한다. |

운영에서는 `oauth.callback.state_mismatch`, `oauth.callback.expired`, `oauth.callback.reused`, `oauth.token_exchange.failed`만 집계하고 state·code·verifier·token 원문은 남기지 않는다. 실패율이 오르면 등록 URI 불일치, 만료, callback 중복을 먼저 확인한다.

## 이 설계를 적용하지 않는 경계

순수 public client가 authorization code와 token 교환을 자기 앱에서 직접 책임져야 한다면, 서버 callback 테이블에 verifier를 저장하는 이 설계를 그대로 옮기지 않는다. 그 client가 verifier를 만들고 보호하며 token endpoint에 보내는 흐름을 별도로 설계해야 한다. 서버는 그 앱의 token을 대신 수집하는 중간자가 되어서는 안 된다.

또한 실제 OAuth 제공자가 PKCE를 지원하지 않거나 지원 여부를 확인하지 못했으면 `code_challenge`와 `code_verifier`를 보낼 수 있다고 쓰지 않는다. 제공자 공식 문서에서 지원 여부와 보안 요구사항을 확인한 뒤 통합 자체를 허용할지 결정한다. 이 두 조건은 기능을 포기하자는 말이 아니라, 서버 callback 방식의 책임 범위를 public client와 미지원 통합까지 과장하지 않기 위한 경계다.

정리하면 PKCE는 verifier 보유 증명이고, `state`는 callback을 시작한 연결 시도를 찾는 열쇠다. 서버 callback에서는 state 해시를 비교하고, 원문이 꼭 필요한 verifier만 짧게 암호화해 보관한다. 성공·실패 직후 삭제한 다음에만 암호화된 token을 별도 저장소에 남긴다.

## 참고한 공식 문서

- [RFC 7636 - Proof Key for Code Exchange by OAuth Public Clients](https://www.rfc-editor.org/rfc/rfc7636.html)
- [RFC 9700 - Best Current Practice for OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700.html)
