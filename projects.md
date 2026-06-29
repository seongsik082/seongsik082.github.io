---
layout: default
title: Projects
permalink: /projects/
---

<section class="page-title">
  <p class="eyebrow">Projects</p>
  <h1>기능 구현보다 요청 흐름, 데이터, 운영 포인트를 설명할 수 있는 프로젝트를 지향합니다.</h1>
</section>

<section class="project-list">
  <article class="project-card">
    <div>
      <p class="section-label">Project Direction 01</p>
      <h2>사용자 요청과 데이터 흐름이 명확한 서비스형 프로젝트</h2>
      <p>
        단순 CRUD를 넘어서 인증, 게시글, 검색, 알림, 비동기 후처리처럼
        실제 서비스에서 흐름이 이어지는 프로젝트를 정리하려고 합니다.
        이 페이지에는 구현 자체보다 어떤 문제를 어떻게 나눠서 해결했는지를 담을 예정입니다.
      </p>
    </div>
    <dl>
      <dt>보고 싶은 역량</dt>
      <dd>API 설계, DB 모델링, 인증/인가, 예외 흐름, 배포 자동화</dd>
      <dt>주요 스택</dt>
      <dd>Java, Spring Boot, JPA, MySQL, Redis, Docker</dd>
      <dt>정리할 포인트</dt>
      <dd>트랜잭션 경계, 캐시 전략, 인덱스 선택, CI/CD 구성, 운영 로그</dd>
    </dl>
    <div class="link-row">
      <a href="https://github.com/seongsik082">GitHub</a>
    </div>
  </article>

  <article class="project-card">
    <div>
      <p class="section-label">Project Direction 02</p>
      <h2>트러블슈팅과 운영 관측이 드러나는 프로젝트</h2>
      <p>
        배치 처리, 외부 API 연동, 캐시, 대량 조회처럼
        장애 원인 분석과 운영 판단 기준을 설명할 수 있는 프로젝트를 우선적으로 남기려 합니다.
      </p>
    </div>
    <dl>
      <dt>보고 싶은 역량</dt>
      <dd>장애 재현, 병목 분석, 재시도 정책, 실패 데이터 추적, 운영 체크리스트</dd>
      <dt>주요 스택</dt>
      <dd>Spring Batch, PostgreSQL, Redis, Docker, GitHub Actions</dd>
      <dt>정리할 포인트</dt>
      <dd>재시도 정책, 작업 단위 분리, 메트릭 확인, 로그 추적, 롤백 기준</dd>
    </dl>
    <div class="link-row">
      <a href="https://github.com/seongsik082">GitHub</a>
    </div>
  </article>

  <article class="project-card">
    <div>
      <p class="section-label">How I Write Projects</p>
      <h2>프로젝트 글은 이런 순서로 정리합니다</h2>
      <p>
        프로젝트 소개보다 요청 흐름과 문제 해결 과정을 먼저 보여주는 편이
        백엔드 개발 블로그에 더 맞다고 생각합니다.
      </p>
    </div>
    <dl>
      <dt>1. 문제 정의</dt>
      <dd>무엇이 느렸는지, 꼬였는지, 운영에서 어떤 신호가 보였는지 적습니다.</dd>
      <dt>2. 구조 설명</dt>
      <dd>요청 흐름, DB 구조, 외부 연동 지점을 그림 없이도 이해되게 설명합니다.</dd>
      <dt>3. 해결 방식</dt>
      <dd>코드, SQL, 설정, 배포 전략 중 실제로 바꾼 지점을 남깁니다.</dd>
      <dt>4. 운영 기준</dt>
      <dd>무엇을 지표로 봤는지, 언제 롤백할지, 어떤 로그를 확인할지 정리합니다.</dd>
    </dl>
  </article>
</section>
