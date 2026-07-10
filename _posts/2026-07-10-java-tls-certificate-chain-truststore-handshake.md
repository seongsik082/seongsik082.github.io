---
title: "TLS 인증서 체인을 바꿨더니 Java 클라이언트만 handshake에 실패하는 이유"
date: 2026-07-10 09:57:00 +0900
tags: [Security, Java, Backend]
excerpt: "TLS 인증서 교체 장애는 만료일만의 문제가 아닙니다. Java 클라이언트는 truststore, 인증서 체인, hostname 검증, 비활성화된 알고리즘 정책의 영향을 받으므로 서버 인증서 교체 전에 실제 클라이언트 런타임 기준으로 검증해야 합니다."
---

## 문제 상황

인증서 만료일이 다가와서 서버 인증서를 교체했다. 브라우저에서는 정상이다. `curl`도 문제없다. 그런데 Java로 만든 내부 배치나 Spring 애플리케이션만 외부 API 호출에 실패한다. 로그에는 `SSLHandshakeException`, `PKIX path building failed`, `unable to find valid certification path` 같은 메시지가 보인다.

이 장애는 "인증서가 틀렸다"로만 보면 오래 걸린다. 같은 서버라도 클라이언트 런타임마다 신뢰하는 root CA 목록, 중간 인증서 처리, hostname 검증 방식, 비활성화된 알고리즘 정책이 다를 수 있다. 브라우저가 성공했다고 Java 11, Java 17, Java 21 애플리케이션이 모두 성공한다는 보장은 없다.

TLS 인증서 교체는 서버 파일 하나를 바꾸는 작업이 아니라, 클라이언트가 서버 신원을 검증할 수 있는 경로를 유지하는 작업이다. 특히 사내 CA, 오래된 JDK, 별도 truststore를 쓰는 서비스에서는 배포 전 확인이 필수다.

## 핵심 개념

TLS handshake에서 서버는 자신의 인증서와 필요한 중간 인증서를 클라이언트에게 보낸다. 클라이언트는 이 인증서 체인을 자신이 신뢰하는 trust anchor, 보통 root CA까지 검증한다. Oracle JSSE 문서는 Java의 `TrustManager`가 제시된 인증 정보를 신뢰할지 결정하며, 신뢰할 수 없으면 연결이 종료된다고 설명한다.

Java 애플리케이션에서 기본 truststore는 실행 환경에 따라 결정된다. `javax.net.ssl.trustStore` 시스템 속성이 있으면 그 파일을 사용한다. 지정하지 않으면 `<java-home>/lib/security/jssecacerts`를 먼저 찾고, 없으면 `<java-home>/lib/security/cacerts`를 찾는다. 컨테이너 이미지나 사내 런타임에서 별도 JDK를 쓰면 브라우저와 전혀 다른 truststore를 볼 수 있다.

또 하나는 hostname 검증이다. 인증서 체인을 신뢰해도, 접속한 hostname이 인증서의 Subject Alternative Name과 맞지 않으면 HTTPS 클라이언트는 거부해야 한다. Oracle JSSE 문서도 raw `SSLSocket`이나 `SSLEngine`을 사용할 때 peer credentials를 확인해야 하며, URL의 host name이 인증서의 신원과 맞아야 한다고 설명한다.

## 예시로 보기

장애 상황은 다음처럼 단순하게 재현할 수 있다.

```bash
java \
  -Djavax.net.debug=ssl,handshake,trustmanager \
  -jar batch-client.jar
```

로그에서 먼저 볼 것은 truststore다.

```text
trustStore is: /opt/java/openjdk/lib/security/cacerts
trustStore type is: pkcs12
Reload trust certs
```

운영자가 사내 CA를 macOS Keychain이나 브라우저에는 넣었지만, 컨테이너 안 JDK의 `cacerts`에는 넣지 않았다면 Java 애플리케이션은 그 CA를 모른다. 이때 서버 인증서가 정상이어도 Java는 신뢰 경로를 만들 수 없다.

두 번째로 볼 것은 서버가 보낸 certificate chain이다.

```text
Consuming server Certificate handshake message
certificate_list: [
  leaf certificate: api.example.internal
  intermediate certificate: Example Issuing CA
]
```

서버가 leaf 인증서만 보내고 중간 인증서를 빠뜨리면 일부 클라이언트는 보완해서 찾을 수 있지만, 모든 Java 런타임이 항상 같은 방식으로 성공한다고 기대하면 안 된다. 서버는 클라이언트가 신뢰 anchor까지 검증할 수 있도록 필요한 중간 인증서를 함께 제공해야 한다.

세 번째는 hostname이다.

```text
javax.net.ssl.SSLHandshakeException:
No subject alternative DNS name matching api.example.com found
```

이 경우 truststore에 CA를 추가해도 해결되지 않는다. 클라이언트가 접속한 hostname과 인증서 SAN이 다르다. 로드밸런서 앞에서 DNS를 바꾸거나, 내부용 hostname으로 외부 인증서를 재사용할 때 자주 생긴다.

## 자주 하는 실수

첫 번째 실수는 만료일만 확인하는 것이다. 인증서가 아직 유효해도 issuer가 바뀌었거나, 중간 인증서가 누락되었거나, key algorithm이 현재 JDK 보안 정책에서 막혀 있으면 handshake는 실패할 수 있다. JSSE에는 `jdk.certpath.disabledAlgorithms` 같은 보안 속성이 있고, 인증서 경로 검증 중 금지된 알고리즘 조건을 적용할 수 있다.

두 번째 실수는 `curl` 성공을 Java 성공으로 해석하는 것이다. `curl`은 OS CA 저장소나 빌드 옵션에 따라 다른 신뢰 저장소를 사용한다. Java는 JSSE와 JDK truststore를 기준으로 움직인다. 운영 검증은 실제 애플리케이션이 쓰는 JDK 이미지, 같은 시스템 속성, 같은 네트워크 경로에서 해야 한다.

세 번째 실수는 문제를 빨리 해결하려고 hostname 검증을 끄는 것이다.

```java
// 장애 대응용으로도 남기면 안 되는 패턴
HttpsURLConnection.setDefaultHostnameVerifier((host, session) -> true);
```

이 코드는 중간자 공격을 막는 중요한 검증을 제거한다. 내부망이라고 안전한 것도 아니다. 잘못된 DNS, 프록시, 테스트 인증서가 운영으로 섞였을 때 클라이언트가 알아채지 못한다.

네 번째 실수는 truststore를 이미지 안에 복사해 놓고 갱신 절차를 잊는 것이다. 사내 CA가 교체되거나 root가 만료되면 모든 서비스 이미지를 다시 빌드해야 할 수 있다. 인증서 교체 절차에는 서버 인증서뿐 아니라 클라이언트 truststore 배포 계획도 포함되어야 한다.

## 적용 기준과 피해야 할 상황

서버 인증서를 교체하기 전에는 세 가지 기준을 통과해야 한다.

- 실제 운영 JDK 버전과 컨테이너 이미지에서 handshake가 성공한다.
- 서버가 leaf와 필요한 intermediate certificate를 올바른 순서로 제공한다.
- 접속 hostname이 인증서 SAN에 포함되어 있고, 우회 verifier가 없다.

사내 CA를 쓰는 경우에는 별도 truststore를 명시하는 편이 운영상 더 예측 가능할 수 있다.

```bash
java \
  -Djavax.net.ssl.trustStore=/etc/service/truststore.p12 \
  -Djavax.net.ssl.trustStorePassword=changeit \
  -Djavax.net.ssl.trustStoreType=PKCS12 \
  -jar app.jar
```

다만 이 방식은 truststore 갱신 책임을 애플리케이션 운영팀이 직접 갖는다는 뜻이다. root CA 변경, 중간 인증서 변경, 만료일 알림을 플랫폼 차원에서 관리하지 않으면 시간이 지나 장애가 된다.

피해야 할 선택도 분명하다. hostname 검증 비활성화, 모든 인증서를 신뢰하는 custom TrustManager, 만료된 root CA를 임시로 계속 추가하는 방식은 장애를 줄이는 것이 아니라 보안 검증을 제거하는 것이다. 테스트 환경에서만 쓰던 코드가 공통 HTTP client bean에 들어가면 운영 전체가 영향을 받는다.

## 운영에서 볼 것

장애가 나면 먼저 예외 메시지를 분류한다.

- `PKIX path building failed`: 신뢰 경로를 만들지 못했다. truststore와 certificate chain을 본다.
- `No subject alternative DNS name`: hostname 검증 실패다. 접속 hostname과 SAN을 본다.
- `handshake_failure`: cipher suite, TLS version, client/server 인증서, 알고리즘 정책까지 넓게 본다.
- `certificate expired`: leaf뿐 아니라 intermediate와 root 만료일도 확인한다.

그 다음 실제 런타임에서 디버그 로그를 짧게 켠다. `javax.net.debug=ssl,handshake,trustmanager`는 로그가 많으므로 평상시 상시 활성화하기보다 재현 환경이나 제한된 canary에서 사용한다. 로그에는 truststore 위치, 읽은 인증서, handshake 중 받은 certificate message가 나온다.

모니터링에는 인증서 만료일만 넣지 말고, synthetic check를 넣는 것이 좋다. 실제 Java runtime으로 대상 endpoint에 접속해 handshake와 hostname 검증을 수행하는 작은 점검이 가장 확실하다. 브라우저 기반 점검만 있으면 Java truststore 차이를 놓칠 수 있다.

## 정리

Java TLS 장애는 서버 인증서 파일 하나의 문제가 아닐 때가 많다. truststore, certificate chain, hostname 검증, JDK 보안 정책이 함께 맞아야 handshake가 성공한다.

인증서 교체 전에는 실제 Java 런타임으로 검증하고, 서버가 중간 인증서를 제대로 제공하는지 확인해야 한다. 장애 대응으로 검증을 끄는 코드는 장기적으로 더 큰 보안 사고를 만든다.

참고한 공식 문서:

- [Oracle Java SE 21 JSSE Reference Guide](https://docs.oracle.com/en/java/javase/21/security/java-secure-socket-extension-jsse-reference-guide.html)
- [RFC 8446: The Transport Layer Security Protocol Version 1.3](https://www.rfc-editor.org/rfc/rfc8446)
- [RFC 5280: Internet X.509 Public Key Infrastructure Certificate and CRL Profile](https://www.rfc-editor.org/rfc/rfc5280)
