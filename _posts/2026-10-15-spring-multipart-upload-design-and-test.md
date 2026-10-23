---
title: "공지사항 첨부파일 업로드 API를 multipart로 설계하고 MockMvc로 검증하기"
date: 2026-10-15 08:55:00 +0900
tags: [Spring, HTTP, File Upload, Testing, Backend]
excerpt: "공지사항 첨부파일 업로드 API를 예로 JSON과 multipart/form-data 선택 기준, @RequestPart 설계, 크기 제한과 파일명 처리, MockMvc 테스트 범위를 정리한다."
redirect_from:
  - /posts/spring-multipart-file-json-request/
  - /posts/spring-mockmvc-profile-image-multipart-test/
---

사내 포털의 공지사항 관리 화면에서 담당자가 점검 일정표 PDF, 신청 양식 XLSX, 안내 이미지 PNG 같은 첨부파일을 짧은 설명 메타데이터와 함께 올린다고 하자. 기능은 단순해 보이지만 업로드 API는 실패 지점이 여러 층에 흩어져 있다. 화면에는 "등록에 실패했습니다" 한 줄만 보여도, 원인은 요청 형식, part 이름, 크기 제한, 파일 내용, 저장 경로 중 어디에든 있을 수 있다. 이 글은 공지사항 첨부파일 업로드 API 하나로 요청 형식 선택부터 검증, 크기 제한, 저장, 테스트까지 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 업로드 요청은 어디에서 실패하는가

첨부파일 하나를 올리는 요청은 Controller에 도착하기 전에 이미 여러 단계를 지난다.

1. 브라우저가 boundary라는 구분선으로 part를 나눈 `multipart/form-data` 요청을 만든다.
2. 앞단 웹 서버나 프록시에 본문 크기 제한이 있으면 요청은 애플리케이션까지 오지 않는다.
3. 서블릿 컨테이너가 본문을 파싱하며 `spring.servlet.multipart.*` 크기 제한을 적용한다.
4. Spring MVC가 `consumes` 조건으로 핸들러를 고르고 `@RequestPart` 인자를 part 이름으로 찾아 변환한다.
5. 애플리케이션 코드가 파일과 메타데이터를 검증하고 저장한다.

3단계에서 막히면 Controller 코드는 한 줄도 실행되지 않고, 4단계는 part 이름이나 Content-Type 문제, 5단계는 업무 규칙 문제다. 그래서 단계별 응답부터 정해 둔다. 이 글의 예제는 다음 규칙을 따른다.

| 실패 지점 | 발생하는 예외 | 응답 |
|---|---|---|
| 요청 전체가 multipart가 아님 | `HttpMediaTypeNotSupportedException` | 415 |
| JSON part의 Content-Type 누락 | `HttpMediaTypeNotSupportedException` | 415 |
| part 이름 불일치 또는 누락 | `MissingServletRequestPartException` | 400 |
| 메타데이터 필드 검증 실패 | `MethodArgumentNotValidException` | 400 |
| 컨테이너 크기 제한 초과 | `MaxUploadSizeExceededException` | 413 |
| 빈 파일, 허용하지 않는 형식, 내용 위장 | 직접 정의한 `AttachmentRejectedException` | 400 또는 413 |

## JSON에 담을까, multipart/form-data로 보낼까

선택지는 Base64 JSON, multipart, 업로드 분리 세 가지다. Base64 JSON은 요청 DTO 하나로 끝나서 클라이언트가 다루기 쉽다. 하지만 Base64는 3바이트를 4글자로 표현하므로 본문이 원본보다 약 3분의 1 커진다. 서버는 이 문자열 전체를 메모리에 올린 뒤 다시 바이트 배열로 디코딩하므로 같은 파일이 처리 중에 두 번 가까이 메모리에 머문다. multipart 크기 제한도 JSON 본문에는 적용되지 않는다. Jackson 2.15부터는 문자열 값 하나의 길이에도 기본 제한(`StreamReadConstraints`)이 있어, 큰 파일을 넣으면 파싱 단계에서 예상하지 못한 400을 만날 수 있다.

`multipart/form-data`는 파일 바이트를 인코딩 없이 보내고 part마다 이름과 Content-Type을 따로 가진다. 컨테이너는 일정 크기를 넘는 part를 임시 파일로 내려 쓰므로 큰 파일을 힙에 전부 올리지 않는다. 대신 요청 조립과 테스트가 JSON API보다 조금 복잡하다. 업로드 분리 방식은 파일을 먼저 올려 임시 첨부 ID를 받고 공지 등록 JSON에 그 ID를 넣는다. 진행률 표시에 유리하지만, 등록되지 않은 임시 파일을 정리하는 작업과 상태 관리가 따라온다.

| 방식 | 잘 맞는 경우 | 쓰지 않는 편이 좋은 경우 |
|---|---|---|
| Base64 JSON | 수 KB 이하의 작은 데이터, JSON 전용 연동 규격 | 문서·이미지 첨부처럼 크기가 MB 단위로 커질 수 있을 때 |
| multipart/form-data | 파일과 짧은 메타데이터를 한 번에 받는 관리 화면 | 파일이 없는 수정 API, 수백 MB 이상을 받아야 할 때 |
| 업로드 분리 | 대용량, 진행률 표시, 여러 화면에서 첨부 재사용 | 임시 파일 정리와 상태 관리를 감당할 여력이 없을 때 |

이 글은 공지 하나에 첨부를 붙이는 관리 화면을 가정하므로 multipart 방식을 쓴다. 실제 요청은 다음과 같은 모양이다.

```http
POST /api/notices/7/attachments HTTP/1.1
Host: portal.example.local
Content-Type: multipart/form-data; boundary=----notice7f3a

------notice7f3a
Content-Disposition: form-data; name="metadata"
Content-Type: application/json

{"description":"11월 보안 점검 일정표","category":"GUIDE"}
------notice7f3a
Content-Disposition: form-data; name="file"; filename="점검일정.pdf"
Content-Type: application/pdf

(PDF 바이트)
------notice7f3a--
```

각 part는 `Content-Disposition`의 `name`으로 식별된다. RFC 7578에 따르면 part의 Content-Type은 생략할 수 있고 기본값은 `text/plain`이며, Spring은 Content-Type이 없는 part를 `application/octet-stream`으로 본다. 어느 쪽이든 JSON이 아니므로 DTO 변환은 실패한다. 뒤에서 볼 415 오류의 가장 흔한 원인이다.

## @RequestPart로 메타데이터와 파일을 함께 받기

```java
@RestController
@RequestMapping("/api/notices/{noticeId}/attachments")
public class NoticeAttachmentController {

    private final AttachmentPolicy attachmentPolicy;
    private final NoticeAttachmentService attachmentService;

    public NoticeAttachmentController(AttachmentPolicy attachmentPolicy,
                                      NoticeAttachmentService attachmentService) {
        this.attachmentPolicy = attachmentPolicy;
        this.attachmentService = attachmentService;
    }

    @PostMapping(consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<AttachmentResponse> upload(
            @PathVariable Long noticeId,
            @Valid @RequestPart("metadata") AttachmentMetadata metadata,
            @RequestPart("file") MultipartFile file) {

        attachmentPolicy.validate(file);
        AttachmentResponse saved = attachmentService.store(noticeId, metadata, file);

        URI location = URI.create("/api/notices/%d/attachments/%d".formatted(noticeId, saved.id()));
        return ResponseEntity.created(location).body(saved);
    }
}

public record AttachmentMetadata(
        @NotBlank @Size(max = 200) String description,
        @NotNull AttachmentCategory category) {
}

public enum AttachmentCategory { GUIDE, FORM, ETC }

public record AttachmentResponse(Long id, String displayName, long size) {
}
```

`consumes`는 요청 전체가 `multipart/form-data`일 때만 이 메서드를 고르라는 조건이라, JSON 요청은 메서드에 들어오기 전에 415가 된다.

`@RequestPart("metadata")`는 `@RequestBody`처럼 HttpMessageConverter로 part 본문을 DTO로 바꾸고, 변환기는 part의 Content-Type으로 고른다. `@Valid`를 붙이면 Bean Validation이 적용되고, 실패하면 `MethodArgumentNotValidException`으로 400이 된다. 메타데이터를 `@RequestParam String`으로 받아 직접 파싱할 수도 있지만 DTO 검증을 손으로 다시 만들게 된다.

`@RequestPart("file")`의 문자열은 클라이언트가 보내는 part 이름과 정확히 같아야 한다. 화면이 `attachment`라는 이름으로 보내면 `MissingServletRequestPartException`이 난다. 여러 파일은 `List<MultipartFile>`로 받을 수 있지만 그때는 개수 제한과 요청 전체 크기 제한을 함께 정해야 한다. 이 예제는 요청 하나에 파일 하나만 받는다.

화면 쪽에서 가장 자주 어긋나는 부분은 메타데이터 part의 Content-Type이다. `FormData`에 `JSON.stringify` 결과를 문자열로 넣으면 그 part에는 Content-Type이 붙지 않아 `Content-Type 'application/octet-stream' is not supported`라는 415가 난다. JSON을 `Blob`으로 감싸 형식을 지정하면 해결된다.

```javascript
const form = new FormData();
form.append('metadata', new Blob([JSON.stringify(metadata)], { type: 'application/json' }));
form.append('file', fileInput.files[0]);

// Content-Type 헤더를 직접 지정하지 않는다. boundary는 브라우저가 붙인다.
await fetch(`/api/notices/${noticeId}/attachments`, { method: 'POST', body: form });
```

헤더에 `multipart/form-data`를 직접 적으면 boundary가 빠져 서버가 본문을 나누지 못한다.

## 파일 검증: 클라이언트가 보낸 값은 힌트일 뿐이다

`MultipartFile`이 주는 값은 출처가 서로 다르다.

- `getOriginalFilename()`은 클라이언트가 보낸 이름이라 확장자를 바꿀 수 있고 경로 문자가 섞일 수 있다.
- `getContentType()`은 브라우저가 확장자로 추측한 값이고, 도구로 만든 요청이라면 아무 값이나 들어온다.
- `getSize()`는 서버가 실제로 받은 바이트 수라 크기 검증에 쓴다.
- `getInputStream()`은 실제 내용이라 앞부분의 시그니처(매직 바이트) 확인에 쓴다.

그래서 허용 목록을 기준으로 검증하고 확장자와 실제 내용이 맞는지 한 번 더 본다. 형식별로 더 작은 크기 기준도 여기서 적용한다.

```java
@Component
public class AttachmentPolicy {

    private static final byte[] ZIP = {0x50, 0x4B, 0x03, 0x04};
    private static final byte[] PNG = {(byte) 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A};
    private static final byte[] PDF = "%PDF-".getBytes(StandardCharsets.US_ASCII);

    private static final Map<String, AllowedType> ALLOWED = Map.of(
            "pdf", new AllowedType(DataSize.ofMegabytes(20), PDF),
            "xlsx", new AllowedType(DataSize.ofMegabytes(20), ZIP),
            "docx", new AllowedType(DataSize.ofMegabytes(20), ZIP),
            "png", new AllowedType(DataSize.ofMegabytes(5), PNG));

    public void validate(MultipartFile file) {
        if (file.isEmpty()) {
            throw new AttachmentRejectedException(Reason.EMPTY);
        }
        AllowedType type = ALLOWED.get(extensionOf(file.getOriginalFilename()));
        if (type == null) {
            throw new AttachmentRejectedException(Reason.EXTENSION_NOT_ALLOWED);
        }
        if (file.getSize() > type.maxSize().toBytes()) {
            throw new AttachmentRejectedException(Reason.TOO_LARGE);
        }
        if (!startsWith(file, type.signature())) {
            throw new AttachmentRejectedException(Reason.SIGNATURE_MISMATCH);
        }
    }

    private static String extensionOf(String filename) {
        if (filename == null) {
            return "";
        }
        int dot = filename.lastIndexOf('.');
        return dot < 0 ? "" : filename.substring(dot + 1).toLowerCase(Locale.ROOT);
    }

    private static boolean startsWith(MultipartFile file, byte[] signature) {
        try (InputStream in = file.getInputStream()) {
            return Arrays.equals(in.readNBytes(signature.length), signature);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    private record AllowedType(DataSize maxSize, byte[] signature) {
    }
}
```

`.exe`나 `.jsp`를 막는 차단 목록 대신 허용 목록을 쓰는 이유는 막아야 할 형식을 빠짐없이 나열할 수 없기 때문이다. 화면의 `<input accept=".pdf,.xlsx">`는 사용자 편의를 위한 필터일 뿐 서버 검증을 생략할 근거가 되지 않는다.

시그니처 확인에도 한계가 있다. XLSX와 DOCX는 ZIP 형식이라 앞 4바이트로는 "ZIP 파일이다"까지만 알 수 있다. 실제 엑셀 문서인지까지 보려면 Apache POI로 열어 보거나 Apache Tika 같은 형식 판별 라이브러리를 쓰는데, 파일 전체를 읽는 만큼 비용이 커진다. 요청 안에서 할지 저장 뒤 비동기 검사로 넘길지는 첨부를 언제부터 내려받게 할지와 함께 정한다. 악성코드 검사도 같은 이유로 이 글의 범위 밖에 둔다.

## 크기 제한: spring.servlet.multipart와 MaxUploadSizeExceededException

Spring Boot의 기본 상한은 파일 하나당 1MB, 요청 하나당 10MB라서 문서 첨부에는 대개 직접 설정한다.

```yaml
spring:
  servlet:
    multipart:
      max-file-size: 20MB       # part 하나의 상한
      max-request-size: 25MB    # 메타데이터를 포함한 요청 전체의 상한
      file-size-threshold: 1MB  # 이 크기를 넘는 part는 임시 파일로 내려 쓴다
      location: /app/tmp/upload # 임시 파일 위치(지정하지 않으면 컨테이너 임시 디렉터리)
```

`max-file-size`는 형식별 정책 중 가장 큰 값 이상으로, `max-request-size`는 거기에 메타데이터와 구분선의 여유분을 더해 둔다. 이 값은 업무 정책이 아니라, 정책 검사까지 가기 전에 터무니없이 큰 요청을 끊는 최종 상한이다. `location`을 비워 두면 컨테이너 임시 디렉터리를 쓰는데, 오래 켜 둔 서버에서 OS의 임시 파일 정리 작업이 이 디렉터리를 지우면 업로드가 실패할 수 있어 경로를 명시하기도 한다.

제한을 넘으면 컨테이너가 파싱 중에 실패하고 Spring은 이를 `MaxUploadSizeExceededException`으로 바꾼다. 기본 설정에서 이 파싱은 DispatcherServlet이 핸들러를 고르기 전에 일어나므로, Controller 클래스 안의 `@ExceptionHandler`는 이 예외를 잡지 못한다. `basePackages`로 범위를 좁힌 advice도 적용되지 않을 수 있으니 범위를 제한하지 않은 `@RestControllerAdvice`에 둔다.

```java
public class AttachmentRejectedException extends RuntimeException {

    public enum Reason {
        EMPTY(HttpStatus.BAD_REQUEST, "빈 파일은 첨부할 수 없습니다."),
        EXTENSION_NOT_ALLOWED(HttpStatus.BAD_REQUEST, "허용하지 않는 파일 형식입니다."),
        TOO_LARGE(HttpStatus.PAYLOAD_TOO_LARGE, "파일 형식별 허용 크기를 넘었습니다."),
        SIGNATURE_MISMATCH(HttpStatus.BAD_REQUEST, "확장자와 실제 파일 내용이 다릅니다.");

        private final HttpStatus status;
        private final String message;

        Reason(HttpStatus status, String message) {
            this.status = status;
            this.message = message;
        }

        public HttpStatus status() {
            return status;
        }
    }

    private final Reason reason;

    public AttachmentRejectedException(Reason reason) {
        super(reason.message);
        this.reason = reason;
    }

    public Reason reason() {
        return reason;
    }
}

@RestControllerAdvice
public class UploadExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(UploadExceptionHandler.class);

    @ExceptionHandler(MaxUploadSizeExceededException.class)
    ProblemDetail handleTooLarge(MaxUploadSizeExceededException ex) {
        log.warn("업로드 크기 초과: {}", ex.getMessage());
        // Spring Framework 7부터는 HttpStatus.CONTENT_TOO_LARGE를 쓴다.
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(
                HttpStatus.PAYLOAD_TOO_LARGE, "요청 또는 파일 크기가 허용 범위를 넘었습니다.");
        problem.setProperty("code", "UPLOAD_SIZE_EXCEEDED");
        return problem;
    }

    @ExceptionHandler(AttachmentRejectedException.class)
    ProblemDetail handleRejected(AttachmentRejectedException ex) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(ex.reason().status(), ex.getMessage());
        problem.setProperty("code", "ATTACHMENT_" + ex.reason().name());
        return problem;
    }
}
```

Spring Framework 6.1부터는 `MaxUploadSizeExceededException`이 `ErrorResponse`를 구현해 별도 처리 없이도 413이 나간다. 그래도 화면이 해석할 오류 코드를 다른 업로드 오류와 같은 모양으로 맞추려면 직접 처리하는 편이 낫다.

Spring 바깥의 변수도 있다. 앞단 웹 서버에 본문 크기 제한이 있으면 요청은 Spring까지 오지 않고 그 서버의 413 페이지가 돌아간다. 요청이 제한보다 훨씬 크면 Tomcat은 남은 본문을 `server.tomcat.max-swallow-size`(기본 2MB)까지만 읽고 연결을 닫으므로, 클라이언트가 413 대신 연결 오류를 볼 수도 있다. RFC 9110도 413 상황에서 서버가 연결을 닫는 것을 허용한다.

## 저장: 원본 파일명은 표시용으로만 쓴다

RFC 7578은 수신 측이 `filename` 값을 그대로 쓰지 말고 그 안의 디렉터리 경로 정보도 사용하지 말라고 권고한다. 클라이언트가 `filename="../../webapps/ROOT/notice.jsp"`를 보내면, 원본 이름으로 경로를 조합하는 코드는 기준 디렉터리 밖에 파일을 쓸 수 있다. 저장 위치가 WAS의 웹 루트 안이라면 올라간 파일이 실행될 위험까지 생긴다. 그래서 저장 이름은 서버가 만들고, 원본 이름은 정리해서 표시용으로만 데이터베이스에 남긴다.

```java
@Component
public class AttachmentStorage {

    private final Path baseDir;

    public AttachmentStorage(@Value("${app.attachment.base-dir}") String baseDir) {
        this.baseDir = Path.of(baseDir).toAbsolutePath().normalize();
    }

    public StoredFile store(MultipartFile file, String extension) throws IOException {
        Path dir = baseDir.resolve(LocalDate.now().toString());
        Path target = dir.resolve(UUID.randomUUID() + "." + extension).normalize();
        if (!target.startsWith(baseDir)) {   // 이름을 서버가 만들어도 마지막 방어선은 남긴다
            throw new IllegalStateException("저장 경로가 기준 디렉터리를 벗어났다: " + target);
        }
        Files.createDirectories(dir);
        file.transferTo(target);             // 절대 경로를 넘긴다
        return new StoredFile(baseDir.relativize(target).toString(),
                displayNameOf(file.getOriginalFilename()));
    }

    static String displayNameOf(String original) {
        if (original == null || original.isBlank()) {
            return "attachment";
        }
        int slash = Math.max(original.lastIndexOf('/'), original.lastIndexOf('\\'));
        String name = original.substring(slash + 1).replaceAll("\\p{Cntrl}", "");
        return name.length() > 200 ? name.substring(name.length() - 200) : name;
    }
}

public record StoredFile(String storageKey, String displayName) {
}
```

`baseDir`은 절대 경로로 바꾸고 `normalize()`로 `..`를 정리한 뒤, 최종 경로가 그 아래에 있는지 `startsWith`로 확인한다. `transferTo`에 상대 경로를 넘기면 구현에 따라 컨테이너 임시 디렉터리 기준으로 해석될 수 있어 절대 경로를 넘긴다. 표시용 이름은 경로 구분자 앞부분과 제어 문자를 지우고, 확장자가 남도록 끝에서부터 길이를 자른다. 내려받을 때는 `ContentDisposition.attachment().filename(displayName, StandardCharsets.UTF_8)`로 헤더를 만들면 한글 파일명도 인코딩된다.

파일 쓰기는 데이터베이스 트랜잭션으로 되돌릴 수 없다. 그래서 Service는 파일을 먼저 쓰고 첨부 행을 저장하며, 행 저장이 실패하면 방금 쓴 파일을 지운다. 프로세스가 중간에 죽으면 주인 없는 파일이 남을 수 있으므로 데이터베이스에 없는 저장 키를 주기적으로 정리하는 작업도 둔다. 또 `MultipartFile`의 임시 파일은 요청이 끝나면 정리되므로, 응답 뒤에 처리할 작업이 있다면 `@Async`로 넘기기 전에 저장소로 먼저 옮긴다.

## MockMvc로 무엇을 고정할 것인가

MockMvc 테스트는 웹 서버 없이 URL 매핑, part 이름, JSON part 변환, 검증, 예외와 상태 코드의 연결, Service에 넘어가는 값을 확인한다. 화면과 합치기 전에 업로드 계약을 고정하는 첫 번째 안전망이다.

다만 MockMvc의 `multipart()`는 `MockMultipartHttpServletRequest`를 써서 실제 multipart 파싱을 하지 않는다. 그래서 `max-file-size`가 적용되지 않고, 아무리 큰 `MockMultipartFile`을 넣어도 `MaxUploadSizeExceededException`은 재현되지 않는다. MockMvc에서는 애플리케이션 정책의 크기 검사를 확인하고, 컨테이너 제한은 실제 서버를 띄운 테스트에서 확인한다.

```java
// static import: MockMvcRequestBuilders.multipart, MockMvcResultMatchers.*,
//                BDDMockito.given, Mockito.verify/never, ArgumentMatchers.*, Assertions.assertThat
@WebMvcTest(NoticeAttachmentController.class)
@Import(AttachmentPolicy.class)
class NoticeAttachmentControllerTest {

    private static final byte[] PDF_BYTES = "%PDF-1.7\n".getBytes(StandardCharsets.US_ASCII);

    @Autowired MockMvc mockMvc;
    @MockitoBean NoticeAttachmentService attachmentService;

    private static MockMultipartFile metadata() {
        return new MockMultipartFile("metadata", "", MediaType.APPLICATION_JSON_VALUE,
                """
                {"description":"11월 보안 점검 일정표","category":"GUIDE"}
                """.getBytes(StandardCharsets.UTF_8));
    }

    @Test
    void PDF와_메타데이터를_받으면_201과_Location을_돌려준다() throws Exception {
        MockMultipartFile file = new MockMultipartFile("file", "점검일정.pdf", "application/pdf", PDF_BYTES);
        given(attachmentService.store(eq(7L), any(), any()))
                .willReturn(new AttachmentResponse(101L, "점검일정.pdf", PDF_BYTES.length));

        mockMvc.perform(multipart("/api/notices/{noticeId}/attachments", 7L)
                        .file(file)
                        .file(metadata()))
                .andExpect(status().isCreated())
                .andExpect(header().string("Location", "/api/notices/7/attachments/101"))
                .andExpect(jsonPath("$.id").value(101));

        ArgumentCaptor<AttachmentMetadata> captor = ArgumentCaptor.forClass(AttachmentMetadata.class);
        verify(attachmentService).store(eq(7L), captor.capture(), any(MultipartFile.class));
        assertThat(captor.getValue().category()).isEqualTo(AttachmentCategory.GUIDE);
    }

    @Test
    void 빈_파일은_400이고_서비스를_호출하지_않는다() throws Exception {
        MockMultipartFile empty = new MockMultipartFile("file", "빈파일.pdf", "application/pdf", new byte[0]);

        mockMvc.perform(multipart("/api/notices/{noticeId}/attachments", 7L)
                        .file(empty)
                        .file(metadata()))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("ATTACHMENT_EMPTY"));

        verify(attachmentService, never()).store(anyLong(), any(), any());
    }

    @Test
    void 확장자만_pdf인_파일은_400으로_거부한다() throws Exception {
        MockMultipartFile disguised = new MockMultipartFile(
                "file", "안내문.pdf", "application/pdf", new byte[]{'M', 'Z', 0x00, 0x00});

        mockMvc.perform(multipart("/api/notices/{noticeId}/attachments", 7L)
                        .file(disguised)
                        .file(metadata()))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.code").value("ATTACHMENT_SIGNATURE_MISMATCH"));
    }

    @Test
    void PNG가_형식별_크기를_넘으면_413을_돌려준다() throws Exception {
        // 크기 검사가 시그니처 검사보다 먼저이므로 내용은 비어 있어도 된다.
        byte[] content = new byte[(int) DataSize.ofMegabytes(5).toBytes() + 1];
        MockMultipartFile large = new MockMultipartFile("file", "안내.png", "image/png", content);

        mockMvc.perform(multipart("/api/notices/{noticeId}/attachments", 7L)
                        .file(large)
                        .file(metadata()))
                .andExpect(status().isPayloadTooLarge())
                .andExpect(jsonPath("$.code").value("ATTACHMENT_TOO_LARGE"));
    }
}
```

메타데이터도 `MockMultipartFile`로 만들고 `application/json`을 명시한다. `.param("metadata", json)`처럼 일반 파라미터로 넣으면 실제 클라이언트와 다른 요청을 테스트하게 된다. 정상 케이스는 상태 코드뿐 아니라 `ArgumentCaptor`로 Service에 넘어간 값까지 보고, 거부 케이스는 `never()`로 잘못된 파일이 저장 단계에 가지 않았음을 고정한다. `@WebMvcTest`는 `@Component`를 스캔하지 않으므로 `AttachmentPolicy`는 `@Import`로 넣고, `@RestControllerAdvice`는 자동으로 포함된다. `@MockitoBean`은 Spring Boot 3.4(Spring Framework 6.2) 이상 기준이며, 그보다 낮은 버전에서는 `@MockBean`을 쓴다.

컨테이너 크기 제한은 테스트에서만 상한을 1KB로 낮춰 실제 서버로 확인한다.

```java
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = "spring.servlet.multipart.max-file-size=1KB")
class AttachmentUploadLimitIntegrationTest {

    @LocalServerPort int port;
    @MockitoBean NoticeAttachmentService attachmentService;

    @Test
    void 컨테이너_크기_제한을_넘으면_413을_돌려준다() {
        MultipartBodyBuilder body = new MultipartBodyBuilder();
        body.part("metadata", """
                {"description":"크기 제한 확인","category":"ETC"}
                """, MediaType.APPLICATION_JSON);
        body.part("file", new ByteArrayResource(new byte[2048]) {
            @Override
            public String getFilename() {
                return "large.pdf";
            }
        }, MediaType.APPLICATION_PDF);

        RestClient client = RestClient.create("http://localhost:" + port);

        assertThatThrownBy(() -> client.post()
                .uri("/api/notices/{noticeId}/attachments", 7L)
                .contentType(MediaType.MULTIPART_FORM_DATA)
                .body(body.build())
                .retrieve()
                .toBodilessEntity())
                .isInstanceOfSatisfying(HttpClientErrorException.class,
                        ex -> assertThat(ex.getStatusCode().value()).isEqualTo(413));
    }
}
```

`@SpringBootTest`는 전체 컨텍스트를 띄워 데이터베이스 같은 설정도 필요하고 느리다. 그래서 컨테이너가 관여하는 계약에만 쓰고 나머지 규칙은 MockMvc 테스트에 둔다.

## 어떻게 확인하나

먼저 웹 계층 테스트를 실행한다.

```bash
./gradlew test --tests "*NoticeAttachmentControllerTest"
```

실패한 테스트에 `.andDo(print())`를 붙이고 `Resolved Exception` 항목부터 본다. 상태 코드만으로는 400이 part 누락인지 검증 실패인지 알 수 없지만, 여기에는 예외 타입이 그대로 나온다.

```text
Resolved Exception:
             Type = org.springframework.web.multipart.support.MissingServletRequestPartException

MockHttpServletResponse:
           Status = 400
```

다음으로 로컬 서버에 curl로 실제 multipart 요청을 보낸다. `-F`의 `;type=`이 part의 Content-Type이다. 두 번째 요청처럼 type을 빼면 화면에서 `Blob` 없이 문자열을 넣은 상황이 재현된다.

```bash
# 정상 요청: 201과 Location을 기대한다
curl -i -X POST http://localhost:8080/api/notices/7/attachments \
  -F 'metadata={"description":"11월 보안 점검 일정표","category":"GUIDE"};type=application/json' \
  -F 'file=@./점검일정.pdf;type=application/pdf'

# 재현용: metadata part에 Content-Type이 없으면 415가 나와야 한다
curl -i -X POST http://localhost:8080/api/notices/7/attachments \
  -F 'metadata={"description":"11월 보안 점검 일정표","category":"GUIDE"}' \
  -F 'file=@./점검일정.pdf'
```

서버 로그에는 다음과 같은 줄이 남는다. 메시지 문구는 Spring 버전에 따라 조금 다를 수 있다.

```text
WARN  .w.s.m.s.DefaultHandlerExceptionResolver : Resolved [org.springframework.web.HttpMediaTypeNotSupportedException: Content-Type 'application/octet-stream' is not supported]
WARN  .w.s.m.s.DefaultHandlerExceptionResolver : Resolved [org.springframework.web.multipart.support.MissingServletRequestPartException: Required part 'file' is not present.]
WARN  c.e.portal.notice.UploadExceptionHandler : 업로드 크기 초과: Maximum upload size exceeded
```

실패했을 때 처음 확인할 것은 응답 상태와 본문의 출처다.

- 415에 `application/octet-stream`이 보이면 메타데이터 part의 Content-Type이 빠졌다. `application/json`이 보이면 요청 전체가 multipart가 아니다.
- 400에 `Required part`가 보이면 화면, API 문서, `@RequestPart`의 part 이름을 비교한다.
- 413 본문이 HTML이면 앞단 웹 서버가 거절한 것이고, ProblemDetail JSON이면 `code` 값으로 컨테이너 제한인지 정책 위반인지 구분한다.
- 응답 없이 연결이 끊기면 요청이 제한보다 훨씬 커서 컨테이너가 연결을 닫았을 가능성이 크다.

## 정리

- 파일이 실제로 포함될 때만 `multipart/form-data`를 쓰고, Base64 JSON은 아주 작은 데이터에만 쓴다.
- 메타데이터는 `@Valid @RequestPart` DTO로, 파일은 `@RequestPart MultipartFile`로 받고 part 이름을 API 문서에 고정한다.
- 화면은 메타데이터를 `application/json` Blob으로 넣고 multipart Content-Type 헤더를 직접 쓰지 않는다.
- 파일명과 Content-Type은 힌트로만 보고, 크기는 `getSize()`로, 형식은 허용 목록과 시그니처로 확인한다.
- `max-file-size`, `max-request-size`는 최종 상한으로 두고 초과 예외는 범위를 좁히지 않은 전역 advice에서 처리한다.
- 저장 이름은 서버가 만들고 최종 경로가 기준 디렉터리 안인지 확인한다.
- MockMvc로 part 이름, 검증, 상태 코드, Service 호출 여부를 고정하고 컨테이너 제한은 실제 서버 테스트로 따로 확인한다.

## 참고한 공식 문서

- [Spring Framework Reference - Multipart](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-controller/ann-methods/multipart-forms.html)
- [Spring Boot Reference - Handling Multipart File Uploads](https://docs.spring.io/spring-boot/how-to/spring-mvc.html#howto.spring-mvc.multipart-file-uploads)
- [Spring Framework Javadoc - MaxUploadSizeExceededException](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/web/multipart/MaxUploadSizeExceededException.html)
- [Spring Framework Reference - MockMvc Performing Requests](https://docs.spring.io/spring-framework/reference/testing/mockmvc/hamcrest/requests.html)
- [RFC 7578 - Returning Values from Forms: multipart/form-data](https://www.rfc-editor.org/rfc/rfc7578.html#section-4.2)
