---
title: "Docker로 백엔드 실행 환경을 맞추는 이유"
date: 2026-06-28 21:20:00 +0900
tags: [Docker, Backend]
excerpt: "Docker는 애플리케이션을 어디서 실행하든 비슷한 환경으로 동작하게 만들어주는 도구입니다."
---

백엔드 프로젝트를 진행하다 보면 로컬에서는 잘 되는데 서버에서는 안 되는 상황을 자주 만납니다.
JDK 버전, 환경 변수, 의존성, 실행 경로, OS 차이처럼 작은 요소들이 실행 결과를 바꿀 수 있습니다.
Docker는 이런 차이를 줄이기 위해 사용합니다.

## Docker 이미지와 컨테이너

Docker에서 이미지는 실행에 필요한 파일과 설정을 묶어둔 템플릿입니다.
컨테이너는 그 이미지를 실제로 실행한 프로세스입니다.

간단히 말하면 이미지는 설계도, 컨테이너는 실행 중인 애플리케이션입니다.

```text
Dockerfile -> image -> container
```

백엔드 애플리케이션을 이미지로 만들면 로컬, 테스트 서버, 운영 서버에서 같은 방식으로 실행할 수 있습니다.

## Dockerfile의 역할

Dockerfile은 이미지를 만드는 방법을 적는 파일입니다.

```dockerfile
FROM eclipse-temurin:17
WORKDIR /app
COPY build/libs/app.jar app.jar
ENTRYPOINT ["java", "-jar", "app.jar"]
```

이 예시는 Java 17 환경에서 빌드된 jar 파일을 실행합니다.
중요한 점은 실행 환경을 코드처럼 기록한다는 것입니다.
누군가 새로 프로젝트를 실행하더라도 Dockerfile을 보면 어떤 환경이 필요한지 알 수 있습니다.

## docker compose

백엔드 서버는 혼자 실행되지 않는 경우가 많습니다.
DB, Redis, 메시지 큐 같은 외부 의존성이 함께 필요합니다.

이때 `docker compose`를 사용하면 여러 컨테이너를 한 번에 실행할 수 있습니다.

```yaml
services:
  app:
    image: backend-app
  mysql:
    image: mysql:8
  redis:
    image: redis:7
```

로컬 개발 환경을 맞출 때 특히 유용합니다.

## 주의할 점

Docker를 쓴다고 배포가 자동으로 좋아지는 것은 아닙니다.
이미지 크기, 환경 변수 관리, 로그 출력, 볼륨, 네트워크 설정을 함께 신경 써야 합니다.

백엔드 개발자는 최소한 다음을 이해하고 있으면 좋습니다.

- 이미지와 컨테이너의 차이
- Dockerfile 작성 흐름
- 포트 매핑
- 환경 변수 주입
- 컨테이너 로그 확인
- compose로 의존 서비스 실행

Docker는 배포 도구이기도 하지만, 팀의 개발 환경을 맞추는 문서이기도 합니다.
실행 방법을 코드로 남긴다는 점에서 백엔드 프로젝트의 재현성을 크게 높여줍니다.
