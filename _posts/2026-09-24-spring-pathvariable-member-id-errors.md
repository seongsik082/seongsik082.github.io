---
title: "회원 프로필 조회에서 숫자가 아닌 @PathVariable을 먼저 구분하는 방법"
date: 2026-09-24 08:55:00 +0900
tags: [Spring, REST API, Java, Backend]
excerpt: "회원 프로필 조회 예제로 Spring @PathVariable의 Long 변환, 숫자가 아닌 ID 요청과 존재하지 않는 회원 요청의 차이, Controller와 Service에서 확인할 위치를 초급 수준에서 설명한다."
---

# 회원 프로필 조회에서 숫자가 아닌 `@PathVariable`을 먼저 구분하는 방법

`/members/abc`와 `/members/999`는 왜 같은 “없는 회원”이 아닐까?

**대상 독자:** Java 문법과 간단한 Spring CRUD를 막 익힌 개발자

회원 프로필 조회 API가 `/members/{memberId}` 형태라고 하자. 어떤 사용자는 숫자 대신 `abc`를 넣을 수 있고, 어떤 사용자는 숫자로 된 999를 넣지만 실제 회원은 없을 수 있다. 두 요청은 모두 프로필을 찾지 못하지만, 실패한 위치가 다르다. `@PathVariable Long memberId`가 문자열 URL 값을 숫자로 바꾸는 과정을 알면 어디서 문제를 확인해야 하는지 분명해진다.

이 글은 회원 한 명을 조회하는 API 하나만 다룬다. URL 값의 형식이 잘못된 경우와 데이터가 없는 경우를 나누고, Service가 시작되기 전과 후의 책임을 구분하는 것이 목표다.

## 1. 오늘의 주제

회원 프로필은 보통 숫자 ID로 한 명을 찾는다. 요청 주소는 다음처럼 보일 수 있다.

```http
GET /members/42
```

여기서 `42`는 URL로 들어올 때는 글자 형태다. `@PathVariable Long memberId`는 Spring에게 이 값을 `Long` 숫자로 바꿔 Controller 메서드에 넣어 달라고 요청하는 코드다. 숫자 42라면 Service까지 전달할 수 있다.

하지만 `/members/abc`는 `abc`를 `Long`으로 바꿀 수 없다. 반면 `/members/999`는 숫자로 바뀌지만, Service가 저장소를 조회했을 때 회원을 못 찾을 수 있다. 이 둘을 같은 예외 처리에 넣으면 로그를 봐도 사용자가 URL을 잘못 쓴 것인지 데이터가 없는 것인지 알기 어렵다.

이 주제는 `@PathVariable`로 조회 API를 만들기 시작한 뒤 배우면 좋다. 글을 읽고 나면 Controller에 값이 들어오기 전의 형식 문제와, Service에서 조회한 뒤의 존재 여부 문제를 나눠 볼 수 있다.

## 2. 핵심 개념

`@PathVariable`은 URL 템플릿 변수와 메서드 파라미터를 연결한다. `/members/{memberId}`의 중괄호 자리에 들어온 값을 `memberId` 변수로 받는다는 뜻이다.

파라미터를 `String`이 아니라 `Long`으로 선언하면 Spring은 문자열을 숫자로 바꾸려고 한다. 이런 변환은 단순 타입에 기본으로 지원된다. 변환에 실패하면 Controller 메서드 본문은 실행되지 않는다. 즉 `memberService.find(memberId)`를 호출하기도 전에 요청 처리가 멈춘다.

회원 존재 여부는 다른 문제다. `Long`으로 바꾼 999가 데이터베이스에 실제 있는지는 Service가 확인한다. URL 형식 검사는 입력의 모양을, 회원 조회는 데이터의 상태를 확인한다. 둘의 책임을 섞지 않는 것이 핵심이다.

## 3. 내부 동작 원리

`GET /members/42` 요청은 다음 순서로 진행된다.

1. Spring MVC가 `/members/{memberId}`와 맞는 Controller 메서드를 찾는다.
2. URL의 `42`를 꺼내 `@PathVariable("memberId") Long memberId`에 넣으려고 한다.
3. Spring이 문자열 `42`를 `Long` 숫자 42로 변환한다.
4. Controller가 숫자 ID를 Service에 넘긴다.
5. Service가 저장소에서 회원을 찾고, 프로필 응답을 만든다.

`GET /members/abc`에서는 3번에서 멈춘다. `abc`는 숫자가 아니므로 `Long`으로 만들 수 없다. 반대로 `/members/999`는 3번을 통과하고 5번에서 회원이 없다는 결과를 얻는다. 같은 4xx 응답 계열로 보일 수 있어도, 원인과 첫 확인 지점은 다르다.

팀의 예외 처리 규칙에 따라 응답 JSON 모양은 달라질 수 있다. 보통 숫자 형식이 아닌 요청은 400 Bad Request, 존재하지 않는 회원은 404 Not Found로 구분한다. 중요한 것은 상태 코드의 암기보다, 변환 실패를 Service의 “회원 없음” 처리로 숨기지 않는 것이다.

## 4. 실제 코드

아래는 숫자 ID를 받고, 실제 회원 존재 여부는 Service에서 확인하는 예시다. `@PathVariable` 이름을 명시해 URL의 이름과 연결 기준을 분명히 했다.

```java
@RestController
@RequestMapping("/members")
@RequiredArgsConstructor
public class MemberProfileController {
    private final MemberProfileService memberProfileService;

    @GetMapping("/{memberId}")
    public MemberProfileResponse findOne(
            @PathVariable("memberId") Long memberId) {
        return memberProfileService.findById(memberId);
    }
}

@Service
@RequiredArgsConstructor
public class MemberProfileService {
    private final MemberRepository memberRepository;

    public MemberProfileResponse findById(Long memberId) {
        Member member = memberRepository.findById(memberId)
                .orElseThrow(() -> new ResponseStatusException(
                        HttpStatus.NOT_FOUND, "회원을 찾을 수 없습니다."));

        return new MemberProfileResponse(member.getId(), member.getNickname());
    }
}
```

`memberId`가 숫자가 아니면 `findOne` 메서드 안에 들어오지 않는다. 그래서 Service는 숫자로 변환된 ID만 받는다고 생각할 수 있다. Service의 `orElseThrow`는 숫자 ID는 받았지만 저장소에 회원이 없는 경우만 담당한다.

`ResponseStatusException`은 예시를 짧게 보이기 위해 사용했다. 프로젝트가 공통 예외 처리 클래스와 오류 응답 형식을 이미 갖고 있다면 그 규칙을 따라야 한다. 핵심은 예외 클래스의 이름이 아니라, “형식 오류”와 “조회 결과 없음”이 다른 경로에서 생긴다는 점이다.

## 5. 실제 서비스 적용

작은 회원 서비스에서는 `memberId`를 `Long`으로 선언하는 것부터 시작하면 된다. 숫자만 허용하는 회원 ID라는 의도가 메서드 파라미터에 드러난다. 사용자 아이디처럼 문자와 숫자가 섞인 식별자를 쓴다면 그때는 `String`을 받고 Service에서 형식을 확인한다.

요청이 늘어났을 때 가장 먼저 볼 값은 400과 404의 개수다. 400이 갑자기 늘면 프런트엔드가 URL을 잘못 만들었거나 클라이언트가 잘못된 ID를 보내고 있을 수 있다. 404가 늘면 삭제된 회원 링크, 오래된 화면 데이터, 조회 권한 규칙을 먼저 확인한다. 두 상태를 한 로그로 뭉치면 원인을 좁히기 어렵다.

테스트에서는 숫자인 42가 Service에 전달되는지, 숫자가 아닌 `abc`가 Service를 호출하지 않는지 확인한다. 그리고 존재하지 않는 999는 Service의 “회원 없음” 규칙을 통과하는지 본다. 이렇게 나누면 한 테스트가 너무 많은 실패 원인을 동시에 확인하지 않는다.

## 6. 흔히 발생하는 문제

### 1) 숫자 ID를 `String`으로 받고 바로 조회하는 경우

현상은 Service 곳곳에 `Long.parseLong(memberId)`가 반복되는 것이다. 원인은 Controller에서 표현할 수 있는 숫자 ID의 의도를 문자열로 미뤘기 때문이다. 첫 확인 지점은 Controller 파라미터 타입이다. 숫자 ID만 허용한다면 `Long`으로 받고 변환 책임을 Spring에 맡긴다.

### 2) 숫자가 아닌 요청을 “회원 없음”으로 처리하는 경우

현상은 `/members/abc`와 `/members/999`가 같은 오류 메시지를 내는 것이다. 원인은 변환 실패와 조회 실패를 구분하지 않았기 때문이다. 첫 확인 지점은 Service가 호출되기 전에 어떤 예외가 발생했는지다. 형식 오류는 공통 예외 처리에서, 회원 없음은 Service의 조회 결과에서 처리한다.

### 3) URL 변수 이름을 코드와 다르게 쓰는 경우

현상은 `@GetMapping("/{id}")`인데 `@PathVariable("memberId")`를 써서 요청 바인딩이 실패하는 것이다. 원인은 중괄호 안의 이름과 애너테이션 이름이 다르기 때문이다. 첫 확인 지점은 URL 매핑과 `@PathVariable`의 문자열이다. 같은 이름을 명시해 두면 수정할 때 실수를 줄일 수 있다.

## 7. 기술 선택의 Trade-off

숫자 ID를 `Long`으로 받으면 Controller가 기대하는 입력 형식이 바로 드러난다. 잘못된 형식은 데이터 조회 전에 걸러지므로 Service 코드도 단순해진다. 대신 URL에 문자형 식별자를 사용해야 하는 API에는 그대로 적용할 수 없다.

내부 숫자 ID로 회원을 찾는 API에는 `Long`이 잘 맞는다. 닉네임이나 로그인 아이디처럼 문자 규칙이 있는 값은 `String`으로 받은 뒤 별도 검증이 필요하다. 어느 쪽이든 URL 값이 존재한다고 해서 데이터가 있다는 뜻은 아니다. 조회 결과 없음은 항상 Service나 Repository의 결과로 확인해야 한다.

결정은 네 단계로 한다. 먼저 URL 식별자가 숫자만 허용하는지 정한다. 숫자라면 Controller에서 `Long`으로 받는다. 다음으로 변환 실패와 조회 실패의 응답 규칙을 나눈다. 마지막으로 400과 404 로그를 분리해 어떤 요청이 늘었는지 확인한다.

### 참고한 공식 문서

- [Spring Framework PathVariable API](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/web/bind/annotation/PathVariable.html) — `@PathVariable`이 URI 템플릿 변수와 메서드 파라미터를 연결하고, 변수 이름을 명시할 수 있음을 확인했다.
- [Spring MVC Mapping Requests](https://docs.spring.io/spring-framework/reference/6.2-SNAPSHOT/web/webmvc/mvc-controller/ann-requestmapping.html) — URI 변수가 `long` 같은 단순 타입으로 자동 변환되며, 변환에 실패하면 `TypeMismatchException`이 발생하는 동작을 확인했다.
