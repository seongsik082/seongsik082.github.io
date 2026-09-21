---
title: "관리자 설정 조회 API에서 Spring @PathVariable을 쓰는 이유"
date: 2026-09-21 08:55:00 +0900
tags: [Spring, REST API, Java, Backend]
excerpt: "관리자 설정 조회 예제로 Spring @PathVariable이 URL의 값과 메서드 파라미터를 연결하는 방법, @RequestParam과 구분하는 기준, 설정 키를 검증하는 위치를 초급 수준에서 설명한다."
---

# 관리자 설정 조회 API에서 Spring `@PathVariable`을 쓰는 이유

URL 안의 설정 키를 Controller에서 어떻게 받을까?

**대상 독자:** Java 문법과 간단한 Spring CRUD를 막 익힌 개발자

관리자 화면에서 `site-title`이라는 설정 하나를 조회한다고 생각해 보자. 주소는 `/admin/settings/site-title`처럼 자연스럽게 만들 수 있다. 그런데 Controller에서 이 값을 받지 못하면 URL의 중괄호 이름과 메서드 파라미터가 제대로 연결됐는지부터 봐야 한다. Spring의 `@PathVariable`은 URL 경로에 들어 있는 값을 Java 메서드 파라미터로 받는 표시다.

이 글은 관리자 설정을 하나 조회하는 API만 기준으로 설명한다. 검색 조건과 리소스의 이름을 섞지 않고, URL 값이 어느 순서로 Service까지 전달되는지 이해하는 것이 목표다.

## 1. 오늘의 주제

관리자는 서비스 이름, 가입 허용 여부, 공지 문구처럼 운영 설정을 하나씩 확인할 수 있다. 이때 “어떤 설정 하나를 조회한다”는 요청은 설정 키가 URL의 일부로 보이는 편이 읽기 쉽다.

```http
GET /admin/settings/site-title
```

여기서 `site-title`은 설정을 구분하는 값이다. `@PathVariable`은 `/admin/settings/{settingKey}`의 `{settingKey}` 자리에 실제로 들어온 문자열을 Controller 메서드의 변수에 담는다. URL 경로에 들어가는 값은 보통 “어느 리소스인가”를 가리킬 때 사용한다.

이 주제는 Spring Controller에 조회 API를 만들기 시작할 때 배우면 좋다. 글을 읽고 나면 URL의 일부로 받을 값과 `?page=1`처럼 덧붙여 받을 조건을 구분하고, 설정 키가 비어 있거나 잘못됐을 때 어디에서 처리할지 판단할 수 있다.

## 2. 핵심 개념

경로 변수는 URL 경로 안에서 바뀌는 부분이다. `/admin/settings/site-title`과 `/admin/settings/allow-signup`은 같은 API 모양을 쓰지만, 마지막 값이 다르다. `{settingKey}`는 이 바뀌는 위치에 붙인 이름이다.

`@PathVariable("settingKey") String settingKey`는 URL의 `{settingKey}` 값을 `settingKey` 변수로 받겠다는 뜻이다. 이름을 명시하면 Controller의 변수 이름을 나중에 바꾸거나 컴파일 설정이 달라져도 연결 기준이 눈에 보인다.

반대로 `@RequestParam`은 URL 뒤에 붙는 선택 조건에 잘 맞는다. 예를 들어 관리자 설정 목록에서 `?enabled=true`로 필터링할 수 있다. 하지만 설정 하나를 찾는 핵심 값까지 쿼리 파라미터로 섞으면 `/admin/settings?key=site-title`처럼 API의 중심 대상이 덜 드러날 수 있다.

## 3. 내부 동작 원리

설정 하나를 조회하는 요청은 다음 순서로 흐른다.

1. 클라이언트가 `GET /admin/settings/site-title`을 보낸다.
2. Spring MVC가 `GET /admin/settings/{settingKey}`와 맞는 Controller 메서드를 찾는다.
3. Spring이 `{settingKey}` 위치의 `site-title`을 꺼내 `@PathVariable` 파라미터에 넣는다.
4. Controller는 설정 키를 Service에 전달한다.
5. Service는 저장된 설정을 찾고, 없으면 “존재하지 않는 설정”이라는 결과를 정해 Controller로 돌려준다.

3번은 URL의 글자를 옮기는 단계일 뿐이다. `site-title`이라는 키가 실제로 등록돼 있는지는 Service나 Repository가 확인해야 한다. 경로 변수가 있다고 해서 데이터가 존재한다는 뜻은 아니다.

설정 키에 공백이나 허용하지 않는 문자가 들어오면, Controller에 도착하기 전 URL 자체가 예상과 다르게 보일 수 있다. 처음에는 정해 둔 키 목록을 Service에서 확인하고, 유효하지 않은 키는 404 또는 400 중 팀의 API 규칙에 맞는 응답으로 정하는 편이 좋다. 중요한 것은 모든 설정 API에서 같은 기준을 쓰는 것이다.

## 4. 실제 코드

아래 코드는 관리자 설정을 하나 찾는 짧은 예시다. `settingKey`를 URL에서 받고, 실제 조회는 Service가 담당한다.

```java
@RestController
@RequestMapping("/admin/settings")
@RequiredArgsConstructor
public class AdminSettingController {
    private final AdminSettingService adminSettingService;

    @GetMapping("/{settingKey}")
    public SettingResponse findOne(
            @PathVariable("settingKey") String settingKey) {
        return adminSettingService.findByKey(settingKey);
    }
}

@Service
public class AdminSettingService {
    public SettingResponse findByKey(String settingKey) {
        if (!settingKey.matches("[a-z-]+")) {
            throw new IllegalArgumentException("설정 키 형식이 올바르지 않습니다.");
        }

        // repository에서 settingKey로 설정을 조회한다고 가정한다.
        return new SettingResponse(settingKey, "서비스 제목");
    }
}
```

`@GetMapping("/{settingKey}")`의 중괄호 이름과 `@PathVariable("settingKey")`의 이름이 같아야 한다. 예시에서는 이름을 명시했기 때문에 `String settingKey`라는 변수명 자체는 연결 규칙의 전부가 아니다.

Controller는 URL에서 값을 받는 역할만 한다. 정규식 검사는 예시로 간단히 넣었지만, 실제로 허용하는 설정 키가 정해져 있다면 Service에서 목록을 확인하는 편이 더 명확하다. 설정 값을 수정하거나 저장하는 코드를 조회 API에 섞지 않는 것도 중요하다.

## 5. 실제 서비스 적용

작은 서비스에서는 설정의 식별자를 먼저 정한다. 데이터베이스의 숫자 ID를 URL에 쓸지, `site-title`처럼 사람이 읽을 수 있는 키를 쓸지 선택한다. 관리자가 설정 이름을 보고 바로 이해해야 하고 키가 쉽게 바뀌지 않는다면 문자열 키가 편할 수 있다. 반대로 이름 변경 가능성이 크다면 내부 ID와 표시 이름을 분리하는 편이 안전하다.

설정 조회가 많아져도 Controller에서 URL을 해석하는 방식은 바뀌지 않는다. 먼저 확인할 것은 요청 로그에 남은 실제 경로와 `settingKey` 값이다. `/admin/settings/site-title` 요청이 다른 메서드로 간다면 매핑 경로를, Service에서 못 찾는다면 저장된 키 값을 확인한다.

테스트에서는 `site-title` 요청이 Service에 같은 문자열로 전달되는지를 먼저 확인한다. 존재하지 않는 키를 넣었을 때 어떤 HTTP 응답을 주는지도 함께 정한다. 조회 API의 핵심은 “값을 받았다”가 아니라, 잘못된 키와 없는 키를 사용자가 이해할 수 있는 방식으로 구분하는 데 있다.

## 6. 흔히 발생하는 문제

### 1) URL 중괄호 이름과 `@PathVariable` 이름이 다른 경우

현상은 요청 주소는 맞아 보이는데 Controller 값이 들어오지 않거나 예외가 나는 것이다. 원인은 `@GetMapping("/{key}")`와 `@PathVariable("settingKey")`처럼 서로 다른 이름을 사용했기 때문이다. 첫 확인 지점은 중괄호 안의 이름과 애너테이션의 이름이다. 두 이름을 같게 두고, 예시처럼 이름을 명시하면 확인하기 쉽다.

### 2) 설정 하나를 찾는데 `@RequestParam`만 사용하는 경우

현상은 API마다 `?key=...`와 `?id=...`가 뒤섞여 URL 규칙이 흐려지는 것이다. 원인은 리소스를 구분하는 값과 목록을 좁히는 조건을 같은 방식으로 다뤘기 때문이다. 첫 확인 지점은 그 값이 없으면 어떤 대상도 정할 수 없는지다. 대상 자체를 가리키면 `@PathVariable`, 목록의 선택 조건이면 `@RequestParam`을 먼저 검토한다.

### 3) URL 값만 믿고 바로 설정을 반환하는 경우

현상은 존재하지 않는 키에서 빈 값이나 서버 오류가 나온다. 원인은 경로 변수가 문자열로 전달된 것과 데이터 존재 여부를 같은 것으로 생각했기 때문이다. 첫 확인 지점은 Service가 없는 설정을 어떻게 처리하는지다. 설정을 찾지 못한 경우의 예외와 HTTP 응답 규칙을 하나로 정하고 테스트로 확인한다.

## 7. 기술 선택의 Trade-off

`@PathVariable`을 쓰면 URL만 봐도 어떤 설정 하나를 조회하는지 알기 쉽다. Controller 메서드도 “경로에서 받은 키로 하나를 찾는다”는 역할이 분명해진다. 대신 경로의 문자열 키를 나중에 바꾸면 기존 클라이언트 URL도 함께 바꿔야 할 수 있다.

설정 하나, 회원 한 명, 게시글 한 건처럼 대상이 명확한 조회에는 `@PathVariable`이 잘 맞는다. 페이지 번호, 정렬 방식, 목록 필터처럼 없어도 기본 조회가 가능한 값에는 `@RequestParam`이 읽기 쉽다. 목록 조건이 많다고 해서 모든 값을 경로에 넣으면 URL 구조가 복잡해질 수 있다.

결정은 네 단계로 한다. 먼저 값이 리소스 자체를 가리키는지 확인한다. 그렇다면 경로 변수 이름을 URL과 코드에서 같게 정한다. 다음으로 Service에서 실제 존재 여부를 확인한다. 마지막으로 없는 값과 형식이 틀린 값의 응답 규칙을 API 전체에서 일관되게 맞춘다.

### 참고한 공식 문서

- [Spring Framework PathVariable API](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/web/bind/annotation/PathVariable.html) — `@PathVariable`이 URI 템플릿 변수와 Controller 메서드 파라미터를 연결하는 애너테이션이며, `name`으로 연결할 변수 이름을 지정할 수 있음을 확인했다.
