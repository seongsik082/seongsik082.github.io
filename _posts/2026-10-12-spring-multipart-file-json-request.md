---
title: "파일 업로드 요청에서 JSON과 multipart/form-data를 구분하는 이유"
date: 2026-10-12 08:55:00 +0900
tags: [Spring, HTTP, File Upload, Backend]
excerpt: "파일과 설명을 함께 보내는 업로드 API 예제로 JSON 요청과 multipart/form-data의 차이, Spring @RequestPart와 MultipartFile의 역할, Content-Type을 먼저 확인하는 기준을 초급 수준에서 설명한다."
---

파일 하나와 설명 JSON을 같은 요청에 보내는 방법

**대상 독자: Java 문법과 간단한 Spring CRUD를 막 익힌 개발자**

게시글에 이미지를 올리는 API를 만들었는데 `@RequestBody`로 받은 DTO의 파일 값이 비어 있거나 415 오류가 나면, 코드보다 요청 형식이 먼저 어긋났을 수 있다. JSON은 글자 형태의 데이터를 보내기 좋지만, 파일의 바이트와 JSON을 한 본문에 담는 방식은 다르다. 이 글은 게시글 이미지 업로드 요청 하나를 기준으로 `multipart/form-data`가 왜 필요한지 설명한다. 핵심은 파일 업로드에도 무조건 다른 Controller를 쓰는 것이 아니라, 서버가 받은 본문의 모양에 맞는 파라미터를 고르는 것이다.

## 1. 오늘의 주제

게시글 작성 화면에서 사용자는 이미지 파일 하나와 “대표 이미지입니다” 같은 설명을 함께 보낼 수 있다. 파일은 바이트 데이터이고, 설명은 `{"description":"대표 이미지입니다"}` 같은 JSON으로 표현할 수 있다. 둘을 한 요청에 넣으려면 각 데이터를 나누어 담는 형식이 필요하다.

`multipart/form-data`는 요청 본문을 여러 part로 나누는 형식이다. part는 큰 요청 안에 들어 있는 작은 조각이라고 생각하면 된다. 파일 part에는 이미지 바이트가 들어가고, 설명 part에는 JSON이 들어간다. 이 글을 읽은 뒤에는 JSON만 받는 생성 API와 파일을 포함한 업로드 API를 구분할 수 있다.

이 예시는 학습용 게시글 이미지 업로드다. 파일 저장소, 바이러스 검사, 이미지 변환 같은 다음 단계는 다루지 않는다. 여기서는 Controller가 파일과 JSON part를 올바르게 받는 경계까지만 본다.

## 2. 핵심 개념

`Content-Type`은 클라이언트가 서버에 “지금 보내는 본문은 어떤 형식입니다”라고 알려 주는 HTTP 헤더다. 일반적인 JSON 요청은 `application/json`을 사용한다. Spring은 이 정보를 보고 `@RequestBody`의 JSON을 DTO로 바꾼다.

파일을 포함한 요청은 보통 `multipart/form-data`를 사용한다. 이 형식은 본문 안에 여러 part를 넣고, boundary라는 구분선을 이용해 각 part의 시작과 끝을 나눈다. 파일과 설명은 같은 HTTP 요청에 들어가지만 서로 다른 part다.

Spring의 `MultipartFile`은 업로드된 파일 part를 다루는 타입이다. 설명처럼 JSON으로 바꾸고 싶은 part에는 `@RequestPart`를 쓸 수 있다. `@RequestPart`는 각 part의 `Content-Type`을 보고 JSON을 Java 객체로 바꾸는 데 적합하다.

## 3. 내부 동작 원리

이미지와 설명을 보내는 요청은 다음 순서로 처리된다.

1. 클라이언트가 요청 전체의 `Content-Type`을 `multipart/form-data`로 보낸다.
2. 본문은 `file` part와 `metadata` part로 나뉜다.
3. Spring의 multipart 처리기가 구분선을 사용해 각 part를 읽는다.
4. `file` part는 `MultipartFile`로 전달되고, JSON인 `metadata` part는 DTO로 변환된다.
5. Controller는 파일이 비어 있는지와 설명 값이 맞는지 확인한 뒤 Service를 호출한다.

파일 자체를 JSON 문자열 안에 억지로 넣지 않는 이유는 파일 바이트와 JSON의 역할이 다르기 때문이다. `multipart/form-data`에서는 파일 part에도 별도 이름과 내용 형식이 있다. 서버는 `file`이라는 이름의 part를 찾아 `MultipartFile`로 받고, `metadata`라는 이름의 part는 JSON으로 읽는다.

요청 전체가 `application/json`인데 Controller가 `MultipartFile`을 기대하면 Spring은 형식을 맞출 수 없다. 오류를 만났을 때 가장 먼저 헤더와 part 이름을 확인해야 하는 이유다.

## 4. 실제 코드

아래 Controller는 이미지 파일과 설명 JSON을 각각 받는다. `consumes`는 이 API가 `multipart/form-data` 요청을 받는다는 약속이다.

```java
@RestController
@RequestMapping("/posts")
@RequiredArgsConstructor
public class PostImageController {
    private final PostImageService postImageService;

    @PostMapping(value = "/{postId}/image",
            consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ImageResponse upload(
            @PathVariable Long postId,
            @RequestPart("file") MultipartFile file,
            @Valid @RequestPart("metadata") ImageMetadataRequest metadata) {

        return postImageService.upload(postId, file, metadata.description());
    }
}

public record ImageMetadataRequest(
        @NotBlank String description) {
}
```

`@RequestPart("file")`은 이름이 `file`인 part를 `MultipartFile`로 받는다. `@RequestPart("metadata")`는 이름이 `metadata`인 part를 `ImageMetadataRequest`로 바꾼다. 클라이언트가 보낸 part 이름이 코드와 다르면 값이 들어오지 않으므로, 프런트엔드와 이 이름을 함께 맞춰야 한다.

`@Valid`는 설명이 비었을 때 Service까지 가지 않게 한다. 파일 자체의 크기, 확장자, 실제 형식 검사는 Service 또는 업로드 정책에서 추가로 해야 한다. 이 Controller는 받은 요청을 구분하는 역할에 집중한다.

## 5. 실제 서비스 적용

작은 게시글 서비스에서는 파일 업로드 API를 게시글 내용 수정 API와 분리하는 편이 읽기 쉽다. 내용만 수정할 때는 `application/json`과 `@RequestBody`를 사용한다. 이미지가 함께 오면 `multipart/form-data`와 `@RequestPart`를 사용한다. 같은 URL을 쓰더라도 요청 형식을 섞으면 클라이언트와 서버 모두 무엇을 보내야 하는지 헷갈리기 쉽다.

입력이 늘어날 때 가장 먼저 제한할 값은 파일 크기와 한 요청의 파일 개수다. 이 글의 예시는 파일 하나만 받는다. 여러 파일이 필요할 때는 `List<MultipartFile>`처럼 계약을 명확히 늘린다. 무제한 파일을 받고 나중에 잘라 내면 서버가 본문을 읽는 과정에서 이미 부담을 받을 수 있다.

첫 확인 지점은 브라우저 개발자 도구나 API 도구의 요청 헤더다. `Content-Type`이 `multipart/form-data`인지, `file`과 `metadata`라는 part 이름이 실제로 맞는지 본다. 테스트에서는 정상 파일과 정상 JSON이 Service에 전달되는지, 파일 part가 빠졌을 때 Service가 호출되지 않는지를 확인한다.

## 6. 흔히 발생하는 문제

### 1) 파일 업로드에 @RequestBody만 쓰는 경우

현상은 DTO가 비어 있거나 서버가 요청 형식을 처리하지 못하는 것이다. 원인은 JSON 본문을 받는 방식으로 multipart 요청 전체를 처리하려 했기 때문이다. 첫 확인 지점은 요청의 `Content-Type`이다. 파일과 JSON part를 함께 보낸다면 `@RequestPart`와 `MultipartFile`로 나눈다.

### 2) part 이름이 클라이언트와 다른 경우

현상은 파일을 골랐는데도 `file` 값이 없다는 오류가 나는 것이다. 원인은 화면이 `image`라는 이름으로 보냈지만 서버는 `file`을 찾는 것처럼 part 이름이 다르기 때문이다. 첫 확인 지점은 네트워크 탭의 form data 이름과 Controller의 문자열이다. 한 이름을 정해 API 문서와 코드에서 같이 쓴다.

### 3) 파일 설명을 문자열로만 받아 JSON 검증을 놓치는 경우

현상은 설명의 필수값이 비어도 Service까지 들어가는 것이다. 원인은 JSON part를 단순 문자열로 받아 DTO 검증을 생략했기 때문이다. 첫 확인 지점은 설명 값의 검증 위치다. 구조가 있는 JSON이라면 `@RequestPart` DTO와 `@Valid`를 사용해 Controller 경계에서 막는다.

## 7. 기술 선택의 Trade-off

`multipart/form-data`의 장점은 파일과 JSON 같은 서로 다른 데이터를 한 요청에 함께 담을 수 있다는 점이다. 게시글 이미지, 프로필 사진, 첨부 파일처럼 파일이 API 입력의 일부일 때 잘 맞는다. `@RequestPart`를 사용하면 파일 part와 JSON part의 역할이 메서드 시그니처에 드러난다.

단점은 JSON 전용 API보다 클라이언트 요청 생성과 테스트가 조금 복잡해진다는 점이다. 파일이 필요 없는 게시글 제목 수정까지 multipart로 만들 필요는 없다. 단순한 데이터 변경에는 `application/json`과 `@RequestBody`가 더 읽기 쉽다. 파일이 아주 크거나 처리 시간이 길다면 업로드 완료와 후속 처리를 하나의 요청에서 모두 끝낼지도 별도로 판단해야 한다.

다음 네 단계로 선택하면 충분하다.

1. 요청에 실제 파일 바이트가 포함되는지 먼저 확인한다.
2. 파일이 없으면 JSON과 `@RequestBody`를 우선 사용한다.
3. 파일과 JSON을 함께 보내면 `multipart/form-data`와 part 이름을 계약으로 정한다.
4. Controller에서 형식과 필수값을 확인하고, 파일 크기와 저장 정책은 Service 규칙으로 분리한다.

### 참고한 공식 문서

- [Spring Framework Multipart](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/multipart-forms.html) — `multipart/form-data` 요청에서 `MultipartFile`, `@RequestParam`, `@RequestPart`를 받는 방법과 JSON part 변환 방식을 확인했다.
- [MDN Content-Type header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Content-Type) — 요청 `Content-Type`이 보낸 본문 형식을 알리고, multipart 형식에서 boundary가 part를 나누는 역할을 확인했다.
