---
title: "AWS IAM 최소 권한은 Action을 줄이는 일보다 평가 순서를 이해하는 일이 먼저인 이유"
date: 2026-07-06 08:57:00 +0900
tags: [AWS, Security, Backend]
excerpt: "IAM 최소 권한은 단순히 Action 목록을 적게 쓰는 작업이 아닙니다. identity policy, resource policy, permissions boundary, SCP가 어떻게 합쳐지고 explicit deny가 어떻게 우선하는지 이해해야 실제 권한을 예측할 수 있습니다."
---

운영자가 "이 Lambda는 S3 객체 하나만 읽으면 된다"고 생각하고 IAM policy를 좁혔는데도 배포 후 `AccessDenied`가 난다. 반대로 권한이 부족할까 봐 `s3:*`를 붙여두면 당장은 장애가 사라지지만, 몇 달 뒤 같은 role이 다른 코드에서도 재사용되며 위험한 권한이 퍼진다. IAM은 작은 JSON 몇 줄처럼 보이지만 실제 운영에서는 장애와 보안 사고가 같은 지점에서 시작된다.

최소 권한은 "권한을 조금만 준다"는 구호가 아니다. 어떤 주체가 어떤 리소스에 어떤 조건에서 접근해야 하는지 설명할 수 있어야 한다. 더 중요한 것은 여러 정책 타입이 함께 평가될 때 최종 권한이 어떻게 결정되는지 이해하는 것이다.

특히 AWS Organizations를 쓰거나, S3 bucket policy 같은 resource-based policy를 함께 쓰거나, permissions boundary로 개발팀 권한을 제한하는 환경에서는 identity policy 하나만 봐서는 실제 권한을 알 수 없다. 코드 리뷰에서 `Action` 목록만 줄였다고 안전해지는 것이 아니다.

## 문제 상황

예를 들어 배치 애플리케이션이 특정 S3 prefix의 파일을 읽고 처리 결과를 다른 prefix에 쓰는 구조라고 하자. 급한 배포에서는 다음처럼 넓은 권한을 붙이기 쉽다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "s3:*",
      "Resource": "*"
    }
  ]
}
```

이 정책은 문제를 빨리 덮는다. 하지만 이 role을 가진 코드가 실수로 다른 bucket을 지우거나, 침해된 credential이 계정 안의 여러 S3 리소스를 훑을 수 있다. 장애 대응 속도를 위해 붙인 권한이 나중에는 사고 반경을 키우는 셈이다.

반대로 너무 좁게 줄인 정책도 운영 장애를 만든다. 객체를 읽으려면 `s3:GetObject`만 있으면 될 것 같지만, 애플리케이션이 prefix 목록을 조회하면 `s3:ListBucket`도 필요하다. 이때 `ListBucket`은 bucket ARN에, `GetObject`는 object ARN에 붙어야 한다. action과 resource의 단위가 다르다는 점을 놓치면 정책은 보기에는 맞지만 동작하지 않는다.

## 핵심 개념

IAM 권한 평가는 여러 정책을 단순히 한 파일처럼 합치는 과정이 아니다. 같은 계정의 identity-based policy와 resource-based policy는 허용 권한의 합집합처럼 작동하지만, explicit deny가 있으면 allow보다 우선한다. permissions boundary가 있으면 identity policy로 허용된 권한과 boundary가 허용한 권한의 교집합만 남는다. Organizations의 SCP나 RCP가 있으면 그 제한도 최종 권한에 영향을 준다.

이 구조 때문에 "내 policy에는 allow가 있는데 왜 안 되지?"라는 질문이 자주 나온다. 어딘가의 boundary나 SCP가 막고 있으면 identity policy만 고쳐도 해결되지 않는다. 반대로 resource policy가 넓게 열려 있으면 identity policy만 보고 안전하다고 판단하기 어렵다.

최소 권한 설계는 세 가지 질문으로 시작하는 편이 좋다. 첫째, 주체는 사람인가 워크로드인가. 둘째, 필요한 action은 읽기, 쓰기, 목록 조회, 태그 변경, 암호화 키 사용 중 무엇인가. 셋째, resource와 condition으로 범위를 어디까지 줄일 수 있는가.

## 정책 예시로 보기

S3 입력 prefix를 읽고 출력 prefix에만 쓰는 배치라면 action을 역할별로 나누는 편이 읽기 쉽다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListInputAndOutputPrefixes",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::example-data-bucket",
      "Condition": {
        "StringLike": {
          "s3:prefix": [
            "input/orders/*",
            "output/orders/*"
          ]
        }
      }
    },
    {
      "Sid": "ReadInputObjects",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::example-data-bucket/input/orders/*"
    },
    {
      "Sid": "WriteOutputObjects",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject"
      ],
      "Resource": "arn:aws:s3:::example-data-bucket/output/orders/*"
    }
  ]
}
```

이 예시는 모든 상황의 정답이 아니다. 암호화된 bucket이면 KMS key 사용 권한이 더 필요할 수 있고, 객체 태그나 ACL을 다루면 관련 action이 추가된다. 그래도 `s3:*`와 `Resource: "*"`에서 시작하는 것보다 리뷰할 기준이 명확하다. 어떤 prefix를 읽고 어떤 prefix에 쓰는지 정책 이름과 resource에서 드러난다.

또 하나의 기준은 condition을 권한 축소 도구로 쓰는 것이다. AWS 공식 문서도 MFA 여부 같은 조건으로 정책 적용을 제한하는 예시를 제공한다. 실무에서는 source VPC endpoint, principal tag, 요청 region, object tag 같은 조건을 검토할 수 있다. 다만 condition은 서비스별 지원 키가 다르므로 문서 확인 없이 복사하면 정책이 기대와 다르게 동작할 수 있다.

## 자주 하는 실수

첫 번째 실수는 managed policy를 붙인 뒤 잊어버리는 것이다. AWS 관리형 정책은 빠르게 시작하기에는 좋지만, 애플리케이션이 실제로 쓰는 권한보다 넓을 수 있다. 최소 권한으로 가려면 Access Analyzer나 CloudTrail 기반 활동을 참고해 사용하지 않는 권한을 줄여야 한다.

두 번째 실수는 role 재사용이다. "이미 S3 권한이 있는 role"을 여러 서비스가 같이 쓰면 나중에 어떤 코드가 어떤 권한을 필요로 하는지 알기 어렵다. 한 서비스 때문에 권한을 추가하면 같은 role을 쓰는 다른 서비스의 사고 반경도 함께 커진다.

세 번째 실수는 explicit deny를 장애 원인 후보에서 빼는 것이다. IAM에서는 allow가 있어도 explicit deny가 이긴다. bucket policy, SCP, permissions boundary, session policy 중 하나가 막고 있으면 애플리케이션 role policy만 보고는 원인을 찾을 수 없다.

네 번째 실수는 장기 access key를 워크로드에 넣는 것이다. AWS는 EC2나 Lambda 같은 compute 서비스에서 IAM role을 통해 임시 credential을 제공하고, SDK가 이를 사용할 수 있게 한다. 워크로드에는 가능한 한 role 기반 임시 credential을 쓰고, 장기 key 배포를 피해야 한다.

## 적용 기준과 피해야 할 상황

새 서비스는 처음부터 최소 권한으로 설계하는 것이 가장 쉽다. API 호출 목록, 대상 ARN, 필요한 condition을 배포 문서에 함께 남긴다. 배포가 막혀 임시로 넓은 권한을 열어야 한다면 만료일과 회수 작업을 이슈로 남기고, 같은 PR에서 영구 정책처럼 합치지 않는 편이 좋다.

기존 서비스는 한 번에 완벽히 줄이려고 하면 장애 가능성이 크다. 먼저 CloudTrail, Access Analyzer, 애플리케이션 로그로 실제 사용 action을 모은다. 그 다음 read-only 성격의 권한부터 줄이고, 쓰기나 삭제 권한은 스테이징에서 재현 테스트 후 줄인다. 특히 `Delete*`, `PutBucketPolicy`, `iam:PassRole`, `kms:*` 같은 권한은 사고 반경이 크므로 별도로 리뷰한다.

피해야 할 상황도 있다. 장애 중 원인을 모르는 상태에서 `AdministratorAccess`를 붙이고 그대로 두는 방식은 가장 위험하다. 일시 조치가 필요하면 시간 제한이 있는 break-glass role, 승인 기록, 사후 회수 절차가 있어야 한다.

## 운영에서 볼 것

IAM 운영에서는 `AccessDenied` 로그만 보면 늦다. CloudTrail에서 어떤 principal이 어떤 action을 어떤 resource에 호출하는지 주기적으로 본다. 사용하지 않는 권한, 사용하지 않는 access key, 오래된 role session 패턴을 찾는다.

권한 변경은 배포처럼 다뤄야 한다. policy diff, 적용 대상 role, 예상되는 허용/거부 시나리오를 리뷰한다. 가능하면 IAM Access Analyzer 정책 검증과 시뮬레이션을 통해 문법 오류와 과도한 권한을 먼저 잡는다.

장애 분석에서는 네 가지를 순서대로 확인한다. identity policy가 action과 resource를 허용하는지, resource policy가 별도 조건이나 deny를 두는지, permissions boundary가 교집합을 줄이지 않는지, SCP나 RCP가 조직 차원에서 막지 않는지 확인한다. 이 순서를 표준화하면 "정책에는 allow가 있는데 왜 안 되지"라는 시간을 줄일 수 있다.

## 정리

AWS IAM 최소 권한은 action 목록을 짧게 만드는 작업이 아니라 실제 평가 결과를 예측 가능하게 만드는 작업이다. identity policy, resource policy, boundary, SCP의 관계를 이해하고, explicit deny가 항상 우선한다는 점을 기준으로 디버깅해야 한다. 워크로드에는 임시 credential과 전용 role을 쓰고, 정책은 resource와 condition으로 좁히며, 변경 후에는 CloudTrail과 Access Analyzer로 계속 줄여가자.

참고한 공식 문서:

- [AWS IAM User Guide - Security best practices in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html)
- [AWS IAM User Guide - Policy evaluation logic](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_evaluation-logic.html)
- [AWS IAM User Guide - Policies and permissions](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies.html)
