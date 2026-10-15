---
title: "MockMvc로 프로필 이미지 multipart 요청을 테스트하는 방법"
date: 2026-10-15 08:55:00 +0900
tags: [Spring, Testing, File Upload, Backend]
excerpt: "프로필 이미지 업로드 예제로 MockMvc와 MockMultipartFile로 파일 part와 JSON part를 함께 테스트하고, part 이름과 Content-Type 오류를 빠르게 찾는 방법을 초급 수준에서 설명한다."
---

# MockMvc로 프로필 이미지 multipart 요청을 테스트하는 방법

파일 part와 JSON part가 Controller까지 정확히 도착하는지 확인하기

**대상 독자: Java 문법과 간단한 Spring CRUD를 막 익힌 개발자**

프로필 이미지 업로드 API를 브라우저에서만 확인하면, 파일은 전달됐지만 설명 JSON이 빠진 문제를 놓치기 쉽다. 반대로 JSON은 맞는데 파일 part 이름이 달라 Controller가 받지 못할 수도 있다. 이런 문제는 서버를 실제로 실행하지 않아도 `MockMvc` 테스트로 빠르게 확인할 수 있다. 이 글은 이미지 파일과 소개 문구를 함께 보내는 요청 하나만 대상으로 한다.

지난 글에서 multipart 요청은 여러 part로 나뉜다고 설명했다. 이번에는 테스트에서 그 part들을 어떻게 만들고, 무엇을 검증해야 하는지 본다. 핵심은 실제 이미지 파일을 디스크에서 읽는 것이 아니라, 테스트용 파일과 JSON part를 요청 계약과 같은 이름으로 만드는 것이다.

## 1. 오늘의 주제

회원이 프로필 이미지를 바꾸면서 이미지 파일과 짧은 설명을 보낸다고 하자. Controller는 `file` part를 `MultipartFile`로 받고, `metadata` part를 JSON DTO로 받는다. 화면 개발자가 part 이름을 `image`로 바꾸거나 JSON part의 Content-Type을 빼면 서버와 약속이 달라진다.

`MockMvc`는 실제 HTTP 서버를 열지 않고 Spring MVC 요청 처리를 테스트하는 도구다. Controller의 URL 매핑, part 이름, JSON 변환, 검증 오류 같은 경계를 확인할 수 있다. 이 글을 읽은 뒤에는 파일 업로드 테스트에서 최소한 파일 이름, part 이름, JSON Content-Type, 응답 상태를 확인할 수 있다.

여기서는 실제 저장소에 이미지를 올리는 테스트가 아니다. Controller가 올바른 입력을 Service에 넘기는지, 잘못된 요청이 Service까지 가지 않는지를 확인하는 웹 계층 테스트다.

## 2. 핵심 개념

`MockMultipartFile`은 테스트에서 업로드 파일을 흉내 내는 객체다. part 이름, 원래 파일명, Content-Type, 바이트 내용을 넣어 만들 수 있다. Controller의 `@RequestPart("file")`과 테스트 파일의 part 이름이 같아야 한다.

JSON 설명도 multipart의 한 part다. 그래서 `metadata`라는 이름과 `application/json` Content-Type을 가진 `MockMultipartFile`로 만든다. 단순 문자열 파라미터처럼 넣으면 `@RequestPart` DTO 변환을 실제와 다르게 테스트할 수 있다.

테스트의 목표는 “업로드가 성공한다”라는 넓은 말보다 구체적이어야 한다. 정상 요청에서 Service가 회원 ID, 파일, 설명을 받는지 확인하고, 필수 part가 빠진 요청에서는 Service가 호출되지 않는지 확인한다.

## 3. 내부 동작 원리

정상적인 프로필 이미지 테스트는 다음 순서로 움직인다.

1. 테스트가 `file`과 `metadata`라는 두 `MockMultipartFile`을 만든다.
2. `multipart()` 요청 빌더가 두 part를 가진 모의 요청을 만든다.
3. MockMvc가 이 요청을 DispatcherServlet과 Controller로 전달한다.
4. Spring은 `file`을 `MultipartFile`로, JSON `metadata`를 DTO로 변환한다.
5. Controller가 Service를 호출하고, 테스트가 상태 코드와 전달값을 검증한다.

이 과정에는 실제 포트나 브라우저가 필요 없다. 그렇다고 실제 서버를 완전히 대신하는 테스트도 아니다. 웹 계층의 계약을 빠르게 확인하는 데 적합하다. 파일 크기 제한 설정, 실제 파일 시스템 쓰기, 외부 저장소 연결은 별도 통합 테스트에서 다루는 편이 좋다.

multipart 테스트에서 가장 중요한 것은 “파일 바이트가 있다”만 확인하지 않는 것이다. `file`과 `metadata`의 이름, JSON part의 형식, URL의 회원 ID가 Controller 선언과 같은지 확인해야 한다. 이 셋 중 하나라도 다르면 화면에서는 파일을 골랐어도 서버는 다른 요청으로 이해한다.

## 4. 실제 코드

아래 테스트는 `POST /members/{memberId}/profile-image`가 파일과 JSON 설명을 함께 받는다고 가정한다. import와 Service 구현은 생략했지만, Spring MVC 테스트에서 그대로 사용하는 코드 형태다.

```java
@WebMvcTest(ProfileImageController.class)
class ProfileImageControllerTest {
    @Autowired MockMvc mockMvc;
    @MockBean ProfileImageService profileImageService;

    @Test
    void 프로필_이미지와_설명을_업로드한다() throws Exception {
        MockMultipartFile file = new MockMultipartFile(
                "file", "profile.png", "image/png", new byte[]{1, 2, 3});
        MockMultipartFile metadata = new MockMultipartFile(
                "metadata", "", "application/json",
                "{\"description\":\"새 프로필 이미지\"}".getBytes(StandardCharsets.UTF_8));

        mockMvc.perform(multipart("/members/{memberId}/profile-image", 42L)
                        .file(file)
                        .file(metadata))
                .andExpect(status().isOk());

        verify(profileImageService).upload(eq(42L), any(), eq("새 프로필 이미지"));
    }
}
```

첫 번째 `MockMultipartFile`의 이름 `file`은 Controller의 `@RequestPart("file")`과 연결된다. 두 번째 파일은 실제 파일이 아니라 JSON part다. 그래서 파일명은 비어 있어도 되고, `application/json`을 명시해 Spring이 DTO로 변환할 단서를 준다.

마지막 `verify`는 HTTP 200만 확인하는 것보다 한 단계 더 구체적이다. URL의 42, 파일, 설명 문구가 Service 호출까지 같은 값으로 전달됐는지 본다. Service 안의 저장 로직은 이 테스트의 범위가 아니다.

## 5. 실제 서비스 적용

작은 회원 서비스에서는 Controller 테스트를 프로필 이미지 API의 첫 방어선으로 둘 수 있다. 프런트엔드와 합치기 전에 part 이름과 JSON 형식을 고정할 수 있기 때문이다. API 문서에도 `file`, `metadata` 이름을 같은 철자로 적어 두면 요청 계약이 덜 흔들린다.

입력이 늘어날 때는 테스트 파일을 크게 만들 필요가 없다. 이 테스트의 목적은 이미지 처리 성능이 아니라 요청 변환이다. 작은 바이트 배열로도 파일 part가 전달되는지는 충분히 확인할 수 있다. 크기 제한이 필요하다면 Spring 설정을 적용한 별도 테스트에서 제한을 넘는 파일을 만든다.

실패가 보이면 첫 확인 지점은 테스트의 part 이름이다. 그 다음 Controller의 `@RequestPart` 이름, JSON part의 Content-Type, DTO 필드명을 순서대로 본다. 요청이 Service에 도달하지 못했다면 Service mock의 문제가 아니라 그 앞의 변환·검증 단계에서 막혔을 가능성이 크다.

## 6. 흔히 발생하는 문제

### 1) JSON part를 일반 문자열 파라미터로 넣는 경우

현상은 테스트는 통과했는데 실제 화면에서 JSON DTO 변환이 실패하는 것이다. 원인은 테스트가 `@RequestPart`가 읽는 JSON part를 제대로 만들지 않았기 때문이다. 첫 확인 지점은 `metadata` part의 `application/json` 설정이다. DTO를 받는 part는 JSON Content-Type을 가진 `MockMultipartFile`로 만든다.

### 2) 파일 part 이름이 다른 경우

현상은 Controller가 파일이 없다고 처리하는 것이다. 원인은 테스트의 `image`와 Controller의 `@RequestPart("file")`처럼 이름이 다르기 때문이다. 첫 확인 지점은 `MockMultipartFile`의 첫 번째 인자와 Controller 애너테이션이다. API 문서, 프런트엔드, 테스트에서 같은 이름을 사용한다.

### 3) 상태 코드만 확인하는 경우

현상은 200 응답은 받았지만 Service에 잘못된 설명이나 회원 ID가 전달되는 것이다. 원인은 Controller와 Service 사이의 값을 확인하지 않았기 때문이다. 첫 확인 지점은 `verify` 또는 Service 인자 캡처다. 웹 계층 테스트에서는 상태 코드와 핵심 전달값을 함께 검사한다.

## 7. 기술 선택의 Trade-off

MockMvc multipart 테스트의 장점은 웹 서버를 실행하지 않고도 Controller의 요청 계약을 빠르게 확인한다는 점이다. 파일 part와 JSON part가 섞인 API에서 이름과 Content-Type 오류를 조기에 발견하기 좋다. Service를 mock으로 두면 테스트 실패 원인도 Controller 경계로 좁힐 수 있다.

단점은 실제 저장소, 네트워크, 최대 업로드 크기까지 보장하지 않는다는 점이다. `MockMultipartFile`의 작은 바이트 배열이 실제 이미지 파일과 모든 면에서 같지는 않다. 따라서 Controller 계약에는 MockMvc를 쓰고, 실제 파일 저장과 설정은 필요한 범위에서 통합 테스트로 나눈다.

다음 네 단계로 결정하면 충분하다.

1. Controller가 받는 모든 part 이름을 먼저 정한다.
2. 파일 part와 JSON part를 각각 `MockMultipartFile`로 만든다.
3. 정상 요청에서 상태 코드와 Service 전달값을 함께 확인한다.
4. 실제 저장소·크기 제한까지 검증해야 할 때만 별도 통합 테스트를 추가한다.

### 참고한 공식 문서

- [Spring Framework MockMvc 요청 수행](https://docs.spring.io/spring-framework/reference/6.2/testing/mockmvc/hamcrest/requests.html) — `multipart()` 요청 빌더가 파일 업로드 요청을 만드는 방식을 확인했다.
- [Spring Framework MockMultipartFile API](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/mock/web/MockMultipartFile.html) — 테스트용 `MultipartFile`에 part 이름, 파일명, Content-Type, 내용을 넣는 방법을 확인했다.
- [Spring Framework Multipart](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/multipart-forms.html) — JSON part를 `@RequestPart`로 DTO에 변환하는 방식을 확인했다.
