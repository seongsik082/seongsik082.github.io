---
title: "공지사항 관리 API로 정리하는 @RequestBody·@PathVariable 바인딩과 400 응답"
date: 2026-09-24 08:55:00 +0900
tags: [Spring, REST API, Java, Testing, Backend]
excerpt: "사내 공지사항 관리 API로 @RequestBody DTO 검증, @PathVariable 타입 변환 실패, @RequestParam 구분을 정리하고 400 응답을 한 형식으로 맞춰 MockMvc로 확인한다."
redirect_from:
  - /posts/spring-requestbody-order-create/
  - /posts/spring-pathvariable-admin-setting/
  - /posts/spring-pathvariable-member-id-errors/
---

사내 공지사항 관리 화면은 관리자만 쓰는 작은 기능이지만, 요청 값이 들어오는 자리는 여러 곳이다. 공지 등록은 JSON 본문으로, 단건 조회와 수정은 URL 경로의 공지 번호로, 목록은 분류와 페이지를 쿼리 파라미터로 받는다. 값이 들어오는 자리가 다르면 실패하는 자리도 다르다. 제목이 비어 있을 때, 공지 번호에 `abc`가 들어왔을 때, 분류 값에 오타가 났을 때 각각 다른 예외가 나고, 아무것도 정하지 않으면 400 응답 본문의 모양도 제각각이 된다. 그러면 프런트엔드는 어느 입력란에 오류를 표시할지 경우마다 다른 코드로 알아내야 한다. 이 글은 공지사항 관리 API를 예로 `@RequestBody`, `@PathVariable`, `@RequestParam`이 값을 받는 방식과 실패하는 지점을 정리하고, 400 응답을 한 가지 형식으로 맞춘 뒤 MockMvc로 확인하는 방법까지 다룬다. 예제는 Spring Boot 3.4(Spring Framework 6.2)를 기준으로 한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 요청이 Controller 메서드에 닿기까지

공지사항 관리 API는 다음 네 가지다.

| 요청 | 값이 오는 자리 | 받는 방법 |
| --- | --- | --- |
| `POST /api/admin/notices` | JSON 본문 | `@RequestBody` |
| `GET /api/admin/notices/{noticeId}` | URL 경로 | `@PathVariable` |
| `PUT /api/admin/notices/{noticeId}` | URL 경로와 JSON 본문 | 둘 다 |
| `GET /api/admin/notices?category=HR&page=0` | 쿼리 문자열 | `@RequestParam` |

요청이 들어오면 Spring MVC는 URL과 HTTP 메서드로 처리할 Controller 메서드를 찾고, 메서드의 파라미터를 하나씩 채운다. 경로 변수와 쿼리 파라미터는 문자열로 들어오므로 선언된 타입으로 변환한다. 본문은 `Content-Type`에 맞는 HTTP 메시지 변환기가 읽는데, JSON이면 Jackson이 객체로 만든다. `@Valid`가 붙은 본문 객체는 그다음 Bean Validation을 거친다. 이 단계를 모두 통과해야 비로소 메서드 본문이 실행된다.

중요한 점은 아래 실패가 전부 Controller 메서드가 실행되기 전에 일어난다는 것이다. Controller 첫 줄에 남긴 로그나 걸어 둔 브레이크포인트에 아무것도 잡히지 않고, Service도 호출되지 않는다.

| 단계 | 실패 예 | 예외 | 기본 상태 |
| --- | --- | --- | --- |
| 경로 매핑 | 없는 URL | `NoResourceFoundException` | 404 |
| 본문 형식 | `Content-Type: text/plain`으로 전송 | `HttpMediaTypeNotSupportedException` | 415 |
| 본문 읽기 | 깨진 JSON, 없는 enum 값 | `HttpMessageNotReadableException` | 400 |
| 경로·쿼리 변환 | `/notices/abc`, `page=first` | `MethodArgumentTypeMismatchException` | 400 |
| 필수 쿼리 누락 | 필수 파라미터 없이 호출 | `MissingServletRequestParameterException` | 400 |
| 본문 검증 | 빈 제목 | `MethodArgumentNotValidException` | 400 |
| 메서드 검증 | 경로 변수의 `@Positive` 위반 | `HandlerMethodValidationException` | 400 |

`/api/admin/notices/abc`와 `/api/admin/notices/999`는 둘 다 공지를 보여 주지 못하지만 실패한 위치가 다르다. `abc`는 `Long`으로 바꿀 수 없어 변환 단계에서 멈추고 400이 된다. `999`는 숫자로 바뀌어 Service까지 가고, 저장소에 그 공지가 없어서 404가 된다. 두 경우를 같은 메시지로 뭉치면 로그를 봐도 화면이 URL을 잘못 만든 것인지 삭제된 공지 링크가 남아 있는 것인지 가를 수 없다. 400이 갑자기 늘면 클라이언트의 요청 생성 코드를, 404가 늘면 삭제되거나 회수된 공지로 이어지는 링크를 먼저 의심하면 된다.

## @RequestBody는 요청 전용 record로 받는다

```java
public enum NoticeCategory { HR, IT, GENERAL_AFFAIRS, SECURITY }

public record CreateNoticeRequest(
        @NotBlank(message = "제목을 입력하세요.") @Size(max = 100) String title,
        @NotBlank(message = "본문을 입력하세요.") @Size(max = 4000) String content,
        @NotNull(message = "분류를 선택하세요.") NoticeCategory category,
        boolean pinned,
        @FutureOrPresent LocalDateTime publishAt) {
}

public record UpdateNoticeRequest(
        @NotBlank @Size(max = 100) String title,
        @NotBlank @Size(max = 4000) String content,
        @NotNull NoticeCategory category,
        boolean pinned) {
}

@RestController
@RequestMapping("/api/admin/notices")
public class NoticeAdminController {

    private final NoticeService noticeService;

    public NoticeAdminController(NoticeService noticeService) {
        this.noticeService = noticeService;
    }

    // 예제에서는 작성자 사번을 헤더로 단순화했다. 실제로는 인증 객체에서 꺼낸다.
    @PostMapping
    public ResponseEntity<NoticeResponse> create(@Valid @RequestBody CreateNoticeRequest request,
                                                 @RequestHeader("X-Employee-No") String writerNo) {
        NoticeResponse created = noticeService.create(request, writerNo);
        return ResponseEntity.created(URI.create("/api/admin/notices/" + created.noticeId()))
                .body(created);
    }

    @GetMapping("/{noticeId}")
    public NoticeResponse get(@PathVariable("noticeId") Long noticeId) {
        return noticeService.get(noticeId);
    }

    @PutMapping("/{noticeId}")
    public NoticeResponse update(@PathVariable("noticeId") Long noticeId,
                                 @Valid @RequestBody UpdateNoticeRequest request) {
        return noticeService.update(noticeId, request);
    }

    @GetMapping
    public List<NoticeSummary> search(
            @RequestParam(name = "category", required = false) NoticeCategory category,
            @RequestParam(name = "page", defaultValue = "0") int page,
            @RequestParam(name = "size", defaultValue = "20") int size) {
        return noticeService.search(category, page, size);
    }
}
```

`@RequestBody`는 요청 본문을 HTTP 메시지 변환기로 읽어 객체로 만든다. JSON 속성 이름과 record 구성 요소 이름이 맞아야 값이 들어가고, 형식이 다르면 메서드에 들어오기 전에 실패한다. Spring 문서는 폼 데이터는 `@RequestBody`가 아니라 `@RequestParam`으로 읽으라고 안내한다. 같은 값이라도 어떤 형식으로 오느냐에 따라 받는 방법이 달라진다는 뜻이다.

`@Valid`를 붙이면 record의 제약 조건을 검사하고, 실패하면 `MethodArgumentNotValidException`이 나서 기본적으로 400이 된다. 파라미터 바로 뒤에 `BindingResult`를 두면 예외 대신 메서드 안에서 오류를 직접 다룰 수 있다. 하지만 REST API에서 Controller마다 이렇게 처리하면 응답 모양이 메서드마다 달라지기 쉬우므로, 이 글에서는 예외로 올려 한곳에서 처리한다.

몇 가지 세부 동작도 기억해 둘 만하다. `boolean pinned`처럼 기본형으로 선언한 값은 JSON에서 빠지면 `false`가 된다. `publishAt`의 `@FutureOrPresent`는 `null`이면 통과하므로 "비우면 즉시 게시"라는 규칙을 별도 코드 없이 표현할 수 있다. `"category": "FINANCE"`처럼 enum에 없는 값은 검증 단계까지 가지 못하고 JSON을 읽는 단계에서 `HttpMessageNotReadableException`으로 끝난다. 같은 "분류가 잘못됨"이라도 비어 있으면 검증 실패, 오타면 읽기 실패로 서로 다른 예외가 된다는 점이 400 응답을 통일해야 하는 이유 중 하나다.

검증은 형식과 필수 여부까지만 맡긴다. 보안 분류 공지는 보안 담당 부서만 등록할 수 있다거나, 분류별 상단 고정 공지가 일정 개수를 넘으면 안 된다는 규칙은 데이터베이스를 조회해야 판단할 수 있다. 이런 규칙을 커스텀 검증 애너테이션 안에 넣으면 쿼리가 검증 단계에 숨어 트랜잭션 밖에서 실행되고, 어디서 조회가 일어나는지 찾기 어려워진다. 업무 규칙은 Service에서 확인하고 도메인 예외로 알리는 편이 흐름을 따라가기 쉽다.

## Entity를 그대로 받지 않는 이유

공지 Entity에는 제목과 본문 말고도 작성자 사번, 게시 상태, 조회수, 삭제 여부, 생성 시각처럼 서버가 정해야 하는 필드가 있다. Controller가 `@RequestBody Notice notice`로 Entity를 바로 받으면 Jackson은 JSON에 있는 속성 중 채울 수 있는 것을 모두 채운다. 클라이언트가 다음과 같은 본문을 보내면 작성자와 상태까지 요청한 대로 들어간다.

```json
{
  "title": "보안 점검 안내",
  "content": "이번 주 금요일 저녁 보안 점검이 있습니다.",
  "category": "SECURITY",
  "writerNo": "E0001",
  "status": "PUBLISHED",
  "viewCount": 0
}
```

이런 문제를 흔히 mass assignment라고 부른다. Spring 문서의 데이터 바인딩 항목은 바인딩이 신뢰할 수 없는 입력을 애플리케이션 객체에 채우는 일이므로 기대한 필드로만 제한해야 한다고 설명한다. 또 JPA나 Hibernate Entity는 기대한 입력보다 프로퍼티가 많아 웹 바인딩에 대체로 안전하지 않다고 적고, record나 생성자 바인딩, 용도별 입력 객체를 권한다. 이 문서는 폼과 쿼리 파라미터를 객체에 채우는 `WebDataBinder`를 기준으로 쓰였다. 그래서 그곳에 나오는 `setAllowedFields` 같은 허용 목록은 Jackson이 읽는 `@RequestBody`에는 적용되지 않는다. JSON 본문에서는 받을 필드만 가진 요청 전용 record를 두는 것이 가장 단순한 방어다. 작성자는 인증 정보에서, 상태와 조회수는 서버 규칙에서 정하고, Service가 record에서 필요한 값만 꺼내 Entity를 만든다.

```java
@Transactional
public NoticeResponse create(CreateNoticeRequest request, String writerNo) {
    Notice notice = Notice.draft(request.title(), request.content(), request.category(),
            request.pinned(), request.publishAt(), writerNo);
    noticeRepository.save(notice);
    return NoticeResponse.from(notice);
}
```

Spring Boot가 구성하는 `ObjectMapper`는 모르는 속성을 만나도 실패하지 않으므로, record에 없는 `writerNo`나 `status`는 조용히 버려진다. 아예 400으로 거절하고 싶다면 설정을 바꿀 수 있다.

```yaml
spring:
  jackson:
    deserialization:
      fail-on-unknown-properties: true
```

엄격하게 막으면 클라이언트의 필드 이름 오타와 의도하지 않은 속성을 바로 드러낼 수 있다. 대신 클라이언트가 먼저 배포되어 새 필드를 보내기 시작하면, 아직 이전 버전인 서버가 그 요청을 모두 거절한다. 배포 순서를 맞추기 어려운 시스템 사이라면 기본값을 유지하고, 필수 필드는 `@NotBlank`나 `@NotNull`로 지키는 편이 낫다.

| 받는 타입 | 장점 | 쓰지 않는 편이 나은 경우 |
| --- | --- | --- |
| Entity를 직접 받기 | 클래스가 하나 줄어든다 | 작성자, 상태, 조회수처럼 서버가 정할 필드가 하나라도 있을 때 |
| 요청 전용 record(이 글) | 받을 필드와 검증 규칙이 한곳에 보인다 | 부분 수정(PATCH)처럼 "필드를 보내지 않음"과 "명시적으로 null"을 구분해야 할 때 |
| `Map<String, Object>` | 어떤 키든 받을 수 있다 | 키와 타입이 정해진 API. 오타와 형 오류가 Service 깊숙이까지 들어간다 |

## @PathVariable과 @RequestParam은 "무엇을"과 "어떻게"로 나눈다

경로 변수는 대상 리소스를 가리키고, 쿼리 파라미터는 결과를 좁히거나 모양을 정한다. 판단 기준은 "이 값이 없으면 대상 자체를 정할 수 없는가"다. 공지 번호가 없으면 어느 공지를 조회할지 정할 수 없으니 경로에 둔다. 분류, 페이지 번호, 페이지 크기는 없어도 기본 목록을 보여 줄 수 있으니 쿼리 파라미터로 둔다. 이 기준을 섞어 `/api/admin/notices?id=10` 같은 API와 `/api/admin/notices/10`이 함께 생기면 같은 시스템 안에서 URL 규칙이 흐려진다. 경로 변수가 꼭 숫자일 필요는 없다. 시스템 설정처럼 `site-title` 같은 문자열 키로 대상을 가리키는 경우도 있는데, 그때는 `String`으로 받고 허용하는 키인지는 Service에서 확인한다.

경로 변수 이름은 `@PathVariable("noticeId")`처럼 명시하는 편이 안전하다. Spring 문서는 이름이 같고 코드가 `-parameters` 옵션으로 컴파일됐다면 이름을 생략할 수 있다고 설명한다. Spring Boot 빌드 플러그인은 보통 이 옵션을 켜 주지만, 이름을 적어 두면 빌드 환경이 달라도 연결 기준이 코드에 그대로 보인다. `@GetMapping("/{id}")`와 `@PathVariable("noticeId")`처럼 이름이 어긋나면 `MissingPathVariableException`이 나는데, 이 예외는 400이 아니라 500으로 처리된다. 클라이언트가 아니라 서버 코드의 매핑 실수이기 때문이다.

타입은 의도를 드러내는 쪽으로 고른다. 공지 번호를 `Long`으로 선언하면 숫자가 아닌 값은 변환 단계에서 걸러지고, Service는 변환된 값만 받는다. `String`으로 받아 Service 곳곳에서 `Long.parseLong`을 호출하면 형식 검사가 흩어지고, 변환 실패가 500으로 새어 나가기 쉽다. 쿼리 파라미터에서 `required = false`로 둔 `category`는 값이 없으면 `null`이 되고, `int page`처럼 기본형은 `defaultValue`가 있어야 값이 없을 때도 안전하다.

공지 번호가 양수인지까지 선언으로 확인하고 싶다면 경로 변수에 제약 애너테이션을 붙일 수 있다.

```java
@PutMapping("/{noticeId}")
public NoticeResponse update(@PathVariable("noticeId") @Positive Long noticeId,
                             @Valid @RequestBody UpdateNoticeRequest request) {
    return noticeService.update(noticeId, request);
}
```

여기에는 함정이 있다. Spring 문서에 따르면 `@Positive`처럼 파라미터에 직접 붙은 제약은 메서드 검증을 일으키고, 메서드 검증은 같은 메서드의 `@Valid` 본문 검증까지 함께 처리한다. 그래서 이 메서드에서는 빈 제목도 `MethodArgumentNotValidException`이 아니라 `HandlerMethodValidationException`으로 올라온다. 문서도 메서드 시그니처에 따라 둘 중 무엇이든 날 수 있으니 애플리케이션은 두 예외를 모두 처리하라고 안내한다. 또 Controller 클래스에 `@Validated`를 붙여 두면 AOP 프록시 방식의 검증이 적용되므로, Spring Framework 6.1부터 들어간 내장 메서드 검증을 쓰려면 그 애너테이션을 지워야 한다.

## 400 응답을 한 가지 모양으로 맞춘다

아무 설정이 없으면 Spring Boot의 기본 오류 응답에는 상태 코드와 경로 정도만 담기고, 어떤 필드가 왜 틀렸는지는 빠진다. `spring.mvc.problemdetails.enabled`를 켜면 RFC 9457 형식으로 바뀌지만, 검증 실패의 `detail`은 요청 내용이 올바르지 않다는 일반 문구여서 입력란별 오류를 표시하기에는 부족하다. 그래서 `ResponseEntityExceptionHandler`를 상속한 advice에서 400 계열 예외 네 가지를 같은 모양으로 바꾼다. 애플리케이션에 이 타입의 빈이 있으면 Spring Boot는 자체 처리기를 따로 등록하지 않으므로, 이 클래스는 하나만 둔다.

```java
@RestControllerAdvice
public class ApiExceptionHandler extends ResponseEntityExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(ApiExceptionHandler.class);

    public record InvalidField(String field, String reason) {
    }

    @Override
    protected ResponseEntity<Object> handleMethodArgumentNotValid(
            MethodArgumentNotValidException ex, HttpHeaders headers,
            HttpStatusCode status, WebRequest request) {
        List<InvalidField> errors = ex.getBindingResult().getFieldErrors().stream()
                .map(error -> new InvalidField(error.getField(), error.getDefaultMessage()))
                .toList();
        return badRequest(ex, headers, request, "요청 본문의 값이 올바르지 않습니다.", errors);
    }

    @Override
    protected ResponseEntity<Object> handleHandlerMethodValidationException(
            HandlerMethodValidationException ex, HttpHeaders headers,
            HttpStatusCode status, WebRequest request) {
        List<InvalidField> errors = new ArrayList<>();
        for (ParameterValidationResult result : ex.getParameterValidationResults()) {
            if (result instanceof ParameterErrors beanErrors) {        // @Valid 본문의 필드 오류
                beanErrors.getFieldErrors().forEach(error ->
                        errors.add(new InvalidField(error.getField(), error.getDefaultMessage())));
            } else {                                                   // 경로 변수 같은 단일 값 오류
                String name = result.getMethodParameter().getParameterName();
                result.getResolvableErrors().forEach(error ->
                        errors.add(new InvalidField(name, error.getDefaultMessage())));
            }
        }
        return badRequest(ex, headers, request, "요청 값이 올바르지 않습니다.", errors);
    }

    @Override
    protected ResponseEntity<Object> handleTypeMismatch(
            TypeMismatchException ex, HttpHeaders headers,
            HttpStatusCode status, WebRequest request) {
        String name = (ex instanceof MethodArgumentTypeMismatchException mismatch)
                ? mismatch.getName() : ex.getPropertyName();
        String type = ex.getRequiredType() != null ? ex.getRequiredType().getSimpleName() : "요구";
        return badRequest(ex, headers, request, "경로 또는 파라미터 값의 형식이 올바르지 않습니다.",
                List.of(new InvalidField(name, type + " 타입으로 바꿀 수 없는 값입니다.")));
    }

    @Override
    protected ResponseEntity<Object> handleHttpMessageNotReadable(
            HttpMessageNotReadableException ex, HttpHeaders headers,
            HttpStatusCode status, WebRequest request) {
        List<InvalidField> errors = List.of();
        if (ex.getCause() instanceof MismatchedInputException mismatch && !mismatch.getPath().isEmpty()) {
            String field = mismatch.getPath().get(mismatch.getPath().size() - 1).getFieldName();
            errors = List.of(new InvalidField(field, "값의 형식이 올바르지 않습니다."));
        }
        return badRequest(ex, headers, request, "요청 본문을 읽을 수 없습니다. JSON 형식을 확인하세요.", errors);
    }

    private ResponseEntity<Object> badRequest(Exception ex, HttpHeaders headers, WebRequest request,
                                              String detail, List<InvalidField> errors) {
        log.info("bad_request {} type={} errors={}", request.getDescription(false),
                ex.getClass().getSimpleName(), errors);
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(HttpStatus.BAD_REQUEST, detail);
        problem.setType(URI.create("https://docs.example.com/problems/invalid-request"));
        problem.setTitle("잘못된 요청");
        problem.setProperty("errors", errors);
        return handleExceptionInternal(ex, problem, headers, HttpStatus.BAD_REQUEST, request);
    }
}
```

네 경로 모두 `errors` 배열에 `field`와 `reason`을 담으므로, 클라이언트는 실패 원인이 검증이든 변환이든 같은 코드로 입력란 옆에 메시지를 표시할 수 있다. `reason`에 쓰이는 문구는 제약 애너테이션의 `message`에서 오므로 사용자에게 보여 줄 문장으로 적어 둔다. 반대로 Jackson 예외 메시지나 스택 트레이스처럼 내부 구현을 드러내는 내용은 본문에 넣지 않고, 필요한 정보는 로그로만 남긴다. JSON 문법 자체가 깨진 경우에는 특정 필드를 가리킬 수 없으므로 `errors`가 비고 `detail`만 남는다.

이 방식은 Controller마다 `BindingResult`를 받아 직접 응답을 만드는 방식과 비교된다. 서버에서 화면을 그리는 폼처럼 실패하면 같은 화면을 오류 메시지와 함께 다시 보여 줘야 하는 경우에는 메서드 안에서 처리하는 편이 자연스럽다. 반면 여러 화면과 시스템이 호출하는 REST API에서는 응답 규칙이 한곳에 있어야 엔드포인트가 늘어도 모양이 어긋나지 않는다.

## 어떻게 확인하나

먼저 의존성을 확인한다. `spring-boot-starter-web`에는 Bean Validation 구현체가 들어 있지 않다. 검증 애너테이션이 컴파일은 되는데 전혀 동작하지 않는다면 구현체가 클래스패스에 없는지부터 본다.

```groovy
dependencies {
    implementation 'org.springframework.boot:spring-boot-starter-web'
    implementation 'org.springframework.boot:spring-boot-starter-validation'
    testImplementation 'org.springframework.boot:spring-boot-starter-test'
}
```

다음은 MockMvc로 400 응답을 고정하는 테스트다. `@WebMvcTest`는 Controller와 `@ControllerAdvice`만 불러오므로 서버를 띄우지 않고 바인딩과 예외 처리까지 확인할 수 있다. 각 테스트 끝에서 Service가 호출되지 않았는지 확인하는 이유는 이 실패들이 Controller 메서드 이전에 끝나야 하기 때문이다. Spring Boot 3.3 이하에서는 `@MockitoBean` 대신 `@MockBean`을 쓴다.

```java
import static org.mockito.BDDMockito.then;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

@WebMvcTest(NoticeAdminController.class)
class NoticeAdminControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private NoticeService noticeService;

    @Test
    void 제목이_공백이면_400과_title_필드_오류를_돌려준다() throws Exception {
        String body = """
                {"title": " ", "content": "연말정산 서류 제출 안내", "category": "HR"}
                """;

        mockMvc.perform(post("/api/admin/notices")
                        .header("X-Employee-No", "E1001")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isBadRequest())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_PROBLEM_JSON))
                .andExpect(jsonPath("$.errors[0].field").value("title"))
                .andExpect(jsonPath("$.errors[0].reason").value("제목을 입력하세요."));

        then(noticeService).shouldHaveNoInteractions();
    }

    @Test
    void 숫자가_아닌_공지_번호는_400이고_서비스를_호출하지_않는다() throws Exception {
        mockMvc.perform(get("/api/admin/notices/abc"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("noticeId"));

        then(noticeService).shouldHaveNoInteractions();
    }

    @Test
    void 없는_분류_값은_읽기_단계에서_400이_된다() throws Exception {
        String body = """
                {"title": "보안 점검 안내", "content": "금요일 저녁 점검", "category": "FINANCE"}
                """;

        mockMvc.perform(post("/api/admin/notices")
                        .header("X-Employee-No", "E1001")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.errors[0].field").value("category"));

        then(noticeService).shouldHaveNoInteractions();
    }

    @Test
    void JSON이_아닌_본문은_415가_된다() throws Exception {
        mockMvc.perform(post("/api/admin/notices")
                        .header("X-Employee-No", "E1001")
                        .contentType(MediaType.TEXT_PLAIN)
                        .content("보안 점검 안내"))
                .andExpect(status().isUnsupportedMediaType());
    }
}
```

로컬 서버에서는 같은 요청을 직접 보내 응답 본문을 눈으로 확인한다.

```http
POST /api/admin/notices HTTP/1.1
Content-Type: application/json
X-Employee-No: E1001

{"title": "", "content": "사내 메신저 점검 안내", "category": "IT"}

HTTP/1.1 400 Bad Request
Content-Type: application/problem+json

{
  "type": "https://docs.example.com/problems/invalid-request",
  "title": "잘못된 요청",
  "status": 400,
  "detail": "요청 본문의 값이 올바르지 않습니다.",
  "instance": "/api/admin/notices",
  "errors": [
    { "field": "title", "reason": "제목을 입력하세요." }
  ]
}
```

서버 로그에는 advice가 남긴 한 줄이 보여야 한다. 어떤 단계에서 실패했는지는 `type` 뒤의 예외 이름으로 바로 구분된다.

```text
INFO  c.e.notice.web.ApiExceptionHandler : bad_request uri=/api/admin/notices/abc type=MethodArgumentTypeMismatchException errors=[InvalidField[field=noticeId, reason=Long 타입으로 바꿀 수 없는 값입니다.]]
```

기대와 다르면 다음 순서로 본다.

- 테스트가 415로 끝난다면 요청에 `contentType(MediaType.APPLICATION_JSON)`을 빠뜨린 것이다.
- 400인데 `errors`가 비어 있다면 검증 전에 JSON 읽기가 실패한 것이다. 로그의 `type`이 `HttpMessageNotReadableException`인지 보고 따옴표, 쉼표, 날짜 형식을 확인한다.
- 빈 제목인데 201이 나온다면 파라미터에 `@Valid`가 있는지, 검증 구현체 의존성이 있는지 확인한다.
- 500과 함께 `MissingPathVariableException`이 보인다면 매핑의 중괄호 이름과 `@PathVariable` 이름이 다른 것이다.
- 특정 엔드포인트에서만 오류 모양이 다르다면 그 메서드의 파라미터에 제약 애너테이션이 붙어 `HandlerMethodValidationException` 경로로 처리되고 있지 않은지 본다.

## 정리

- JSON 본문은 받을 필드만 가진 요청 전용 record와 `@Valid`로 받고, Entity를 직접 받지 않는다.
- 작성자, 상태, 조회수처럼 서버가 정할 값은 요청 DTO에 두지 않는다.
- 대상을 가리키는 값은 `@PathVariable`, 결과를 좁히거나 모양을 정하는 값은 `@RequestParam`으로 받는다.
- 경로 변수 이름은 명시하고, 숫자 식별자는 `Long`으로 받아 변환 실패가 400으로 끝나게 한다.
- `MethodArgumentNotValidException`, `HandlerMethodValidationException`, 타입 변환 실패, 본문 읽기 실패를 같은 `errors` 형식으로 응답한다.
- 400 케이스마다 MockMvc 테스트에서 상태 코드, 필드 이름, Service 미호출을 함께 확인한다.

## 참고한 공식 문서

- [Spring Framework Reference: @RequestBody](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/requestbody.html)
- [Spring Framework Reference: Mapping Requests (URI Variables)](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-requestmapping.html)
- [Spring Framework Reference: Validation](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-validation.html)
- [Spring Framework Reference: Data Binding (Model Design)](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-data-binding.html)
- [DefaultHandlerExceptionResolver (Spring Framework API)](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/web/servlet/mvc/support/DefaultHandlerExceptionResolver.html)
