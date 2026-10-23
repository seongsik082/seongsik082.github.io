---
title: "결재 요청 생성 API에서 201 Created와 Location을 설계하고 MockMvc로 검증하기"
date: 2026-10-22 08:55:00 +0900
tags: [Spring, HTTP, REST API, Testing, Backend]
excerpt: "결재 요청(기안) 생성 API를 예로 200·201·202 선택 기준, Location 헤더를 만드는 순서와 주의점, MockMvc로 상태·헤더·본문을 함께 검증하는 방법을 정리한다."
redirect_from:
  - /posts/spring-reservation-created-location/
  - /posts/spring-mockmvc-reservation-created-test/
---

전자결재 화면에서 기안자가 출장비 정산서를 작성하고 "상신" 버튼을 누르면 서버에는 결재 문서 한 건과 결재선이 만들어지고, 화면은 방금 만든 문서의 상세 화면으로 이동한다. 응답이 "성공했다"만 알려 주면 화면은 본문에서 ID를 꺼내 상세 주소를 직접 조합해야 하고, 서버의 경로 규칙이 바뀔 때마다 함께 고쳐야 한다. 응답의 상태 코드와 Location 헤더가 "새 문서가 생겼고 여기서 조회할 수 있다"를 정확히 알려 주면, 그 약속을 테스트로 고정할 수 있다. 이 글은 결재 요청 생성 API 하나로 상태 코드 선택, Location을 만드는 방법과 순서, 중복 제출의 한계, MockMvc 검증과 흔한 실패를 정리한다.

> 이 글의 예제는 개념을 설명하기 위해 구성한 코드이며, 특정 서비스의 운영 수치가 아니다.

## 상신 버튼 한 번이 만드는 요청과 응답

화면은 다음 요청을 보낸다.

```http
POST /api/approvals HTTP/1.1
Host: groupware.example.local
Content-Type: application/json

{"formCode":"EXPENSE","title":"10월 출장비 정산","approverIds":[2031,2045],"amount":182000}
```

서버가 문서를 만들었다면 응답은 이런 모양이 된다.

```http
HTTP/1.1 201 Created
Location: https://groupware.example.local/api/approvals/9001
Content-Type: application/json

{"id":9001,"status":"PENDING","title":"10월 출장비 정산","currentApproverId":2031}
```

서버 안에서는 다음 순서로 처리된다.

1. Controller가 JSON을 요청 DTO로 받고 필수값을 검증한다.
2. Service가 트랜잭션 안에서 결재 문서와 결재선을 저장하고, 이때 문서 ID가 확정된다.
3. Service 메서드가 끝나면서 트랜잭션이 커밋된다.
4. Controller가 확정된 ID로 Location을 만들고, 같은 결과 객체로 응답 본문을 채운다.
5. 클라이언트는 Location으로 `GET`을 보내 같은 문서를 조회한다.

이 흐름에서 깨지기 쉬운 지점은 세 곳이다. ID가 확정되기 전에 Location을 만드는 경우, Location과 본문이 서로 다른 값을 쓰는 경우, Location이 실제 조회 경로와 다른 경우다. 셋 다 상태 코드만 확인하는 테스트로는 드러나지 않는다.

## 200, 201, 202 중 무엇을 돌려줄까

RFC 9110은 POST가 새 리소스를 만들었다면 201 Created와 그 리소스를 식별하는 Location을 보내라고 권고한다(SHOULD). 201은 요청 결과로 새 리소스가 하나 이상 만들어졌다는 뜻이고, Location이 있으면 그 값이 주된 생성 리소스를 가리킨다. 상신은 이전에 없던 결재 문서를 만들고 응답 시점에 바로 조회할 수 있으므로 201이 맞다.

같은 결재 시스템 안에서도 모든 POST가 201은 아니다.

| 상황 | 상태 코드 | Location이 가리키는 것 | 이 코드를 쓰지 말아야 할 때 |
|---|---|---|---|
| 상신: 결재 문서가 저장되어 바로 조회 가능 | 201 Created | 새 문서 `/api/approvals/{id}` | 문서가 아직 만들어지지 않았을 때 |
| 승인·반려: 기존 문서의 상태 변경 | 200 OK 또는 204 No Content | 없음 | 승인 이력을 독립 리소스로 새로 만들어 노출할 때 |
| 일괄 기안: 여러 건을 작업 큐에 접수 | 202 Accepted | 작업 상태 리소스 | 요청 안에서 문서 생성이 끝날 때 |

승인(`POST /api/approvals/9001/approve`)은 기존 문서의 상태를 바꾸는 요청이다. 새 리소스가 생기지 않으므로 바뀐 문서를 본문에 담아 200을 주거나 본문 없이 204를 준다. 승인 이력을 `/api/approvals/9001/histories/3`처럼 독립 리소스로 노출한다면 그때는 201이 자연스럽다. 상태 코드는 HTTP 메서드가 아니라 "요청 결과로 무엇이 생겼는가"로 정한다.

일괄 기안처럼 요청 안에서 처리가 끝나지 않으면 202를 쓴다. RFC 9110은 202를 처리가 아직 끝나지 않았고, 나중에 실제로 처리될지도 약속하지 않는 응답으로 정의한다. 이때 문서는 아직 없으므로 Location은 문서가 아니라 작업 상태를 조회하는 리소스를 가리켜야 한다. 처리가 끝나지 않았는데 201을 주면 클라이언트는 존재하지 않는 문서를 조회하게 된다.

## Location은 확정된 ID로, 본문과 같은 객체에서 만든다

```java
@RestController
@RequestMapping("/api/approvals")
public class ApprovalController {

    private final ApprovalService approvalService;

    public ApprovalController(ApprovalService approvalService) {
        this.approvalService = approvalService;
    }

    @PostMapping
    public ResponseEntity<ApprovalResponse> submit(@Valid @RequestBody SubmitApprovalRequest request) {
        ApprovalResponse created = approvalService.submit(request);      // 1. 저장과 커밋이 끝난 결과

        URI location = ServletUriComponentsBuilder.fromCurrentRequest()  // 2. 확정된 ID로 위치를 만든다
                .path("/{id}")
                .buildAndExpand(created.id())
                .toUri();

        return ResponseEntity.created(location).body(created);          // 3. 헤더와 본문이 같은 객체에서 나온다
    }

    @GetMapping("/{id}")
    public ApprovalResponse get(@PathVariable Long id) {
        return approvalService.get(id);
    }
}

public record SubmitApprovalRequest(
        @NotBlank String formCode,
        @NotBlank @Size(max = 200) String title,
        @NotEmpty List<Long> approverIds,
        @PositiveOrZero long amount) {
}

public record ApprovalResponse(Long id, String status, String title, Long currentApproverId) {
}
```

`ResponseEntity.created(location)`은 상태를 201로 정하고 Location 헤더를 넣은 빌더를 돌려준다. 순서가 핵심이다. `approvalService.submit`이 반환한 시점에는 Service의 `@Transactional`이 끝나 커밋까지 완료됐고, Controller는 그 결과 객체 하나에서 Location의 ID와 응답 본문을 모두 꺼낸다. 요청 DTO의 값이나 따로 조회한 값으로 Location을 만들면 본문과 헤더가 서로 다른 문서를 가리킬 수 있다.

ID가 정말 확정됐는지는 영속 계층 설정에 달려 있다. Tibero나 Oracle처럼 시퀀스로 ID를 만드는 MyBatis 매퍼라면 `selectKey`가 ID를 객체에 채워 줘야 한다.

```xml
<insert id="insertApproval" parameterType="ApprovalDocument">
    <selectKey keyProperty="id" resultType="long" order="BEFORE">
        SELECT SEQ_APPROVAL_DOC.NEXTVAL FROM DUAL
    </selectKey>
    INSERT INTO APPROVAL_DOC (ID, FORM_CODE, TITLE, DRAFTER_ID, AMOUNT, STATUS, CREATED_AT)
    VALUES (#{id}, #{formCode}, #{title}, #{drafterId}, #{amount}, 'PENDING', SYSDATE)
</insert>
```

```java
@Service
public class ApprovalService {

    private final ApprovalMapper approvalMapper;
    private final EmployeeContext employeeContext;   // 로그인 사용자 정보를 꺼내는 컴포넌트

    // 생성자 생략

    @Transactional
    public ApprovalResponse submit(SubmitApprovalRequest request) {
        ApprovalDocument document = ApprovalDocument.draft(employeeContext.currentId(), request);
        approvalMapper.insertApproval(document);   // selectKey가 document.id를 채운다
        approvalMapper.insertApprovalLines(document.getId(), request.approverIds());
        return new ApprovalResponse(document.getId(), "PENDING", document.getTitle(),
                request.approverIds().get(0));
    }
}
```

위 매퍼에서 `selectKey`만 빼면 `#{id}`가 null이라 INSERT가 PK 제약으로 실패한다. 더 찾기 어려운 경우는 `VALUES (SEQ_APPROVAL_DOC.NEXTVAL, ...)`처럼 SQL 안에서 시퀀스를 바로 쓰거나 트리거로 ID를 채우면서 `selectKey`를 두지 않은 매퍼다. 이때는 INSERT는 성공하지만 객체의 `id`는 null로 남고, 응답에는 `Location: .../api/approvals/null`이 나간다. 결재선 INSERT도 같은 null을 받으므로 대개 제약 조건 오류로 드러나지만, 결재선이 없는 단순 생성 API라면 201 응답이 그대로 나간다.

### Location을 만드는 방법 비교

`ServletUriComponentsBuilder.fromCurrentRequest()`는 현재 요청의 scheme, host, port, 경로, 쿼리 문자열을 가져온다. 여기에 `.path("/{id}")`를 붙이면 `/api/approvals` 뒤에 ID가 붙은 절대 URL이 된다. 편하지만 전제가 있다.

- 생성 경로와 조회 경로가 같은 컬렉션이어야 한다. `POST /api/approval-drafts/{draftId}/submit`처럼 다른 경로에서 문서를 만든다면 현재 경로를 재사용한 주소는 틀린다.
- 쿼리 문자열이 따라온다. `POST /api/approvals?notify=false`로 요청하면 Location이 `/api/approvals/9001?notify=false`가 된다. 쿼리를 받을 수 있는 API라면 쿼리를 빼는 `fromCurrentRequestUri()`를 쓴다.
- 프록시 뒤에서는 내부 주소가 나올 수 있다. Spring 5.1부터 이 클래스는 `Forwarded`, `X-Forwarded-*` 헤더를 직접 읽지 않는다. TLS를 앞단에서 끝내는 구성이라면 별도 설정 없이 `http://10.0.3.12:8080/...` 같은 Location이 나간다.

| 방식 | Location 예 | 쓰기 좋은 경우 | 피해야 할 때 |
|---|---|---|---|
| `fromCurrentRequest().path("/{id}")` | `https://groupware.example.local/api/approvals/9001` | 생성과 조회가 같은 컬렉션이고 프록시 헤더 처리가 정리된 경우 | 생성 경로가 조회 경로와 다르거나 쿼리를 받는 경우 |
| `fromCurrentRequestUri().path("/{id}")` | 위와 같음(쿼리 제외) | 쿼리 파라미터가 붙을 수 있는 생성 API | 생성 경로가 조회 경로와 다를 때 |
| 상대 경로 `UriComponentsBuilder.fromPath("/api/approvals/{id}")` | `/api/approvals/9001` | 프록시 구성과 무관하게 단순하게 가고 싶을 때 | 게이트웨이가 외부 경로 접두어를 바꿀 때 |

RFC 9110에 따르면 Location이 상대 참조이면 요청 대상 URI를 기준으로 해석하므로 상대 경로도 유효하다. 다만 게이트웨이가 외부에는 `/groupware/api/approvals`로 노출하고 애플리케이션은 `/api/approvals`로 받는 구성이라면, 상대 경로 `/api/approvals/9001`은 외부에서 틀린 주소가 된다. 조회 핸들러의 매핑에서 주소를 만들고 싶다면 `MvcUriComponentsBuilder.fromMethodName`도 선택지지만, 메서드 이름을 문자열로 다뤄야 한다.

프록시 뒤에서 절대 URL을 쓰기로 했다면 Spring Boot의 `server.forward-headers-strategy`로 전달 헤더 처리 방식을 정한다. `native`는 서블릿 컨테이너가, `framework`는 Spring의 `ForwardedHeaderFilter`가 처리한다.

```yaml
server:
  # 앞단 프록시가 X-Forwarded-* 헤더를 항상 덮어써 준다는 전제에서만 켠다
  forward-headers-strategy: framework
```

이 설정은 클라이언트가 보낸 전달 헤더를 믿는다는 뜻이기도 하다. 프록시가 해당 헤더를 지우거나 덮어쓰지 않으면 클라이언트가 임의의 host를 넣어 Location을 조작할 수 있으므로, 인프라 구성과 함께 결정한다.

## 중복 제출: 201은 아무것도 막아 주지 않는다

응답이 늦어 기안자가 상신 버튼을 두 번 누르면 POST 두 건이 도착한다. 서버는 둘 다 정상 처리해 9001과 9002 두 문서에 각각 201을 돌려준다. HTTP 관점에서는 잘못이 없다. POST는 멱등 메서드가 아니고, 201은 결과를 설명할 뿐 같은 요청이 다시 오는 것을 막지 않는다. 그 결과 첫 결재자는 같은 정산서를 두 번 받는다.

화면에서 버튼을 비활성화하면 사용자 실수는 줄지만 네트워크 재시도나 새로고침까지 막지는 못한다. 서버에서는 클라이언트가 상신 시도마다 고유한 값을 `Idempotency-Key` 같은 헤더로 보내고, 같은 키로 다시 오면 처음 만든 문서의 응답(같은 Location)을 돌려주는 방식을 쓸 수 있다. "임시 저장 문서 하나는 한 번만 상신된다" 같은 업무 규칙이 있다면 유니크 제약으로 막을 수도 있다. 두 요청이 거의 동시에 오면 "조회 후 없으면 저장"하는 코드는 둘 다 통과할 수 있으므로 최종 방어선은 데이터베이스 제약이어야 한다. 키 보관 기간이나 같은 키에 다른 본문이 온 경우의 처리는 별도 설계 주제라 여기서는 다루지 않는다.

## MockMvc로 상태·헤더·본문을 함께 고정하기

Controller 테스트의 책임은 HTTP 계약이다. 상태 코드, Location, 본문의 ID가 서로 맞는지와, 그 Location으로 실제 조회 핸들러에 도달하는지를 확인한다. 결재선 규칙이나 SQL은 Service 테스트와 통합 테스트의 몫이다.

```java
// static import: MockMvcRequestBuilders.*, MockMvcResultMatchers.*, MockMvcResultHandlers.print,
//                BDDMockito.given, Mockito.verify/never, ArgumentMatchers.any
@WebMvcTest(ApprovalController.class)
class ApprovalControllerTest {

    private static final String REQUEST_BODY = """
            {"formCode":"EXPENSE","title":"10월 출장비 정산","approverIds":[2031,2045],"amount":182000}
            """;

    @Autowired MockMvc mockMvc;
    @MockitoBean ApprovalService approvalService;

    @Test
    void 상신하면_201과_새_문서를_가리키는_Location을_돌려준다() throws Exception {
        given(approvalService.submit(any()))
                .willReturn(new ApprovalResponse(9001L, "PENDING", "10월 출장비 정산", 2031L));

        mockMvc.perform(post("/api/approvals")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(REQUEST_BODY))
                .andDo(print())
                .andExpectAll(
                        status().isCreated(),
                        header().string(HttpHeaders.LOCATION, "http://localhost/api/approvals/9001"),
                        jsonPath("$.id").value(9001),
                        jsonPath("$.status").value("PENDING"));
    }

    @Test
    void Location을_따라가면_같은_문서를_조회한다() throws Exception {
        ApprovalResponse created = new ApprovalResponse(9001L, "PENDING", "10월 출장비 정산", 2031L);
        given(approvalService.submit(any())).willReturn(created);
        given(approvalService.get(9001L)).willReturn(created);

        String location = mockMvc.perform(post("/api/approvals")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(REQUEST_BODY))
                .andExpect(status().isCreated())
                .andReturn().getResponse().getHeader(HttpHeaders.LOCATION);

        mockMvc.perform(get(URI.create(location)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(9001));
    }

    @Test
    void 결재선이_비어_있으면_400이고_Location도_없다() throws Exception {
        mockMvc.perform(post("/api/approvals")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("""
                                {"formCode":"EXPENSE","title":"10월 출장비 정산","approverIds":[],"amount":182000}
                                """))
                .andExpect(status().isBadRequest())
                .andExpect(header().doesNotExist(HttpHeaders.LOCATION));

        verify(approvalService, never()).submit(any());
    }
}
```

첫 테스트는 `andExpectAll`로 네 가지를 한 번에 확인한다. `andExpect`를 이어 쓰면 첫 실패에서 멈추지만, `andExpectAll`은 모든 기대값을 검사하고 실패를 함께 보고한다. 상태 코드와 Location이 동시에 틀렸을 때 한 번의 실행으로 둘 다 보인다.

두 번째 테스트는 Location을 문자열로 비교하는 데서 끝나지 않고 그 주소로 실제 `GET`을 보낸다. Location의 경로와 `@GetMapping`이 어긋나면 404가 나므로, "본문과 Location이 같은 리소스를 가리킨다"는 약속을 끝까지 확인할 수 있다.

세 번째 테스트는 실패한 요청에 Location이 붙지 않고 Service도 호출되지 않는다는 점을 고정한다. 예제의 `@MockitoBean`은 Spring Boot 3.4(Spring Framework 6.2) 이상 기준이며, 그보다 낮은 버전에서는 `@MockBean`을 쓴다.

## 테스트가 실패할 때 흔히 보는 메시지

가장 흔한 실패는 기대값을 상대 경로로 적은 경우다.

```text
java.lang.AssertionError: Response header 'Location' expected:</api/approvals/9001> but was:<http://localhost/api/approvals/9001>
```

`fromCurrentRequest()`는 요청의 scheme과 host로 절대 URL을 만든다. MockMvc의 모의 요청은 기본값이 `http://localhost`이고 포트가 80이라 포트 표기 없이 `http://localhost/...`가 된다. 해결책은 두 가지다. 절대 URL 전체를 기대값으로 적어 계약을 그대로 문서화하거나, 호스트가 환경마다 달라 경로만 중요하다면 Hamcrest의 `endsWith("/api/approvals/9001")`를 `header().string`에 넘긴다. 테스트를 통과시키려고 운영 코드를 상대 경로로 바꾸는 것은 순서가 거꾸로다. 어떤 Location을 줄지 먼저 정하고 테스트를 그에 맞춘다.

그 밖에 자주 만나는 경우는 다음과 같다.

- `expected:<201> but was:<200>`: Controller가 `ResponseEntity.created` 대신 DTO를 바로 반환하고 있다. `@ResponseStatus(HttpStatus.CREATED)`로 바꾸면 201은 되지만 Location은 여전히 없다.
- Location이 `.../api/approvals/null`: 테스트 픽스처가 ID 없는 응답을 돌려주거나, 실제 코드에서 `selectKey` 같은 ID 채우기 설정이 빠졌다.
- 단언 실패가 아니라 `NullPointerException`을 감싼 예외로 테스트가 끝난다: `given(...)`의 인자 조건이 실제 호출과 맞지 않아 mock이 null을 돌려준 것이다. stub 조건부터 확인한다.
- 테스트는 통과하는데 운영 Location이 다르다: `server.servlet.context-path`나 프록시가 경로와 host를 바꾸는 구성이다. MockMvc는 기본적으로 context path 없이 요청을 만들기 때문에 이 차이를 잡지 못한다.

## 어떻게 확인하나

먼저 테스트를 실행하고 `print()` 출력에서 응답 부분을 본다.

```bash
./gradlew test --tests "*ApprovalControllerTest"
```

```text
MockHttpServletResponse:
           Status = 201
    Error message = null
          Headers = [Location:"http://localhost/api/approvals/9001", Content-Type:"application/json"]
     Content type = application/json
             Body = {"id":9001,"status":"PENDING","title":"10월 출장비 정산","currentApproverId":2031}
```

다음으로 로컬 서버에 실제 요청을 보내고, 응답의 Location을 그대로 조회한다.

```bash
curl -i -X POST http://localhost:8080/api/approvals \
  -H 'Content-Type: application/json' \
  -d '{"formCode":"EXPENSE","title":"10월 출장비 정산","approverIds":[2031,2045],"amount":182000}'

# 응답 헤더의 Location 값을 복사해 같은 문서가 나오는지 본다
curl -i http://localhost:8080/api/approvals/9001
```

개발 서버처럼 프록시나 게이트웨이 뒤에 배포된 환경에서는 같은 요청을 외부 주소로 보내 Location의 scheme, host, 경로 접두어가 외부 주소와 같은지 확인한다. 내부 IP나 `http`가 보이면 전달 헤더 설정을 확인한다.

실패했을 때 처음 볼 것은 단언 메시지의 기대값과 실제값이다. Location이 아예 없으면 `ResponseEntity.created`를 쓰는지 보고, 400이면 `print()`의 본문에서 어떤 필드 검증이 실패했는지 본다. Location을 따라간 조회가 404라면 Location 경로와 `@GetMapping` 경로를 나란히 놓고 비교한다.

## 정리

- 요청 결과로 새 리소스가 생겨 바로 조회할 수 있을 때만 201을 쓴다. 기존 문서 상태 변경은 200이나 204, 처리가 끝나지 않은 접수는 202다.
- Location과 응답 본문은 Service가 돌려준 같은 결과 객체에서 만들고, ID가 실제로 채워지는지 영속 계층 설정까지 확인한다.
- `fromCurrentRequest()`는 쿼리 문자열과 요청 host를 그대로 쓴다. 쿼리가 붙을 수 있으면 `fromCurrentRequestUri()`를, 프록시 뒤라면 전달 헤더 설정을 함께 정한다.
- 201은 중복 제출을 막지 않는다. 멱등 키나 데이터베이스 제약 같은 별도 장치가 필요하다.
- MockMvc 테스트에서는 상태, Location, 본문 ID를 `andExpectAll`로 함께 검증하고, Location을 따라가 같은 문서가 조회되는지도 확인한다.
- Location 기대값은 절대 URL인지 상대 경로인지 계약을 먼저 정한 뒤 적는다.

## 참고한 공식 문서

- [RFC 9110 - 15.3.2. 201 Created](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.3.2)
- [RFC 9110 - 10.2.2. Location](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.2)
- [Spring Framework Javadoc - ServletUriComponentsBuilder](https://docs.spring.io/spring-framework/docs/current/javadoc-api/org/springframework/web/servlet/support/ServletUriComponentsBuilder.html)
- [Spring Framework Reference - MockMvc Defining Expectations](https://docs.spring.io/spring-framework/reference/testing/mockmvc/hamcrest/expectations.html)
- [Spring Boot Reference - Running Behind a Front-end Proxy Server](https://docs.spring.io/spring-boot/how-to/webserver.html#howto.webserver.use-behind-a-proxy-server)
