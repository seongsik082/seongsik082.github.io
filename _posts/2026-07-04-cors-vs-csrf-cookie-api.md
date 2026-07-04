---
title: "CORS를 통과해도 CSRF는 막히지 않는 이유와 쿠키 기반 API의 방어 기준"
date: 2026-07-04 08:59:00 +0900
tags: [Security, HTTP, Backend]
excerpt: "CORS는 어떤 브라우저 스크립트가 응답을 읽을 수 있는지 정하는 규칙이고, CSRF는 브라우저가 자동으로 보내는 인증 정보를 악용한 상태 변경 요청을 막는 문제입니다. 쿠키 인증 API에서는 둘을 별개로 설계해야 합니다."
---

## 문제 상황

프론트엔드가 `https://app.example.com`, API가 `https://api.example.com`에 있을 때 많은 팀이 가장 먼저 CORS 설정부터 엽니다. `Access-Control-Allow-Origin`을 맞추고, 필요하면 `Access-Control-Allow-Credentials: true`도 넣습니다. 로컬 테스트가 통과하면 "이제 브라우저 보안 문제는 끝났다"고 생각하기 쉽습니다.

하지만 실제 운영 사고는 여기서 끝나지 않습니다. 어떤 팀은 CORS를 열어 둔 뒤 CSRF 토큰을 없앴다가, 외부 사이트에서 유도된 요청으로 프로필 변경이나 결제 시도가 들어오는 문제를 만납니다. 반대로 어떤 팀은 CSRF가 걱정돼 CORS만 조이는데, 정작 같은 브라우저 안의 정상 SPA가 쿠키를 보내지 못해 인증 문제가 반복되기도 합니다.

이 둘이 자꾸 섞이는 이유는 둘 다 "브라우저가 보내는 요청"을 다루기 때문입니다. 그러나 질문이 다릅니다. CORS는 "이 응답을 자바스크립트가 읽어도 되는가"에 가깝고, CSRF는 "브라우저가 들고 있는 인증 쿠키를 이용한 상태 변경 요청을 믿어도 되는가"에 가깝습니다.

## 핵심 개념

MDN 문서는 CORS를 HTTP 헤더 기반 메커니즘으로 설명합니다. 서버는 어떤 origin이 응답을 읽어도 되는지 알리고, 브라우저는 `fetch()`나 `XMLHttpRequest` 같은 스크립트 기반 cross-origin 요청에서 그 규칙을 적용합니다. 또 credentialed request에서는 `Access-Control-Allow-Origin: *`를 쓸 수 없고, 명시적인 origin이 필요합니다.

같은 MDN 문서는 더 중요한 사실도 함께 적습니다. HTML `form`은 원래 다른 origin으로 단순 요청을 보낼 수 있었고, 그래서 서버는 이미 CSRF를 방어해야 한다는 전제가 있습니다. 즉 CORS preflight가 없다고 해서 요청 자체가 안 가는 것이 아닙니다. 브라우저가 응답을 스크립트에 공유하지 않을 뿐, 상태 변경 요청은 도달할 수 있습니다.

OWASP CSRF Cheat Sheet는 쿠키 기반 인증을 쓰는 웹 애플리케이션에서는 CSRF 토큰이 여전히 중요하다고 강조합니다. 상태 저장 애플리케이션은 synchronizer token pattern을, 상태 비저장 구조는 double-submit cookie 같은 방식을 고려하라고 권합니다. `SameSite`는 유용하지만 대부분의 배포에서 proper CSRF defense를 대체하지는 못한다고도 분명히 말합니다.

## HTTP로 보기

SPA가 쿠키를 포함해 API를 호출하는 정상 흐름은 대략 이렇게 생깁니다.

```http
POST /api/profile/email HTTP/1.1
Origin: https://app.example.com
Cookie: SESSION=abc123
X-CSRF-Token: 8f4c...
Content-Type: application/json
```

서버는 최소한 아래 항목을 분리해서 판단해야 합니다.

- 이 origin이 응답을 읽어도 되는가
- 이 요청이 사용자의 의도에서 왔는가
- 이 요청이 상태를 바꾸는 요청인가

예를 들어 서버 검증 순서는 아래처럼 잡을 수 있습니다.

```text
1. Origin 허용 목록 확인
2. 상태 변경 메서드면 CSRF 토큰 또는 동등한 방어 수단 검증
3. Origin/Referer 또는 Fetch Metadata를 보조 검증
4. 쿠키의 SameSite, Secure, HttpOnly 속성 점검
```

중요한 점은 1번이 통과해도 2번이 자동으로 해결되지 않는다는 것입니다. 특히 HTML form으로 보낼 수 있는 단순 요청이나, 사용자의 브라우저가 자동으로 붙이는 쿠키를 악용하는 시나리오는 CORS만으로 막히지 않습니다.

## 자주 하는 실수

첫 번째 실수는 `Access-Control-Allow-Origin`만 맞추고 CSRF 토큰을 제거하는 것입니다. 응답 공유 정책과 요청 위조 방어는 다른 문제입니다.

두 번째 실수는 credentialed request를 허용하면서 `*` 와일드카드를 기대하는 것입니다. MDN 문서처럼 자격 증명이 포함된 요청에는 명시적 origin이 필요합니다.

세 번째 실수는 `SameSite=Lax`만 믿고 끝내는 것입니다. OWASP는 `SameSite`를 defense-in-depth로 보라고 권합니다. 특히 상태 변경이 `GET`에 남아 있거나, 배포 조건이 좁지 않다면 이것만으로 충분하지 않습니다.

네 번째 실수는 쿠키를 상위 도메인 전체에 공유하는 것입니다. OWASP는 특정 domain 전체로 쿠키를 설정하면 모든 서브도메인이 그 쿠키를 공유하게 되어 위험해질 수 있다고 경고합니다.

## 언제 쓰면 좋은가

브라우저가 자동으로 세션 쿠키를 붙이는 로그인 구조라면, CORS와 CSRF는 항상 함께 검토해야 합니다. 반대로 모바일 앱이나 서버 간 통신처럼 브라우저 자동 쿠키 전송이 없고, 명시적 bearer token만 쓰는 경우에는 CSRF 위험 모델이 달라질 수 있습니다.

실무 판단 기준을 하나만 고르면 이렇습니다. "브라우저가 사용자의 의도와 무관하게 인증 정보를 실어 보낼 수 있는가?" 그렇다면 CORS 설정과 별도로 CSRF 방어 설계를 유지해야 합니다.

## 운영에서 볼 것

- state-changing endpoint에서 `Origin`, `Referer`, `Sec-Fetch-Site` 분포
- CSRF 검증 실패 횟수와 특정 경로 편중 여부
- credentialed CORS 요청에서 허용 origin 누락 또는 wildcard 오설정
- `SameSite`, `Secure`, `HttpOnly`가 빠진 쿠키 배포 여부
- `GET` 요청인데 서버 상태를 바꾸는 핸들러가 남아 있는지

보안 점검에서는 브라우저 콘솔의 CORS 에러만 보면 부족합니다. 실제로는 "응답을 읽지 못한 요청"과 "서버 상태를 바꾼 요청"을 분리해서 봐야 합니다.

## 정리

CORS는 브라우저 스크립트의 응답 접근을 제어하는 규칙이고, CSRF는 자동으로 전송되는 쿠키를 악용한 요청 위조를 막는 규칙입니다. 쿠키 기반 API에서는 둘 중 하나만 맞춰서는 부족합니다. 허용 origin, credential 정책, CSRF 토큰 또는 동등한 방어 수단, `SameSite`와 origin 검증을 별도 체크리스트로 운영해야 실제 사고를 줄일 수 있습니다.

## 참고한 공식 문서

- [MDN: Cross-Origin Resource Sharing (CORS)](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CORS)
- [OWASP Cheat Sheet: Cross-Site Request Forgery Prevention](https://cheatsheetseries.owasp.org/cheatsheets/Cross-Site_Request_Forgery_Prevention_Cheat_Sheet.html)
