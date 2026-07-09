---
title: "S3 strong consistency를 믿어도 같은 key 동시 쓰기는 따로 막아야 하는 이유"
date: 2026-07-09 08:55:00 +0900
tags: [AWS, Distributed Systems, Backend]
excerpt: "Amazon S3는 객체 PUT, DELETE, GET, LIST에 strong read-after-write consistency를 제공하지만, 같은 key를 여러 writer가 동시에 갱신하는 순서 경쟁이나 여러 key를 한 번에 바꾸는 원자성까지 대신 해결해 주지는 않습니다."
---

## 문제 상황

이미지 변환 작업을 하는 서비스가 있다고 하자. 사용자가 프로필 이미지를 바꾸면 백엔드가 원본을 S3에 올리고, 별도 worker가 썸네일을 만들어 같은 prefix 아래에 저장한다. 운영자는 "S3는 strong consistency니까 업로드 직후 GET이나 LIST가 안 보이는 문제는 없겠지"라고 생각한다.

그런데 장애는 다른 곳에서 난다. 사용자가 짧은 시간 안에 이미지를 두 번 바꾸면 두 worker가 거의 동시에 같은 `users/42/profile.webp` key에 결과를 쓴다. 마지막으로 보낸 요청이 마지막으로 저장된다는 보장이 애플리케이션 의도와 정확히 같지 않을 수 있다. 네트워크 지연, worker 재시도, 큐 순서 때문에 오래된 작업이 늦게 끝나 새 결과를 덮어쓰는 일이 생긴다.

이 문제는 "S3가 아직 예전처럼 eventual consistency라서" 생기는 문제가 아니다. 단일 객체에 대한 읽기 일관성과 비즈니스 작업의 순서 보장은 다른 문제다. strong consistency는 성공한 쓰기 뒤의 읽기가 무엇을 보느냐를 설명하지만, 동시에 들어온 여러 쓰기 중 어떤 쓰기를 받아들일지까지 애플리케이션 대신 판단하지 않는다.

## 핵심 개념

Amazon S3는 모든 AWS Region에서 객체의 `PUT`, overwrite `PUT`, `DELETE` 요청에 대해 strong read-after-write consistency를 제공한다. 성공한 `PUT` 응답을 받은 뒤 시작한 `GET`이나 `LIST`는 방금 쓴 데이터를 볼 수 있다. 같은 key를 갱신할 때도 읽는 쪽은 부분적으로 깨진 데이터를 보지 않고, 이전 값 또는 새 값 중 하나를 본다.

하지만 S3 문서가 말하는 일관성 단위는 기본적으로 object key다. 한 key의 갱신은 원자적으로 보이지만, `metadata.json`과 `image.webp`처럼 여러 key를 함께 바꾸는 트랜잭션은 제공하지 않는다. 두 key 중 하나만 성공하고 다른 하나가 실패하면, 그 상태를 해석하고 보정하는 코드는 서비스가 가져야 한다.

또 하나의 경계는 concurrent writer다. 같은 key에 두 writer가 동시에 `PUT`하면 S3는 애플리케이션의 "요청 생성 시각"이나 "비즈니스 버전"을 기준으로 자동 정렬하지 않는다. 문서상 동시 쓰기에는 last-writer-wins 성격이 있으며, 최종 값을 정확히 알려면 두 쓰기가 모두 완료된 뒤 다시 읽어야 한다.

## 흐름으로 보기

다음 흐름은 S3 strong consistency를 만족하면서도 사용자 입장에서는 잘못된 결과가 되는 예다.

```text
09:00:00  사용자가 profile-v2.png 업로드
09:00:01  worker A가 v2 썸네일 생성 시작
09:00:03  사용자가 profile-v3.png 업로드
09:00:04  worker B가 v3 썸네일 생성 시작
09:00:05  worker B가 users/42/profile.webp 저장
09:00:08  worker A가 늦게 끝나 users/42/profile.webp 덮어쓰기
09:00:09  GET users/42/profile.webp -> v2 기반 썸네일
```

09:00:09의 `GET`은 S3 관점에서 일관적이다. 마지막으로 성공한 `PUT`이 worker A의 쓰기였기 때문이다. 문제는 worker A가 더 오래된 비즈니스 버전을 가지고 있었다는 점이다.

이럴 때는 object key를 고정된 "최종 위치"로만 쓰지 말고, 버전 key와 포인터 key를 나누는 방식이 더 안전하다.

```text
users/42/profile/20260709T090000-v2.webp
users/42/profile/20260709T090003-v3.webp
users/42/profile/current.json
```

worker는 결과 파일을 새 key에 쓰고, 마지막 단계에서 `current.json`에 현재 버전을 기록한다. 그래도 `current.json` 갱신은 경쟁할 수 있으므로, DB의 사용자 row에 `profile_version`을 두고 "현재 버전과 맞을 때만 갱신"하는 조건부 업데이트를 함께 쓰는 편이 안전하다.

```sql
UPDATE user_profile
SET current_image_key = :new_key,
    profile_version = :new_version
WHERE user_id = :user_id
  AND profile_version = :expected_previous_version;
```

업데이트된 row 수가 0이면 worker가 이미 오래된 것이다. 이 경우 S3 객체를 지우거나 lifecycle로 정리되게 두고, current 포인터는 바꾸지 않는다.

## 자주 하는 실수

첫 번째 실수는 LIST 결과를 작업 큐처럼 쓰는 것이다. S3의 LIST가 strong consistency를 제공하더라도, prefix 아래 파일을 훑어 "아직 처리 안 된 것"을 찾는 방식은 중복 처리와 순서 경쟁을 만들기 쉽다. 처리 상태, lease, 재시도 횟수는 DynamoDB, RDB, SQS 같은 상태 관리 도구에 두는 편이 운영하기 쉽다.

두 번째 실수는 여러 key를 하나의 논리 레코드처럼 다루는 것이다. 예를 들어 `order.json`, `payment.json`, `receipt.pdf`를 순서대로 쓰다가 중간에 실패하면 독자는 서로 다른 시점의 key 조합을 볼 수 있다. 여러 key를 묶어 일관되게 보여야 한다면 manifest key를 두고, 독자는 manifest가 가리키는 key만 읽도록 설계한다.

세 번째 실수는 overwrite를 수정 이력처럼 쓰는 것이다. 감사, 복구, 재처리가 중요한 데이터는 같은 key를 계속 덮어쓰는 것보다 불변 key를 만들고 최신 포인터를 따로 두는 편이 낫다. S3 Versioning도 도움이 되지만, 애플리케이션이 어떤 버전을 유효한 비즈니스 버전으로 볼지 결정해야 한다.

## 언제 쓰면 좋은가

S3 strong consistency는 업로드 직후 바로 다운로드하거나, 객체 생성 뒤 목록에 보이는지 확인해야 하는 일반적인 백엔드 흐름을 단순하게 만든다. 과거처럼 새 객체가 LIST에 늦게 보일 것을 가정해 별도 인덱스를 만들 필요가 줄어든다.

하지만 같은 key를 여러 worker가 갱신하거나, 여러 key를 하나의 변경처럼 보여야 하거나, 오래된 재시도가 새 결과를 덮으면 안 되는 경우에는 S3 일관성만으로 충분하지 않다. 판단 기준은 간단하다. "마지막 S3 PUT이 이기는 것"이 비즈니스 규칙과 같으면 S3만으로도 단순하게 갈 수 있다. 그렇지 않으면 버전, 조건부 DB 업데이트, idempotency key, manifest 같은 별도 규칙이 필요하다.

## 운영에서 볼 것

운영에서는 overwrite 횟수와 재시도 로그를 먼저 본다. 같은 key에 짧은 시간 동안 여러 `PUT`이 몰린다면 key 설계가 너무 넓거나 worker 재시도 정책이 결과를 덮어쓸 수 있다. S3 server access log나 CloudTrail data event를 켠 환경이라면 object key, event time, requester를 함께 추적한다.

애플리케이션 로그에는 비즈니스 버전을 반드시 남긴다.

```text
profile_thumbnail_write userId=42 jobId=a17 sourceVersion=3 targetKey=users/42/profile/3.webp
profile_pointer_skip userId=42 jobId=a16 sourceVersion=2 currentVersion=3 reason=stale_worker
```

이런 로그가 있어야 S3가 읽기 일관성을 어겼는지, 아니면 오래된 worker가 정상적으로 늦게 도착했는지 구분할 수 있다. 대부분의 실제 장애는 후자다.

운영 체크리스트는 세 단계로 잡으면 좋다. 첫째, 사용자가 같은 리소스를 짧은 시간에 여러 번 바꿀 수 있는 화면인지 확인한다. 프로필 이미지, 첨부 파일, 리포트 재생성처럼 사람이 반복 클릭할 수 있는 기능은 항상 후보가 된다. 둘째, worker가 처리하는 입력에 버전이 있는지 본다. 단순히 `userId`만 들고 작업하면 worker는 자신이 최신 요청을 처리하는지 알 방법이 없다. 셋째, 최종 반영을 DB 조건부 업데이트나 별도 포인터 갱신으로 한 번 더 검증하는지 확인한다. 이 세 가지가 없으면 S3가 아무리 일관적으로 읽혀도 오래된 결과가 정상적으로 마지막 결과가 될 수 있다.

장애 대응 때는 "S3에서 왜 예전 파일을 줬나"부터 의심하기보다 쓰기 순서를 재구성하는 편이 빠르다. 같은 key에 대한 `PUT` 시각, worker 시작 시각, 원본 요청 버전, 최종 포인터 갱신 시각을 나란히 놓으면 대부분의 원인이 보인다. 로그에 버전이 없으면 다음 배포에서 먼저 관측 가능성을 보강하고, 그 뒤에 key 설계를 바꾸는 순서가 안전하다.

## 정리

S3 strong consistency는 업로드 직후 읽기와 목록 조회를 훨씬 예측 가능하게 만든다.
하지만 같은 key 동시 쓰기, 여러 key 원자성, 비즈니스 버전 순서까지 대신 보장하지는 않는다.
최종 key를 직접 덮어쓰기 전에 버전 key, manifest, 조건부 DB 업데이트를 검토하자.
운영 로그에는 S3 key뿐 아니라 비즈니스 버전과 job id를 함께 남겨야 원인 분석이 가능하다.

## 참고한 공식 문서

- [Amazon S3 data consistency model](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)
