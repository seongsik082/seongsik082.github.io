---
title: "OAuth2 PKCE가 authorization code 탈취를 막는 방식과 서버 검증 기준"
date: 2026-07-19 08:50:00 +0900
tags: [Security, OAuth2, PKCE, Backend]
excerpt: "모바일·SPA 같은 public client에서는 client_secret만으로 authorization code 탈취를 막기 어렵습니다. PKCE의 code_verifier와 S256 code_challenge가 요청을 어떻게 묶는지, authorization server가 어떤 조건을 검증해야 하는지와 운영 체크포인트를 정리합니다."
---

## 문제 상황

모바일 앱의 로그인은 브라우저에서 인증을 마친 뒤 앱으로 authorization code를 돌려보내는 흐름을 자주 사용합니다. 그런데 운영체제의 custom URI scheme을 여러 앱이 등록할 수 있으면 악성 앱이 같은 redirect를 가로채 authorization code를 먼저 얻을 수 있습니다. code를 받은 앱이 token endpoint에 다시 요청하면 access token까지 가져갈 수 있습니다.

이때 모바일 앱에 `client_secret`을 넣어 해결하려는 경우가 있습니다. 하지만 앱에 포함된 secret은 바이너리 분석이나 런타임 관찰로 추출될 수 있으므로 confidential secret으로 취급하기 어렵습니다. 필요한 것은 “이 code를 처음 요청한 앱이 token 교환도 계속하고 있는가”를 확인하는 장치입니다.

## PKCE가 묶어 주는 두 요청

PKCE(Proof Key for Code Exchange)는 authorization request와 token request를 일회성 비밀값으로 연결합니다. client는 로그인 시작마다 높은 엔트로피의 `code_verifier`를 만들고, 그 값을 그대로 보내지 않고 변환한 `code_challenge`만 authorization server에 보냅니다. token 교환 시에는 원래의 `code_verifier`를 보내 서버가 둘을 비교합니다.

실제 흐름은 다음과 같습니다.

```text
1. client: random code_verifier 생성
2. client: S256(code_verifier) -> code_challenge
3. client -> /authorize: code_challenge, code_challenge_method=S256
4. server -> client: authorization code
5. client -> /oauth/token: code + code_verifier
6. server: code에 저장된 challenge와 다시 계산한 값을 비교
```

예를 들어 요청은 다음처럼 구성됩니다.

```http
GET /authorize?
  response_type=code&
  client_id=mobile-app&
  redirect_uri=com.example.app:/oauth/callback&
  code_challenge=K8...&
  code_challenge_method=S256&
  state=7f...
```

token endpoint는 authorization code와 원래의 `code_verifier`를 함께 받습니다. 서버는 `BASE64URL(SHA256(code_verifier))`를 계산해 authorization code에 저장한 challenge와 비교합니다. 값이 다르면 `invalid_grant`로 거절해야 합니다. code는 짧은 만료 시간과 일회성 사용 규칙도 가져야 하며, 다른 client의 redirect URI나 client_id를 허용하면 안 됩니다.

## S256을 기본으로 삼는다

RFC 7636에는 `plain`과 `S256` 방식이 정의되어 있지만, `plain`은 challenge와 verifier가 같아 authorization request가 노출되는 상황에서 보호력이 약합니다. 최신 OAuth 보안 권고는 S256 사용을 요구하는 방향입니다. 따라서 client는 `code_challenge_method=S256`을 사용하고, server는 지원하지 않는 방식이나 누락된 challenge를 조용히 허용하지 않는 편이 안전합니다.

특히 server는 token request에 `code_verifier`가 왔다는 이유만으로 검증을 수행하면 안 됩니다. 해당 authorization code가 발급될 때 실제 `code_challenge`가 있었는지도 저장해야 합니다. challenge 없이 발급된 code에 나중에 verifier만 붙여 보내는 흐름을 허용하면 PKCE downgrade가 생길 수 있습니다.

`state`는 callback의 CSRF 상관관계를, PKCE는 code를 가로챈 앱의 token 교환 차단을 담당하므로 둘 중 하나가 다른 하나를 대체하지 않습니다.

## 서버 검증 체크리스트

authorization server의 token endpoint에서는 최소한 다음을 확인합니다.

- authorization code가 존재하고 만료·재사용되지 않았는가
- 같은 `client_id`와 `redirect_uri`로 요청했는가
- 발급 당시의 challenge와 S256 method가 저장되어 있는가
- 계산한 값과 받은 `code_verifier`가 일치하는가
- token과 verifier를 로그에 남기지 않는가

실패한 code는 재사용할 수 없게 처리합니다. client에는 표준 오류를 주고 서버 로그에는 request id, client id, 실패 단계 정도만 남깁니다.

client는 `code_verifier`를 token 교환까지 보존하되 analytics나 일반 로그로 보내면 안 됩니다. 동시에 여러 로그인 요청이 있다면 verifier를 state 또는 transaction id별로 저장해야 하며, 전역 변수에 덮어쓰면 `invalid_grant`가 발생합니다.

## 흔한 잘못된 적용

첫 번째는 PKCE를 access token 보호 장치로 생각하는 것입니다. PKCE는 code 교환만 묶으므로 짧은 token 만료, scope 최소화, TLS, refresh token 정책이 별도로 필요합니다.

두 번째는 검증 실패를 재시도로 덮는 것입니다. verifier 불일치와 만료된 code는 새 authorization flow를 시작해야 하는 요청 오류입니다.

## 적용 기준과 운영 지표

네이티브 앱, SPA, 데스크톱 앱처럼 secret을 안전하게 보관할 수 없는 public client에는 PKCE를 기본 적용합니다. confidential client에도 추가 방어로 사용할 수 있습니다.

운영에서는 token endpoint의 `invalid_grant` 비율을 client·redirect URI·앱 버전별로 봅니다. 증가는 verifier 저장 버그나 redirect 설정 불일치일 수 있으며, code·verifier 원문은 기록하지 않습니다.

정리하면 다음과 같습니다.

- PKCE는 authorization request와 token request를 일회성 verifier로 묶습니다.
- public client의 client_secret은 안전한 인증 수단으로 볼 수 없습니다.
- S256, code·redirect URI·client_id 검증, 일회성 code 폐기를 함께 적용해야 합니다.
- `state`는 CSRF 상관관계, PKCE는 code 교환 주체 확인을 담당하므로 둘 다 필요합니다.

## 참고한 공식 문서

- [RFC 7636 - Proof Key for Code Exchange by OAuth Public Clients](https://www.rfc-editor.org/rfc/rfc7636.html)
- [RFC 9700 - Best Current Practice for OAuth 2.0 Security](https://www.rfc-editor.org/rfc/rfc9700.html)
