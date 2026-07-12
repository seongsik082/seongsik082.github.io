---
title: "GitHub Actions OIDC를 써도 AWS trust policy가 넓으면 배포 권한이 새는 이유"
date: 2026-07-12 08:52:00 +0900
tags: [CI/CD, Security, AWS, GitHub Actions, Backend]
excerpt: "GitHub Actions OIDC는 장기 AWS access key를 없애지만, 실제 배포 권한은 IAM role의 trust policy와 권한 정책이 결정합니다. aud와 sub를 저장소·브랜치 또는 보호된 environment에 맞춰 제한하지 않으면 다른 workflow도 같은 role을 assume할 수 있습니다."
---

## 문제 상황

GitHub Actions에 저장해 두던 AWS access key를 삭제하고 OIDC 기반 배포로 바꿨다. 이제 저장소에 장기 비밀값이 없으니 안전해졌다고 생각했는데, IAM role의 trust policy를 확인해 보니 `sub`에 저장소 전체를 뜻하는 넓은 패턴이 들어 있다. 결과적으로 배포 브랜치가 아닌 다른 브랜치의 workflow도 같은 role을 요청할 수 있다.

OIDC는 비밀값을 없애는 기술이지, 자동으로 최소 권한을 만들어 주는 기술은 아니다. GitHub는 workflow 실행을 나타내는 짧은 수명의 JWT를 발급하고, AWS STS는 그 token이 trust policy 조건을 만족할 때만 role의 임시 자격 증명을 돌려준다. 누가 role을 맡을 수 있는지와 role을 맡은 뒤 무엇을 할 수 있는지는 별도의 정책이다.

따라서 OIDC 도입의 핵심은 “access key가 없어졌다”가 아니라 “이 role을 어떤 저장소의 어떤 실행만 assume할 수 있는가”를 정확히 표현하는 것이다.

## 핵심 개념

GitHub Actions job이 OIDC token을 요청하려면 다음 permission이 필요하다.

```yaml
permissions:
  contents: read
  id-token: write
```

`id-token: write`는 GitHub OIDC provider에서 token을 가져올 수 있게 하는 권한일 뿐, AWS 리소스에 쓰기 권한을 부여하지 않는다. 실제 AWS 접근은 token을 검증한 뒤 STS의 `AssumeRoleWithWebIdentity`가 반환한 임시 credentials와, 해당 IAM role에 연결된 permission policy로 결정된다.

AWS trust policy에서는 최소한 issuer, audience(`aud`), subject(`sub`)를 확인하는 조건을 둔다. `aud`는 이 token이 AWS STS를 대상으로 발급되었는지 확인하고, `sub`는 어떤 저장소와 ref 또는 environment에서 실행되었는지 구분하는 데 사용한다.

## workflow로 보기

main 브랜치에 push된 workflow만 배포 role을 사용하게 하려면 workflow trigger와 IAM trust policy를 함께 맞춘다.

```yaml
name: deploy

on:
  push:
    branches: [main]

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: arn:aws:iam::123456789012:role/github-actions-deploy
          aws-region: ap-northeast-2

      - name: Deploy
        run: ./scripts/deploy.sh
```

위 workflow가 사용하는 role의 trust policy는 다음처럼 저장소와 main ref를 명시할 수 있다.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
          "token.actions.githubusercontent.com:sub": "repo:seongsik082/seongsik082.github.io:ref:refs/heads/main"
        }
      }
    }
  ]
}
```

여기서 `Principal`은 GitHub OIDC provider를 가리키고, `Condition`이 실제 범위를 좁힌다. `sub`에 `repo:*`나 저장소만 넣으면 해당 저장소의 여러 branch와 workflow가 같은 role을 요청할 가능성이 생긴다. 배포 role이라면 운영 배포 ref를 직접 표현하는 편이 안전하다.

environment를 사용한다면 subject 형식이 달라진다. 예를 들어 `production` environment를 job에 지정했다면 조건은 다음과 같이 environment 이름을 기준으로 맞춰야 한다.

```json
"token.actions.githubusercontent.com:sub":
  "repo:seongsik082/seongsik082.github.io:environment:production"
```

이 경우에는 GitHub environment의 required reviewers와 branch/tag deployment rule도 함께 설정해야 한다. trust policy만 바꾸고 environment 보호 규칙을 비워 두면 승인 절차라는 운영 의도가 실제로 강제되지 않는다.

## 자주 하는 실수

첫 번째 실수는 `id-token: write`를 AWS 쓰기 권한으로 오해하는 것이다. token 발급 permission과 AWS IAM permission은 다른 경계다. workflow에는 필요한 `contents`, `packages` 같은 permission만 최소로 두고, AWS role의 permission policy도 배포에 필요한 S3·CloudFront·ECS 작업만 resource 범위와 함께 제한해야 한다.

두 번째 실수는 trust policy에 `sub` 조건을 생략하거나 너무 넓은 wildcard를 쓰는 것이다. OIDC provider를 신뢰한다고 해서 모든 GitHub workflow를 신뢰하면 안 된다. 같은 조직의 다른 저장소나 feature branch가 운영 role을 사용할 수 있는지 반드시 확인한다.

세 번째 실수는 branch trigger와 `sub` 값을 다르게 쓰는 것이다. workflow는 `main`만 실행하도록 했지만 trust policy가 `ref:refs/heads/release`를 가리키면 assume role이 실패한다. 반대로 workflow trigger를 넓혔는데 trust policy는 저장소 전체를 허용하면 보안 범위가 의도보다 커진다.

네 번째 실수는 environment를 붙인 뒤에도 branch 형식의 subject를 유지하는 것이다. environment job에서는 `sub`에 environment가 포함될 수 있으므로 GitHub 문서의 실제 claim 형식과 IAM 조건을 함께 확인해야 한다. 환경 이름을 바꾼 뒤 배포가 갑자기 실패하는 원인도 이 불일치일 수 있다.

다섯 번째 실수는 외부 action을 tag만 보고 무제한으로 사용하는 것이다. OIDC role을 얻은 뒤 실행되는 action과 script는 그 role의 권한을 사용할 수 있다. 공식 action을 선택하고, 중요한 workflow에서는 action을 검토된 commit SHA에 고정하며, pull request의 검증 코드가 운영 배포 자격 증명을 받을 수 없는 event 구조를 유지해야 한다.

여섯 번째 실수는 `sub` 형식이 항상 같다고 하드코딩하는 것이다. GitHub Docs는 2026년 7월 15일 이후 생성된 저장소나 immutable subject claim을 선택한 저장소에서 owner·repository ID가 포함된 형식을 사용할 수 있다고 안내한다. 저장소를 새로 만들거나 정책을 마이그레이션할 때는 문서의 예시를 복사하는 데서 끝내지 말고, 실제 workflow token의 claim 형식과 trust policy가 일치하는지 확인해야 한다.

## 언제 쓰면 좋은가

GitHub Actions가 AWS에 배포하거나 artifact·ECR·S3를 업로드하는 CI/CD라면 장기 access key 대신 OIDC federation을 우선 검토할 만하다. credentials를 GitHub Secrets에 오래 보관하지 않고, workflow 실행마다 짧은 수명의 role credentials를 받는 구조가 되기 때문이다.

다만 OIDC를 도입해도 IAM role의 permission policy는 그대로 최소 권한 원칙을 따라야 한다. 배포 대상이 하나의 S3 bucket이면 bucket 전체가 아니라 필요한 prefix와 작업만 허용한다. CloudFront invalidation이나 ECS service update처럼 필요한 API가 명확한 경우에도 resource 조건과 action 범위를 분리해 검토한다.

판단 기준은 “이 workflow가 탈취되더라도 role로 할 수 있는 일이 배포에 필요한 최소 범위인가”다. 이 질문에 답하려면 trust policy와 permission policy를 함께 읽어야 한다. OIDC는 첫 번째 정책의 주체를 정교하게 만드는 장치이고, 두 번째 정책의 과도한 권한을 자동으로 줄이지 않는다.

## 운영에서 볼 것

배포 장애나 의심스러운 접근이 생기면 먼저 CloudTrail에서 `AssumeRoleWithWebIdentity` 이벤트를 찾는다. 어떤 role이 요청되었는지, 어느 AWS account인지, 요청 시각과 source identity가 무엇인지 확인하고 해당 GitHub run과 대조한다. 정상 배포가 아닌 branch나 actor에서 role assume이 발생했다면 trust policy와 workflow trigger를 즉시 점검한다.

설정 변경 전에는 실제 token claim을 확인하는 디버깅 workflow를 제한된 저장소나 안전한 branch에서 실행할 수 있다. claim 전체를 무심코 로그에 남기지 말고, `sub`, `aud`, event, ref처럼 정책 판단에 필요한 값만 확인한다. AWS trust policy를 바꾼 뒤에는 성공 케이스뿐 아니라 feature branch, pull request, environment 없는 실행이 거절되는지도 테스트해야 한다.

대시보드와 감사 기록에는 workflow 이름, repository, ref 또는 environment, assume role 이름, 배포 대상, 실행자와 commit SHA를 연결해 남긴다. role 하나를 여러 저장소와 여러 환경이 공유하면 사고 범위를 파악하기 어렵다. 운영·스테이징 role과 AWS account를 분리하는 것이 비용보다 추적성과 차단 속도에서 유리한 경우가 많다.

## 정리

GitHub Actions OIDC는 장기 AWS access key를 없애지만, role을 누가 assume할 수 있는지는 IAM trust policy가 결정한다.
`id-token: write`는 token 요청 권한일 뿐이며, AWS 리소스 권한은 STS 임시 credentials와 IAM permission policy가 결정한다.
`aud`와 저장소·branch 또는 environment를 표현한 `sub`를 명시해 운영 배포 role의 범위를 좁혀야 한다.
CloudTrail의 `AssumeRoleWithWebIdentity`와 GitHub run 정보를 연결해 정상 workflow만 role을 사용했는지 계속 확인하자.

## 참고한 공식 문서

- [GitHub Docs - Configuring OpenID Connect in Amazon Web Services](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws)
- [GitHub Docs - OpenID Connect reference](https://docs.github.com/en/actions/reference/security/oidc)
- [AWS IAM - Request temporary security credentials](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_temp_request.html)
- [aws-actions/configure-aws-credentials](https://github.com/aws-actions/configure-aws-credentials)
