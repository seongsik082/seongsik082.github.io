---
layout: default
title: Start Here
permalink: /start-here/
---

{% assign java_posts = site.posts | where_exp: "post", "post.tags contains 'Java'" %}
{% assign spring_posts = site.posts | where_exp: "post", "post.tags contains 'Spring' or post.tags contains 'JPA'" %}
{% assign api_posts = site.posts | where_exp: "post", "post.tags contains 'REST API' or post.tags contains 'API' or post.tags contains 'HTTP'" %}
{% assign database_posts = site.posts | where_exp: "post", "post.tags contains 'Database' or post.tags contains 'Transaction'" %}
{% assign ops_posts = site.posts | where_exp: "post", "post.tags contains 'Observability' or post.tags contains 'Kubernetes' or post.tags contains 'CI/CD' or post.tags contains 'AWS'" %}

<section class="page-title">
  <p class="eyebrow">Start Here</p>
  <h1>처음 방문했다면, 백엔드 주제별로 이런 순서로 읽어보세요.</h1>
  <p class="page-description">
    이 블로그는 시간순 기록보다, 주니어에서 미들 백엔드 개발자로 넘어갈 때 필요한
    판단 기준을 쌓는 방향으로 글을 정리하고 있습니다.
  </p>
</section>

<section class="start-steps">
  <article class="step-card">
    <p class="section-label">Step 01</p>
    <h2>요청과 응답부터 보기</h2>
    <p>API 설계, 상태 코드, 조건부 요청처럼 클라이언트와 서버의 약속이 어떻게 만들어지는지 먼저 이해하면 나머지 주제를 읽기 쉬워집니다.</p>
  </article>
  <article class="step-card">
    <p class="section-label">Step 02</p>
    <h2>데이터와 트랜잭션 보기</h2>
    <p>정합성, 인덱스, 락, 격리 수준은 실제 장애와 가장 자주 연결되는 영역이라 초반에 잡아두는 편이 좋습니다.</p>
  </article>
  <article class="step-card">
    <p class="section-label">Step 03</p>
    <h2>운영과 관측으로 확장하기</h2>
    <p>성능, 재시도, 관측성, 배포 같은 주제는 "돌아간다"를 넘어 "운영할 수 있다"로 넘어가는 구간입니다.</p>
  </article>
</section>

<section class="guide-grid">
  <article class="guide-card">
    <p class="section-label">Java</p>
    <h2>동시성과 비동기 처리</h2>
    <p>스레드, 공용 풀, 비동기 체인이 실제 응답 지연과 어떻게 연결되는지부터 읽어보는 것을 추천합니다.</p>
    <div class="mini-post-list">
      {% for post in java_posts limit: 3 %}
        <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      {% endfor %}
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Spring / JPA</p>
    <h2>서비스 계층과 쿼리 흐름</h2>
    <p>트랜잭션, 지연 로딩, N+1, 프레임워크 경계처럼 서비스 코드와 실제 DB 동작이 만나는 지점을 다룹니다.</p>
    <div class="mini-post-list">
      {% for post in spring_posts limit: 3 %}
        <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      {% endfor %}
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">REST API</p>
    <h2>설계와 충돌 방지</h2>
    <p>상태 코드, 멱등성, 조건부 요청, 중복 방지처럼 API를 운영 가능한 형태로 만드는 기준을 모았습니다.</p>
    <div class="mini-post-list">
      {% for post in api_posts limit: 4 %}
        <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      {% endfor %}
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Database</p>
    <h2>정합성과 성능</h2>
    <p>인덱스, 락, 격리 수준, 트랜잭션 규칙처럼 실무에서 자주 사고가 나는 데이터 영역을 먼저 읽어볼 수 있습니다.</p>
    <div class="mini-post-list">
      {% for post in database_posts limit: 4 %}
        <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      {% endfor %}
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Operations</p>
    <h2>관측성과 배포</h2>
    <p>서비스를 운영하면서 어떤 신호를 보고 어디서 병목과 장애를 찾는지에 초점을 맞춘 글들입니다.</p>
    <div class="mini-post-list">
      {% for post in ops_posts limit: 4 %}
        <a href="{{ post.url | relative_url }}">{{ post.title }}</a>
      {% endfor %}
    </div>
  </article>

  <article class="guide-card">
    <p class="section-label">Next</p>
    <h2>전체 글을 태그로 확장해서 보기</h2>
    <p>특정 영역을 더 깊게 보고 싶다면 전체 글 목록에서 태그와 검색으로 확장해보는 방식이 가장 빠릅니다.</p>
    <div class="hero-actions">
      <a href="{{ '/posts/' | relative_url }}">전체 글 목록</a>
      <a href="{{ '/projects/' | relative_url }}">프로젝트 방향</a>
    </div>
  </article>
</section>
