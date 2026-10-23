---
title: "결재 문서 API에서 없음·권한 없음·상태 충돌을 Optional과 예외로 구분하기"
date: 2026-08-25 00:05:00 +0900
tags: [Java, Optional, Exception, Spring, Backend]
excerpt: "결재 문서 조회·승인 API에서 실패 이유를 Optional과 도메인 예외로 나누고, @RestControllerAdvice와 ProblemDetail로 404·403·409를 일관되게 응답하는 방법을 정리한다."
redirect_from:
  - /posts/java-optional-product-not-found/
  - /posts/java-exception-post-update/
---

결재 시스템에서 자주 호출되는 API는 문서 상세 조회와 승인·반려 같은 상태 변경이다. 두 API 모두 "처리할 수 없다"로 끝나는 경우가 있는데, 그 이유는 하나가 아니다. 기안자가 회수해 문서가 더는 없을 수 있고, 다른 부서 문서라 권한이 없을 수 있고, 다른 결재자가 먼저 반려해 상태가 이미 바뀌었을 수도 있다. 이 셋을 `null`이나 `false`, 혹은 "처리 실패"라는 메시지 하나로 뭉치면 화면은 사용자에게 무엇을 안내해야 할지 모르고, 운영자는 로그만 보고 원인을 가를 수 없다. 이 글은 "값이 없을 수 있다"는 사실은 `Optional`로, "값은 있지만 더 진행할 수 없는 이유"는 도메인 예외로 표현하고, 이를 `@RestControllerAdvice`에서 RFC 9457 형식의 `ProblemDetail` 응답으로 바꾸는 흐름을 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 실패 이유가 한 덩어리가 되면 생기는 일

결재 알림 메일의 링크를 눌러 `GET /api/approvals/1024`가 호출되고, 이어서 승인 버튼으로 `POST /api/approvals/1024/approve`가 호출된다고 하자. 초기 구현에서 흔히 보이는 모양은 다음과 같다.

```java
// 실패 이유가 사라지는 구현
public ApprovalDocumentDetail getDetail(long documentId, String employeeNo) {
    ApprovalDocument document = approvalMapper.selectDocument(documentId); // 없으면 null
    if (!document.isVisibleTo(employeeNo)) {                               // 없으면 여기서 NPE
        return null;                                                       // 권한 없음도 null
    }
    return ApprovalDocumentDetail.from(document);
}

public boolean approve(long documentId, String employeeNo) {
    try {
        ApprovalDocument document = approvalMapper.selectDocument(documentId);
        document.approve(employeeNo);
        approvalMapper.updateStatus(document);
        return true;
    } catch (Exception e) {
        log.error("결재 처리 실패");   // 원인 예외도, 문서 번호도 남지 않는다
        return false;
    }
}
```

문서가 없으면 `NullPointerException`이 나서 500이 된다. 권한이 없으면 `null`이 반환되어 Controller가 본문 없는 200을 내보낸다. 승인 실패는 `false` 하나로만 표현되니 화면은 "다시 시도" 버튼밖에 보여 줄 수 없는데, 이미 반려된 문서라면 몇 번을 다시 시도해도 결과는 같다. 로그에는 "결재 처리 실패"만 남아 어느 문서에서 무엇 때문에 실패했는지 추적할 수 없다.

필요한 것은 실패 이유마다 "누가 무엇을 하면 해결되는가"를 구분하는 일이다.

| 실패 이유 | 예시 | HTTP 상태 | 클라이언트가 할 일 |
| --- | --- | --- | --- |
| 대상 없음 | 기안자가 회수해 삭제된 문서 | 404 Not Found | 목록으로 돌아간다 |
| 권한 없음 | 결재선에 없는 사원의 승인 시도 | 403 Forbidden | 담당자에게 문의한다 |
| 상태 충돌 | 이미 반려됐거나 아직 본인 차례가 아닌 문서 | 409 Conflict | 새로고침해 최신 상태를 본다 |
| 입력 오류 | 반려 사유 누락 | 400 Bad Request | 입력을 고쳐 다시 보낸다 |

RFC 9110은 409를 대상 리소스의 현재 상태와 충돌해 요청을 끝낼 수 없을 때 쓰는 코드로 정의하고, 사용자가 충돌 원인을 알아볼 수 있을 만큼의 정보를 응답에 담으라고 권한다. 403에 대해서는 대상의 존재 자체를 숨기고 싶다면 404로 응답해도 된다고 적고 있다. 다른 부서 문서가 있다는 사실조차 알리면 안 되는 시스템이라면 권한 없음도 밖으로는 404로 내보내는 선택지가 있다는 뜻이다. 어느 쪽을 고르든 서버 안에서는 두 경우를 구분해 로그에 남겨야 한다. 입력 오류는 Bean Validation이 맡는 영역이므로 이 글에서는 나머지 세 가지에 집중한다.

## Optional은 "없을 수 있다"를 반환값으로 약속한다

첫 번째 분기는 문서가 없을 수 있다는 사실이다. `Optional` Javadoc은 이 타입의 주된 용도를 "결과 없음"을 표현해야 하고 `null`을 쓰면 오류가 나기 쉬운 메서드의 반환 타입으로 설명한다. 그리고 `Optional` 타입 변수 자체는 절대 `null`이어서는 안 되며 항상 `Optional` 인스턴스를 가리켜야 한다고 적는다.

Spring Data JPA의 `findById`는 이미 `Optional`을 돌려준다. MyBatis 매퍼처럼 결과가 없을 때 `null`을 돌려주는 조회라면 Repository 경계에서 한 번 감싸 두면 된다. 그러면 Service부터는 `null`을 다룰 일이 없다.

```java
public interface ApprovalDocumentRepository {
    Optional<ApprovalDocument> findById(long documentId);
    Optional<ApprovalDocument> findByIdForUpdate(long documentId);
    void updateStatus(ApprovalDocument document);
}

@Repository
public class MyBatisApprovalDocumentRepository implements ApprovalDocumentRepository {

    private final ApprovalMapper approvalMapper;

    public MyBatisApprovalDocumentRepository(ApprovalMapper approvalMapper) {
        this.approvalMapper = approvalMapper;
    }

    @Override
    public Optional<ApprovalDocument> findById(long documentId) {
        return Optional.ofNullable(approvalMapper.selectDocument(documentId));
    }

    @Override
    public Optional<ApprovalDocument> findByIdForUpdate(long documentId) {
        return Optional.ofNullable(approvalMapper.selectDocumentForUpdate(documentId));
    }

    @Override
    public void updateStatus(ApprovalDocument document) {
        approvalMapper.updateStatus(document);
    }
}

@Service
@Transactional(readOnly = true)
public class ApprovalQueryService {

    private final ApprovalDocumentRepository documentRepository;
    private final ApprovalAccessPolicy accessPolicy;

    public ApprovalQueryService(ApprovalDocumentRepository documentRepository,
                                ApprovalAccessPolicy accessPolicy) {
        this.documentRepository = documentRepository;
        this.accessPolicy = accessPolicy;
    }

    public ApprovalDocumentDetail getDetail(long documentId, String employeeNo) {
        ApprovalDocument document = documentRepository.findById(documentId)
                .orElseThrow(() -> new ApprovalDocumentNotFoundException(documentId));

        if (!accessPolicy.canRead(employeeNo, document)) {
            throw new ApprovalAccessDeniedException(documentId, employeeNo);
        }
        return ApprovalDocumentDetail.from(document);
    }
}
```

`orElseThrow` 다음 줄부터는 문서가 반드시 있다는 전제로 읽힌다. 같은 자리에 `get()`을 쓰면 값이 없을 때 `NoSuchElementException`이 나는데, 그 예외에는 문서 번호도 이유도 담기지 않는다. Javadoc도 `get()`보다 `orElseThrow()`를 선호하는 대안으로 안내한다.

"없음"을 표현하는 다른 방법과도 비교해 두자. 첫째는 `null`을 돌려주고 `@Nullable` 같은 애너테이션으로 표시하는 방식이다. 추가 객체가 없고 기존 MyBatis 코드와 잘 맞지만, 이 표시는 컴파일러가 강제하지 않는다. 정적 분석 도구를 함께 돌리지 않는 팀이라면 확인 누락을 막지 못한다. 둘째는 Repository가 `getById`처럼 없으면 곧바로 예외를 던지는 방식이다. 호출부는 짧아지지만 중복 검사처럼 "없어야 정상"인 호출에서도 예외를 잡아야 하고, 어떤 실패로 응답할지를 저장소 계층이 정해 버린다. `Optional`은 그 사이에서 "없을 수 있다"를 타입으로 드러내고, 없을 때 무엇을 할지는 호출한 쪽이 고르게 한다. 다만 받은 쪽이 다시 `isPresent()`와 `get()`으로 풀어 쓰면 `null` 검사와 다를 바가 없다. `orElseThrow`, `map`, `orElseGet`처럼 의도가 드러나는 메서드로 바로 이어 쓰는 편이 낫다.

### Optional을 쓰지 않는 자리

`Optional`을 반환값에만 쓰는 데는 이유가 있다.

- 필드: `Optional`은 `Serializable`이 아니고, 필드로 두면 "필드가 `null`", "비어 있음", "값 있음"이라는 세 상태가 생긴다. 반려 사유처럼 비어 있을 수 있는 값은 필드를 일반 타입으로 두고, 꺼내는 메서드가 `Optional<String>`을 돌려주게 하면 충분하다.
- 파라미터: `search(Optional<String> keyword)`는 감싸는 일을 호출자에게 떠넘기고, 그래도 호출자는 `null`을 넘길 수 있다. 조건이 여럿이면 검색 조건 객체를 두거나 메서드를 오버로딩한다.
- 컬렉션: 여러 건을 돌려주는 조회라면 `Optional<List<...>>` 대신 빈 리스트를 돌려준다. "없음"을 표현하는 방법이 두 가지가 되면 호출부의 분기도 두 배가 된다.
- 없으면 버그인 값: 기안자가 없는 결재 문서처럼 "있어야만 정상"인 데이터를 `Optional`로 감싸 404로 내보내면 데이터 정합성 문제가 평범한 클라이언트 오류처럼 묻힌다. 이런 경우는 `IllegalStateException`으로 실패시켜 500으로 드러내는 편이 원인을 빨리 찾게 해 준다.

`orElse`와 `orElseGet`의 차이도 자주 놓친다. `orElse`의 인자는 값이 있든 없든 먼저 평가되므로 첫 번째 줄은 양식이 있어도 기본 양식 조회 쿼리를 매번 실행한다.

```java
// 값이 있어도 loadDefaultTemplate()이 먼저 실행된다
FormTemplate eager = templateRepository.findByCode(formCode)
        .orElse(templateRepository.loadDefaultTemplate());

// 비어 있을 때만 실행된다
FormTemplate lazy = templateRepository.findByCode(formCode)
        .orElseGet(templateRepository::loadDefaultTemplate);
```

## 도메인 예외 계층: 이유는 타입으로, 세부 정보는 필드로

문서를 찾은 뒤의 두 실패, 즉 권한과 상태는 `Optional`로 표현할 수 없다. "값이 없다"가 아니라 "값은 있는데 진행할 수 없다"이기 때문이다. 여기서 예외를 쓴다. 타입을 나누는 기준은 단순하다. HTTP 응답이나 클라이언트의 다음 행동이 달라지는 실패만 별도 타입으로 만들고, 같은 처리로 끝나는 세부 조건은 하나의 타입 안에서 필드로 구분한다. 조건마다 클래스를 만들면 이름만 늘고 처리 코드는 그대로 중복된다.

```java
public abstract class ApprovalException extends RuntimeException {

    private final String errorCode;
    private final long documentId;

    protected ApprovalException(String errorCode, long documentId, String message) {
        super(message);
        this.errorCode = errorCode;
        this.documentId = documentId;
    }

    public String getErrorCode() { return errorCode; }
    public long getDocumentId() { return documentId; }
}

public class ApprovalDocumentNotFoundException extends ApprovalException {
    public ApprovalDocumentNotFoundException(long documentId) {
        super("APPROVAL_DOCUMENT_NOT_FOUND", documentId,
                "결재 문서 없음. documentId=" + documentId);
    }
}

public class ApprovalAccessDeniedException extends ApprovalException {
    public ApprovalAccessDeniedException(long documentId, String employeeNo) {
        super("APPROVAL_ACCESS_DENIED", documentId,
                "결재 권한 없음. documentId=" + documentId + ", employeeNo=" + employeeNo);
    }
}

public class ApprovalStateConflictException extends ApprovalException {

    private final ApprovalStatus currentStatus;

    public ApprovalStateConflictException(long documentId, ApprovalStatus currentStatus,
                                          ApprovalAction action) {
        super("APPROVAL_STATE_CONFLICT", documentId,
                "결재 상태 충돌. documentId=" + documentId
                        + ", status=" + currentStatus + ", action=" + action);
        this.currentStatus = currentStatus;
    }

    public ApprovalStatus getCurrentStatus() { return currentStatus; }
}
```

예외 메시지에는 사번이나 상태처럼 조사에 필요한 내부 정보를 담는다. 이 메시지는 로그용이고 응답 본문에는 그대로 내보내지 않는다. 이 구분은 뒤의 advice에서 다시 다룬다.

상태 규칙은 문서 객체가 스스로 지키게 하고, 서비스는 확인 순서를 책임진다.

```java
public class ApprovalDocument {

    private final long id;
    private final Set<String> approvalLine;   // 결재선에 있는 사번
    private ApprovalStatus status;
    private String currentApproverNo;
    private LocalDateTime lastProcessedAt;

    // 생성자와 조회 메서드는 생략

    public boolean hasApprover(String employeeNo) {
        return approvalLine.contains(employeeNo);
    }

    public void approve(String approverNo, LocalDateTime now) {
        if (status != ApprovalStatus.IN_PROGRESS || !approverNo.equals(currentApproverNo)) {
            throw new ApprovalStateConflictException(id, status, ApprovalAction.APPROVE);
        }
        this.status = ApprovalStatus.APPROVED;   // 다음 결재자가 있으면 차례를 넘기는 로직이 들어간다
        this.lastProcessedAt = now;
    }
}

@Service
public class ApprovalCommandService {

    private final ApprovalDocumentRepository documentRepository;
    private final Clock clock;

    public ApprovalCommandService(ApprovalDocumentRepository documentRepository, Clock clock) {
        this.documentRepository = documentRepository;
        this.clock = clock;
    }

    @Transactional
    public void approve(long documentId, String approverNo) {
        ApprovalDocument document = documentRepository.findByIdForUpdate(documentId)
                .orElseThrow(() -> new ApprovalDocumentNotFoundException(documentId));

        if (!document.hasApprover(approverNo)) {
            throw new ApprovalAccessDeniedException(documentId, approverNo);
        }
        document.approve(approverNo, LocalDateTime.now(clock));
        documentRepository.updateStatus(document);
    }
}
```

확인 순서는 존재, 권한, 상태다. 권한보다 상태를 먼저 보면 결재선에 없는 사람도 409 응답에 담긴 현재 상태로 남의 문서가 어떻게 됐는지 엿볼 수 있다.

상태 검사만으로는 동시에 들어온 두 요청을 막지 못한다는 점도 기억해야 한다. 두 결재자가 같은 순간 승인과 반려를 누르면 둘 다 `IN_PROGRESS`를 읽고 통과할 수 있다. 그래서 변경용 조회는 잠금을 걸어 두 번째 요청이 첫 번째 커밋 이후의 상태를 읽고 409로 끝나게 한다. 잠금 대신 버전 컬럼으로 갱신 건수를 확인하는 낙관적 잠금도 선택지다.

```xml
<select id="selectDocumentForUpdate" resultMap="approvalDocumentMap">
    SELECT document_id, status, current_approver_no, last_processed_at
      FROM approval_document
     WHERE document_id = #{documentId}
       FOR UPDATE
</select>
```

## checked와 unchecked는 "호출자가 복구할 수 있는가"로 고른다

Java 튜토리얼의 기준은 짧다. 호출자가 합리적으로 복구할 수 있는 예외라면 checked로, 복구할 방법이 없다면 unchecked로 만든다. 웹 요청 안에서 문서 없음, 권한 없음, 상태 충돌은 Service를 부른 Controller가 복구할 수 있는 일이 아니다. 요청을 끝내고 알맞은 응답으로 바꿀 뿐이다. 이를 checked로 만들면 Service와 Controller 시그니처마다 `throws`가 번지지만 결국 하는 일은 advice로 넘기는 것뿐이다.

Spring에서는 이유가 하나 더 있다. 선언적 트랜잭션의 기본 롤백 규칙은 `RuntimeException`과 `Error`에만 롤백하고, checked 예외에는 롤백하지 않는다. 승인 처리 도중 checked 예외를 던지면 기본 설정에서는 그때까지의 변경이 커밋될 수 있다. checked 예외를 쓰기로 했다면 `rollbackFor`를 명시해야 한다.

checked가 어울리는 곳도 있다. 첨부파일을 일괄 이관하는 배치에서 파일 하나를 읽다가 `IOException`이 나면, 호출자는 그 건만 실패 목록에 기록하고 다음 파일로 넘어갈 수 있다. 호출자에게 실제로 다른 선택지가 있을 때가 checked를 쓸 때다. 이런 예외를 unchecked로 감싸 올릴 때는 원인 예외를 생성자의 `cause`로 넘겨 스택 트레이스를 잃지 않게 한다.

예외 대신 결과 객체를 돌려주는 방식도 비교해 볼 만하다. 결재함에서 서른 건을 골라 일괄 승인할 때 일부가 이미 처리됐다고 전체를 멈추면 안 된다. 이때는 건별 성공과 실패 사유를 담은 결과 목록을 돌려주는 편이 맞다. 반대로 단건 승인에서 결과 객체를 쓰면 호출자가 매번 성공 여부를 확인해야 하고, 확인을 빠뜨리면 실패가 성공처럼 흘러간다. 실패가 요청의 끝이면 예외, 실패도 정상 출력의 일부면 결과 객체로 나누면 된다.

## @RestControllerAdvice에서 ProblemDetail로 바꾼다

도메인 예외를 HTTP로 옮기는 일은 한곳에 모은다. Spring Framework 6부터 제공되는 `ProblemDetail`은 RFC 9457의 `type`, `title`, `status`, `detail`, `instance`를 담는 객체이고, `@ExceptionHandler`에서 반환하면 `instance`가 요청 경로로 채워진다. 표준에 없는 값은 `setProperty`로 추가하면 Jackson이 최상위 JSON 필드로 펼쳐 준다.

```java
@RestController
@RequestMapping("/api/approvals")
public class ApprovalController {

    private final ApprovalQueryService queryService;
    private final ApprovalCommandService commandService;

    public ApprovalController(ApprovalQueryService queryService,
                              ApprovalCommandService commandService) {
        this.queryService = queryService;
        this.commandService = commandService;
    }

    // 예제에서는 인증 정보를 헤더로 단순화했다. 실제로는 인증 객체에서 사번을 꺼낸다.
    @GetMapping("/{documentId}")
    public ApprovalDocumentDetail detail(@PathVariable("documentId") long documentId,
                                         @RequestHeader("X-Employee-No") String employeeNo) {
        return queryService.getDetail(documentId, employeeNo);
    }

    @PostMapping("/{documentId}/approve")
    public ResponseEntity<Void> approve(@PathVariable("documentId") long documentId,
                                        @RequestHeader("X-Employee-No") String employeeNo) {
        commandService.approve(documentId, employeeNo);
        return ResponseEntity.noContent().build();
    }
}

@RestControllerAdvice
public class ApprovalExceptionHandler {

    private static final Logger log = LoggerFactory.getLogger(ApprovalExceptionHandler.class);

    @ExceptionHandler(ApprovalDocumentNotFoundException.class)
    public ProblemDetail handleNotFound(ApprovalDocumentNotFoundException ex) {
        log.info("approval.not_found {}", ex.getMessage());
        return problem(HttpStatus.NOT_FOUND, "결재 문서 없음",
                "요청한 결재 문서를 찾을 수 없습니다.", ex);
    }

    @ExceptionHandler(ApprovalAccessDeniedException.class)
    public ProblemDetail handleAccessDenied(ApprovalAccessDeniedException ex) {
        log.warn("approval.access_denied {}", ex.getMessage());
        return problem(HttpStatus.FORBIDDEN, "결재 권한 없음",
                "이 결재 문서를 처리할 권한이 없습니다.", ex);
    }

    @ExceptionHandler(ApprovalStateConflictException.class)
    public ProblemDetail handleConflict(ApprovalStateConflictException ex) {
        log.info("approval.conflict {}", ex.getMessage());
        ProblemDetail problem = problem(HttpStatus.CONFLICT, "결재 상태 충돌",
                "문서 상태가 바뀌어 요청을 처리할 수 없습니다. 최신 상태를 확인하세요.", ex);
        problem.setProperty("currentStatus", ex.getCurrentStatus().name());
        return problem;
    }

    private ProblemDetail problem(HttpStatus status, String title, String detail,
                                  ApprovalException ex) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setType(URI.create("https://docs.example.com/problems/"
                + ex.getErrorCode().toLowerCase(Locale.ROOT).replace('_', '-')));
        problem.setTitle(title);
        problem.setProperty("errorCode", ex.getErrorCode());
        return problem;
    }
}
```

`detail`에는 고정 문구만 넣고 예외 메시지는 로그에만 남긴다. RFC 9457은 스택 덤프 같은 구현 내부 정보를 problem details로 노출하지 말라고 경고하며, 이 형식은 HTTP 인터페이스를 설명하기 위한 것이지 구현을 디버깅하는 도구가 아니라고 말한다. 404와 409는 업무상 예상 가능한 결과이므로 스택 트레이스 없이 INFO로 남기고, 권한 위반은 감사 관점에서 따로 볼 수 있게 WARN으로 남겼다. 예외 이름을 바탕으로 만든 `type` URI는 클라이언트가 문제 종류를 구분하는 기본 식별자가 되므로, 한번 공개한 값은 바꾸지 않는다.

로그를 남기는 위치도 이곳 하나로 정한다. Service에서 예외를 잡아 로그를 찍고 다시 던지면, 같은 실패가 Service와 advice와 서버 오류 로그에 두세 번 기록된다. 장애 상황에서 로그 건수가 실제 실패 건수보다 부풀어 보이고, 어느 줄이 원인인지 가리기도 어려워진다. 예외를 던지는 쪽은 메시지와 필드에 정보를 담는 데 집중하고, 기록과 응답 변환은 처리하는 쪽이 한 번만 하는 편이 읽기 쉽다.

이미 반려된 문서를 승인하려 하면 응답은 다음처럼 나간다.

```http
HTTP/1.1 409 Conflict
Content-Type: application/problem+json

{
  "type": "https://docs.example.com/problems/approval-state-conflict",
  "title": "결재 상태 충돌",
  "status": 409,
  "detail": "문서 상태가 바뀌어 요청을 처리할 수 없습니다. 최신 상태를 확인하세요.",
  "instance": "/api/approvals/1024/approve",
  "errorCode": "APPROVAL_STATE_CONFLICT",
  "currentStatus": "REJECTED"
}
```

Spring Boot에서 아래 설정을 켜면 400, 405, 415처럼 Spring MVC가 직접 만드는 오류도 같은 형식으로 나가므로, 클라이언트가 다뤄야 할 오류 본문이 한 가지로 줄어든다.

```yaml
spring:
  mvc:
    problemdetails:
      enabled: true
```

HTTP로 옮기는 방법은 이것만 있는 것은 아니다.

| 방식 | 장점 | 쓰지 않는 편이 나은 경우 |
| --- | --- | --- |
| Service에서 `ResponseStatusException` | 예외 클래스가 필요 없다 | 같은 Service를 배치나 메시지 소비자에서도 호출할 때. HTTP가 없는 곳에 HTTP 상태가 섞인다 |
| 예외 클래스에 `@ResponseStatus` | 선언만으로 상태 코드가 정해진다 | `errorCode`, `currentStatus`처럼 본문을 직접 구성해야 할 때 |
| `ErrorResponseException` 상속 | `ResponseEntityExceptionHandler`(앞의 설정으로 켜지는 처리기)가 별도 매핑 없이 ProblemDetail로 렌더링한다 | 도메인 계층이 spring-web에 의존하면 안 될 때 |
| 도메인 예외와 advice(이 글) | 도메인은 HTTP를 모르고 매핑이 한곳에 모인다 | 실패 유형이 두세 개뿐인 작은 API. 클래스 수 대비 얻는 것이 적다 |

## 어떻게 확인하나

먼저 도메인 규칙을 단위 테스트로 고정한다. 반려된 문서를 승인하면 상태 충돌 예외가 나고, 그 안에 현재 상태가 담기는지 본다.

```java
class ApprovalDocumentTest {

    @Test
    void 반려된_문서를_승인하면_상태_충돌_예외가_난다() {
        ApprovalDocument document = ApprovalDocumentFixture.rejected(1024L, "E1001");

        assertThatThrownBy(() -> document.approve("E1001", LocalDateTime.of(2026, 8, 25, 9, 0)))
                .isInstanceOf(ApprovalStateConflictException.class)
                .extracting("currentStatus")
                .isEqualTo(ApprovalStatus.REJECTED);
    }
}
```

다음은 예외가 advice를 거쳐 기대한 상태 코드와 본문이 되는지 확인하는 MockMvc 테스트다. `@WebMvcTest`는 Controller와 함께 `@ControllerAdvice` 빈도 불러오므로 advice까지 한 번에 검증된다. Spring Boot 3.4 이상 기준이며, 그보다 낮은 버전에서는 `@MockitoBean` 대신 `@MockBean`을 쓴다.

```java
@WebMvcTest(ApprovalController.class)
class ApprovalControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockitoBean
    private ApprovalQueryService queryService;

    @MockitoBean
    private ApprovalCommandService commandService;

    @Test
    void 없는_문서는_404_problem_json으로_응답한다() throws Exception {
        given(queryService.getDetail(9999L, "E1001"))
                .willThrow(new ApprovalDocumentNotFoundException(9999L));

        mockMvc.perform(get("/api/approvals/9999").header("X-Employee-No", "E1001"))
                .andExpect(status().isNotFound())
                .andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_PROBLEM_JSON))
                .andExpect(jsonPath("$.errorCode").value("APPROVAL_DOCUMENT_NOT_FOUND"))
                .andExpect(jsonPath("$.instance").value("/api/approvals/9999"));
    }

    @Test
    void 이미_반려된_문서를_승인하면_409와_현재_상태를_돌려준다() throws Exception {
        willThrow(new ApprovalStateConflictException(1024L, ApprovalStatus.REJECTED, ApprovalAction.APPROVE))
                .given(commandService).approve(1024L, "E1001");

        mockMvc.perform(post("/api/approvals/1024/approve").header("X-Employee-No", "E1001"))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.errorCode").value("APPROVAL_STATE_CONFLICT"))
                .andExpect(jsonPath("$.currentStatus").value("REJECTED"));
    }
}
```

로컬에서 띄운 서버에는 `curl -i -X POST http://localhost:8080/api/approvals/1024/approve -H "X-Employee-No: E1001"`로 요청하고, 상태 줄과 `Content-Type`, 본문의 `errorCode`를 확인한다. 서버 로그에는 advice가 남긴 한 줄이 보여야 한다.

```text
INFO  c.e.approval.web.ApprovalExceptionHandler : approval.conflict 결재 상태 충돌. documentId=1024, status=REJECTED, action=APPROVE
```

기대와 다르게 나오면 다음 순서로 본다.

- 404가 아니라 500이고 로그에 `NoSuchElementException`이 있다면 어딘가에서 `Optional.get()`을 호출하고 있다.
- 500인데 로그에 `ApprovalDocumentNotFoundException`이 그대로 찍혀 있다면 advice가 등록되지 않은 것이다. advice 클래스가 컴포넌트 스캔 범위 안에 있는지, `basePackages` 같은 적용 범위 설정이 Controller를 포함하는지 확인한다.
- 200인데 본문이 비어 있다면 중간 어딘가에서 예외를 잡고 `null`을 반환하고 있다.
- 400이어야 할 요청까지 500이 된다면 `Exception.class` 전체를 잡는 핸들러가 Spring MVC의 기본 예외까지 가로채고 있는지 본다.
- 두 사람이 동시에 처리했는데 둘 다 성공했다면 변경용 조회가 잠금 없는 `findById`를 쓰고 있지 않은지 확인한다.

## 정리

- 단건 조회 결과가 없을 수 있으면 반환 타입을 `Optional`로 하고, 필드·파라미터·컬렉션에는 쓰지 않는다.
- `get()` 대신 `orElseThrow`로 없을 때의 이유를 예외 타입으로 남기고, 기본값 계산이 비싸면 `orElseGet`을 쓴다.
- 응답이나 클라이언트 행동이 달라지는 실패만 예외 타입으로 나누고, 세부 정보는 필드로 담는다.
- 확인 순서는 존재, 권한, 상태로 두고, 상태 검사는 잠금이나 버전 확인과 함께 쓴다.
- 요청 흐름에서 복구할 수 없는 실패는 unchecked로 만든다. checked를 쓴다면 트랜잭션 롤백 규칙을 확인한다.
- HTTP 매핑은 `@RestControllerAdvice` 한곳에 모으고, `detail`은 고정 문구로, 내부 정보는 로그로만 보낸다.
- 404·403·409마다 MockMvc 테스트로 상태 코드와 `errorCode`를 고정해 둔다.

## 참고한 공식 문서

- [Optional (Java SE 21 API)](https://docs.oracle.com/en/java/javase/21/docs/api/java.base/java/util/Optional.html)
- [Unchecked Exceptions — The Controversy (The Java Tutorials)](https://docs.oracle.com/javase/tutorial/essential/exceptions/runtime.html)
- [Spring Framework Reference: Error Responses](https://docs.spring.io/spring-framework/reference/web/webmvc/mvc-ann-rest-exceptions.html)
- [RFC 9457: Problem Details for HTTP APIs](https://www.rfc-editor.org/rfc/rfc9457.html)
- [RFC 9110: HTTP Semantics, 15.5 Client Error 4xx](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5)
