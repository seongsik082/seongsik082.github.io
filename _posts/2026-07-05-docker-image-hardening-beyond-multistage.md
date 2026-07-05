---
title: "멀티 스테이지만으로 끝내면 안 되는 Docker 이미지 하드닝 기준"
date: 2026-07-05 09:00:00 +0900
tags: [Docker, Security, Backend]
excerpt: "멀티 스테이지 빌드는 좋은 시작이지만, 그것만으로는 Docker 이미지가 안전해지지 않습니다. 신뢰할 수 있는 작은 base image, non-root 실행, secret 비노출, 재빌드 주기까지 함께 설계해야 실제 운영 리스크가 줄어듭니다."
---

## 문제 상황

팀에서 기존 Dockerfile을 멀티 스테이지로 바꾼 뒤 이미지 크기가 절반 가까이 줄었다고 가정해 보겠습니다. 빌드 시간도 짧아지고, 스캐너가 잡는 패키지 수 역시 줄어들어서 모두가 "이제 하드닝도 끝났다"고 느끼기 쉽습니다.

그런데 운영 사고는 다른 곳에서 터집니다. 컨테이너는 여전히 root로 실행되고, 빌드 중 사설 패키지 레지스트리 토큰을 `ENV`로 주입해 이미지 메타데이터나 레이어 히스토리에 흔적이 남습니다. base image는 몇 달째 다시 pull하지 않아 이미 패치가 나온 취약 라이브러리를 계속 품고 있을 수도 있습니다.

즉, 멀티 스테이지는 "빌드 도구를 최종 이미지에서 빼는 기술"이지 "공격 표면 전체를 자동으로 줄이는 기술"은 아닙니다. 실무 하드닝은 어떤 base를 믿을지, 런타임 프로세스를 어떤 권한으로 돌릴지, build secret을 어떻게 숨길지, 이미지를 얼마나 자주 다시 만들지까지 함께 봐야 합니다.

## 핵심 개념

Docker 공식 문서는 secure image의 첫 단계로 "신뢰할 수 있는 작은 base image"를 고르라고 설명합니다. Docker Official Images나 Verified Publisher 이미지처럼 출처가 분명하고, 필요 기능만 담은 작은 이미지를 선택하면 다운로드 속도뿐 아니라 취약점 노출 면적도 함께 줄어듭니다.

멀티 스테이지 빌드는 그 다음 단계입니다. Docker 문서가 설명하듯 여러 `FROM`을 두고 빌드 결과물만 최종 stage로 복사하면 컴파일러, 테스트 도구, 패키지 매니저 같은 불필요한 요소를 남기지 않을 수 있습니다. 하지만 여기서 끝내면 "작은 root 이미지"가 될 뿐입니다.

실행 사용자도 별도로 설계해야 합니다. Dockerfile reference는 `USER` 명령이 이후 `RUN`, `CMD`, `ENTRYPOINT`의 기본 사용자를 정한다고 설명합니다. 즉, 아무 설정이 없으면 런타임 프로세스는 root일 가능성이 높습니다. 애플리케이션 파일도 `COPY --chown`을 쓰지 않으면 기본적으로 UID/GID 0 소유로 들어오므로, non-root 전환을 뒤늦게 붙이다가 권한 오류를 만드는 경우가 흔합니다.

비밀값 처리 방식도 중요합니다. Docker 문서는 `RUN --mount=type=secret`을 사용하면 토큰이나 키를 이미지에 bake하지 않고 빌드 시점에만 접근할 수 있다고 안내합니다. 반대로 `ENV` 값은 최종 이미지에 남습니다. Dockerfile reference도 `ENV`로 설정한 값은 이미지에 persist된다고 명시합니다. 빌드 전용 값이라면 `ARG` 또는 secret mount가 더 적절합니다.

마지막으로 이미지는 immutable이지만 안전하지는 않습니다. Docker best practices 문서는 이미지를 자주 rebuild하고, `--pull`로 최신 base를 가져오며, 필요하면 `--no-cache`로 종속성을 다시 받아오라고 권장합니다. 태그를 pin하는 것은 재현성에 도움이 되지만, 재빌드 자체를 멈추면 보안 패치를 놓칠 수 있다는 trade-off도 같이 봐야 합니다.

## Dockerfile로 보기

아래 예시는 멀티 스테이지를 하되, non-root와 secret 처리까지 같이 넣은 형태입니다.

```dockerfile
# syntax=docker/dockerfile:1
FROM gradle:8.14.0-jdk21 AS builder
WORKDIR /workspace
COPY . .
RUN --mount=type=secret,id=gradle_properties,target=/root/.gradle/gradle.properties \
    gradle clean bootJar

FROM eclipse-temurin:21-jre
WORKDIR /app
RUN useradd -r -u 10001 spring
COPY --from=builder --chown=10001:10001 /workspace/build/libs/app.jar /app/app.jar
USER 10001:10001
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
```

이 Dockerfile이 주는 실무 포인트는 네 가지입니다.

- builder stage에는 빌드 도구가 있어도 final stage에는 남지 않습니다.
- secret은 `RUN --mount=type=secret`으로 주입되어 최종 이미지에 저장되지 않습니다.
- runtime image는 JRE만 남겨 공격 표면을 줄입니다.
- `USER`를 명시해 애플리케이션이 root로 실행되지 않도록 합니다.

여기서 더 나가면 `COPY --chown`으로 파일 소유권을 복사 시점에 맞추고, base image 선택도 서비스 특성에 맞게 더 작은 런타임으로 줄일 수 있습니다. 중요한 것은 "이미지가 작다"와 "권한이 최소화되었다"를 같은 말로 취급하지 않는 것입니다.

## 자주 하는 실수

첫 번째 실수는 멀티 스테이지만 적용하고 최종 stage를 root로 실행하는 것입니다. 이 경우 빌드 도구는 사라져도 런타임 탈출, 파일 권한 오용, 잘못된 마운트 조합에서 얻는 피해 범위는 여전히 큽니다.

두 번째 실수는 build secret을 `ENV`나 평문 파일 복사로 처리하는 것입니다. `.npmrc`, `settings.xml`, private key, cloud credential이 최종 이미지나 layer history에 남으면 이미지 공유만으로도 비밀이 새어 나갈 수 있습니다.

세 번째 실수는 편의상 디버깅 도구를 계속 포함하는 것입니다. Docker 문서가 말하듯 필요 없는 패키지는 설치하지 않는 편이 낫습니다. `curl`, `vim`, `net-tools` 몇 개쯤은 괜찮아 보여도 결국 이미지 크기, 종속성 수, 취약점 수를 함께 키웁니다.

네 번째 실수는 태그를 pin했으니 안전하다고 생각하고 재빌드 주기를 놓치는 것입니다. 태그 고정은 갑작스러운 변경을 막아 주지만, base image와 라이브러리의 보안 패치가 자동으로 따라오지는 않습니다. 재현성과 최신성은 같이 관리해야 합니다.

## 언제 쓰면 좋은가

외부에 노출되는 API 서버, 내부 업무 시스템, 배치 워커를 가리지 않고 대부분의 컨테이너 이미지는 이 기준을 기본값으로 보는 편이 좋습니다. 특히 CI/CD에서 이미지를 여러 환경으로 반복 배포한다면, 한 번 잘못 만들어진 root 이미지나 secret 노출 이미지는 문제를 빠르게 복제합니다.

반대로 로컬 실험용 이미지나 하루짜리 개발 컨테이너라면 모든 하드닝 단계를 엄격히 적용하지 않을 수도 있습니다. 하지만 운영 경로에 들어가는 순간에는 기준이 달라져야 합니다. "개발 편의용 예외"와 "배포용 기본값"을 섞지 않는 것이 중요합니다.

실무 한 줄 기준은 이것입니다. "이 이미지가 유출되거나 root로 실행되어도, 피해 범위가 우리가 예상한 최소 수준인가?" 여기에 답하려면 이미지 크기만이 아니라 권한, 비밀, 공급망 갱신 주기까지 같이 봐야 합니다.

## 운영에서 볼 것

- 최종 컨테이너가 UID 0으로 실행되고 있지 않은지
- 이미지 빌드 시 base image를 얼마나 오래된 캐시로 재사용하고 있는지
- secret scanner나 이미지 히스토리에서 민감 정보 흔적이 보이지 않는지
- 배포 이미지 크기와 설치 패키지 수가 불필요하게 늘어나지 않는지
- CI에서 주기적 rebuild와 취약점 스캔이 실제로 돌고 있는지

운영에서 중요한 것은 "빌드가 성공했는가"보다 "같은 Dockerfile이 몇 달 뒤에도 여전히 안전한 결과를 만들고 있는가"입니다. 이미지 하드닝은 한 번 끝내는 설정이 아니라 공급망과 런타임 권한을 지속적으로 좁히는 과정에 가깝습니다.

## 정리

멀티 스테이지 빌드는 Docker 이미지 하드닝의 출발점이지 종착점이 아닙니다. 신뢰할 수 있는 작은 base image, non-root 실행, `RUN --mount=type=secret` 기반의 비밀 처리, 재빌드 주기까지 함께 설계해야 실제 운영 리스크가 줄어듭니다. 이미지를 작게 만드는 것보다 더 중요한 것은 이미지가 어떤 권한과 어떤 흔적을 남긴 채 배포되는지 아는 것입니다.

## 참고한 공식 문서

- [Docker Docs: Building best practices](https://docs.docker.com/build/building/best-practices/)
- [Docker Docs: Multi-stage builds](https://docs.docker.com/build/building/multi-stage/)
- [Docker Docs: Dockerfile reference](https://docs.docker.com/reference/dockerfile/)
