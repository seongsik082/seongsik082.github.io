---
title: "ID Token을 API 인증에 쓰면 aud 검증이 어긋나는 이유"
date: 2026-07-02 08:59:00 +0900
tags: [Security, OIDC, Backend]
excerpt: "OpenID Connect의 ID Token은 로그인한 사용자를 클라이언트가 확인하기 위한 토큰이고, API는 자신을 대상으로 발급된 access token을 검증해야 합니다. 서명이 맞는 JWT라는 이유만으로 ID Token을 API 인증에 쓰면 audience 검증이 틀어집니다."
---

## 문제 상황

프론트엔드에서 로그인 연동을 붙인 뒤 백엔드 API에 JWT를 그대로 전달하는 구조는 흔합니다. 그런데 현장에서는 "이 토큰도 JWT고 저 토큰도 JWT니까 아무거나 검증해서 쓰면 되지 않나"라는 식으로 구현되는 경우가 자주 있습니다. 특히 클라이언트가 받은 ID Token을 그대로 API `Authorization: Bearer` 헤더에 넣고, 서버는 서명과 만료 시간만 본 뒤 통과시키는 패턴이 위험합니다.

이 구현은 개발 초기에 잘 동작하는 것처럼 보일 수 있습니다. 같은 인증 서버가 서명했고, `sub`도 들어 있고, `exp`도 아직 남아 있기 때문입니다. 하지만 운영으로 가면 API audience가 맞지 않는 토큰을 받아들이거나, 프론트엔드용 클라이언트에 발급된 토큰을 다른 서비스가 그대로 신뢰하는 문제가 생깁니다.

핵심은 토큰 문자열 형식이 아니라 토큰의 "수신자"가 누구냐입니다. ID Token은 로그인 결과를 클라이언트가 검증하기 위한 토큰이고, Access Token은 보호된 리소스 서버가 요청 권한을 판단하기 위한 토큰입니다. 둘 다 JWT일 수 있지만, 검증 기준과 intended audience가 다릅니다.

## 핵심 개념

OpenID Connect Core는 ID Token의 `aud` 클레임이 Relying Party, 즉 클라이언트의 OAuth `client_id`를 반드시 포함해야 한다고 설명합니다. 다시 말해 ID Token은 API를 위한 토큰이 아니라 "이 로그인 결과가 바로 이 클라이언트에게 온 것인가"를 확인하는 토큰입니다. 같은 문서에서 ID Token은 `iss`, `aud`, `exp` 같은 클레임을 통해 클라이언트가 인증 결과를 검증하게 만든다고 설명합니다.

반면 OpenID Connect의 UserInfo Endpoint는 Access Token으로 호출하게 되어 있습니다. 이 점만 봐도 ID Token과 Access Token의 용도가 다르다는 것을 알 수 있습니다. 클라이언트는 ID Token으로 로그인 세션을 세우고, 보호된 리소스 접근은 Access Token으로 해야 합니다.

RFC 9068은 JWT 형식 Access Token 예시에서 `aud`가 리소스 서버를 가리키는 resource indicator라고 설명합니다. 그리고 리소스 서버는 `iss`가 기대한 발급자와 정확히 일치하는지, `aud`에 현재 리소스 서버 자신이 기대하는 식별자가 들어 있는지 검증해야 한다고 명시합니다. 즉 API가 봐야 할 audience는 클라이언트 앱의 `client_id`가 아니라, 자기 자신을 뜻하는 리소스 식별자입니다.

## 코드로 보기

문제가 되는 구현은 보통 아래와 비슷합니다.

```java
DecodedJWT jwt = verifier.verify(token);
if (jwt.getExpiresAt().before(new Date())) {
    throw new UnauthorizedException();
}

String userId = jwt.getSubject();
authenticate(userId);
```

이 코드는 "JWT가 유효한가"만 보고 "이 JWT가 우리 API를 위한 것인가"를 보지 않습니다. 그래서 프론트엔드용 ID Token도 통과할 수 있습니다.

API 쪽 검증은 최소한 아래 질문을 따라가야 합니다.

```java
DecodedJWT jwt = verifier.verify(token);

assertExpectedIssuer(jwt.getIssuer());
assertAudienceContainsApi(jwt.getAudience(), "https://api.example.com");
assertNotExpired(jwt.getExpiresAt());

String scope = jwt.getClaim("scope").asString();
assertContainsRequiredScope(scope, "orders.read");
```

여기서 중요한 것은 `aud` 기준입니다. OIDC ID Token의 `aud`는 보통 `web-client`나 `mobile-app` 같은 클라이언트 ID를 가리키고, API용 Access Token의 `aud`는 `https://api.example.com` 같은 리소스 식별자를 가리킵니다.

```json
// ID Token 예시
{
  "iss": "https://id.example.com",
  "aud": "web-client",
  "sub": "user-123",
  "exp": 1780000000
}
```

```json
// Access Token 예시
{
  "iss": "https://id.example.com",
  "aud": "https://api.example.com",
  "sub": "user-123",
  "scope": "orders.read orders.write",
  "exp": 1780000000
}
```

둘 다 서명 검증은 통과할 수 있지만, API가 받아야 하는 것은 두 번째뿐입니다.

## 자주 하는 실수

첫 번째 실수는 같은 issuer가 서명한 JWT면 모두 같은 용도라고 보는 것입니다. 실제로는 ID Token, Access Token, 심지어 서로 다른 API용 토큰도 audience가 다를 수 있습니다. 서명 검증은 시작일 뿐이고, audience 검증이 빠지면 토큰 대체 문제가 생깁니다.

두 번째 실수는 API에서 클라이언트의 `client_id`를 audience 기대값으로 넣는 것입니다. 그러면 프론트엔드 로그인용 토큰이 API 호출에 그대로 재사용됩니다. 프론트엔드와 API를 분리한 이유가 흐려지고, 서비스 경계도 약해집니다.

세 번째 실수는 로그인 정보와 권한 정보를 같은 토큰 의미로 다루는 것입니다. "누가 로그인했는가"와 "이 API를 호출해도 되는가"는 같은 질문이 아닙니다. 첫 번째는 ID Token이, 두 번째는 Access Token이 더 직접적으로 다룹니다.

## 언제 쓰면 좋은가

이 원칙은 특히 다음 구조에서 중요합니다.

- SPA 또는 모바일 앱이 외부 OIDC Provider로 로그인하는 경우
- 백엔드 API가 여러 개라서 서비스별 audience를 분리해야 하는 경우
- BFF 없이 브라우저와 API가 직접 토큰을 주고받는 경우

반대로 "우리 시스템은 세션 쿠키만 쓰고 토큰은 백엔드 내부에서만 보인다"는 구조라면 노출 방식은 다를 수 있습니다. 그래도 내부 API gateway나 resource server는 결국 자신을 대상으로 발급된 Access Token만 신뢰해야 한다는 원칙은 같습니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "이 토큰의 `aud`가 누구를 가리키는가?" 답이 클라이언트 앱이라면 API에서 받으면 안 되고, 답이 현재 API 리소스라면 검증 후보가 됩니다.

## 운영에서 볼 것

- API 인증 실패 중 `invalid_audience` 비율
- issuer별, audience별 토큰 수락 통계
- scope 부족과 만료 실패를 구분한 인증 로그
- 프론트엔드에서 어떤 토큰 종류를 실제로 보내는지 네트워크 캡처나 access log로 확인한 결과

운영 로그에는 토큰 원문을 남기지 말고 `iss`, `aud`, `client_id`, `scope`, 실패 사유만 남기는 편이 좋습니다. 그래야 보안 위험을 늘리지 않으면서도 "왜 특정 앱 토큰이 이 API에서 거절됐는가"를 분석할 수 있습니다.

## 정리

ID Token과 Access Token은 둘 다 JWT일 수 있지만, 같은 역할을 하지 않습니다. ID Token은 클라이언트가 로그인 결과를 확인하는 토큰이고, API는 자신을 audience로 가진 Access Token을 검증해야 합니다. 서명만 맞는 토큰을 받아들이지 말고, `iss`, `aud`, `exp`, 필요 scope까지 함께 확인해야 서비스 경계가 무너지지 않습니다.

## 참고한 공식 문서

- OpenID Connect Core 1.0, ID Token claims and UserInfo Endpoint: https://openid.net/specs/openid-connect-core-1_0.html
- RFC 9068: JSON Web Token (JWT) Profile for OAuth 2.0 Access Tokens: https://www.rfc-editor.org/rfc/rfc9068
