---
layout: default
title: Home
---

<section class="home-hero">
  <div class="home-hero-inner">
    <p class="eyebrow">Backend Developer Blog</p>
    <h1>Java, Spring, Database, 운영 이슈를 백엔드 개발자 관점에서 기록합니다.</h1>
    <p class="home-hero-summary">
      개념만 요약하는 블로그보다 실제 서비스에서 어떤 기준으로 선택하고,
      어디서 장애를 확인하고, 무엇을 먼저 의심해야 하는지 남기는 블로그를 지향합니다.
    </p>
    <div class="hero-actions">
      <a href="{{ '/posts/' | relative_url }}">최신 글 보기</a>
      <a href="{{ '/about/' | relative_url }}">운영 방식 보기</a>
    </div>
  </div>
</section>

<section class="profile-intro">
  <div>
    <p class="section-label">About</p>
    <h2>요청 흐름, 데이터 정합성, 운영 관측성을 함께 보는 백엔드 블로그입니다.</h2>
    <p>
      이 블로그는 기능 구현에서 끝나지 않고, 왜 그런 선택을 했는지와 운영에서 무엇을 봐야 하는지까지 함께 정리합니다.
      Java, Spring, API, Database, 캐시, 배포, 관측성처럼 백엔드 개발자가 자주 부딪히는 주제를 차분하게 쌓아갑니다.
    </p>
  </div>
</section>

<section class="home-stats">
  <article class="stat-card">
    <p class="section-label">현재 포스트</p>
    <strong>{{ site.posts | size }}</strong>
    <span>백엔드 학습과 운영 경험을 주제별로 정리 중입니다.</span>
  </article>
  <article class="stat-card">
    <p class="section-label">주요 주제</p>
    <strong>Java · Spring · API</strong>
    <span>트랜잭션, 비동기, OSIV, 조건부 요청 같은 실무 주제를 다룹니다.</span>
  </article>
  <article class="stat-card">
    <p class="section-label">글의 기준</p>
    <strong>문제 → 원리 → 적용 기준</strong>
    <span>정의만 나열하지 않고 어디에 적용할지까지 함께 적습니다.</span>
  </article>
</section>

<section class="home-topics">
  <a href="{{ '/posts/?tag=Java' | relative_url }}">Java</a>
  <a href="{{ '/posts/?tag=Spring' | relative_url }}">Spring</a>
  <a href="{{ '/posts/?tag=Database' | relative_url }}">Database</a>
  <a href="{{ '/posts/?tag=REST%20API' | relative_url }}">REST API</a>
  <a href="{{ '/posts/?tag=Distributed%20Systems' | relative_url }}">Distributed Systems</a>
  <a href="{{ '/posts/?tag=Observability' | relative_url }}">Observability</a>
  <a href="{{ '/posts/?tag=Kubernetes' | relative_url }}">Kubernetes</a>
  <a href="{{ '/posts/?tag=Performance' | relative_url }}">Performance</a>
</section>

<section class="home-section">
  <div class="section-kicker">읽기 가이드</div>
  <div class="section-head compact">
    <h2>관심 주제별로 시작해보세요</h2>
    <a class="text-link" href="{{ '/posts/' | relative_url }}">전체 글 보기</a>
  </div>

  <div class="reading-grid">
    <a class="reading-card" href="{{ '/posts/?tag=Java' | relative_url }}">
      <p class="section-label">Java</p>
      <h3>동시성, 스레드, 비동기</h3>
      <p>응답 지연, 공용 풀 경합, 실행 흐름처럼 애플리케이션 코드에서 바로 체감되는 문제를 중심으로 읽을 수 있습니다.</p>
    </a>
    <a class="reading-card" href="{{ '/posts/?tag=Spring' | relative_url }}">
      <p class="section-label">Spring / JPA</p>
      <h3>프레임워크 경계와 쿼리 흐름</h3>
      <p>트랜잭션, 지연 로딩, N+1, 서비스 계층 설계처럼 Spring 백엔드에서 자주 부딪히는 주제를 모았습니다.</p>
    </a>
    <a class="reading-card" href="{{ '/posts/?tag=REST%20API' | relative_url }}">
      <p class="section-label">REST API</p>
      <h3>상태 코드, 조건부 요청, 중복 방지</h3>
      <p>API를 동작하게 만드는 수준을 넘어, 충돌과 재시도까지 고려한 설계 기준을 정리합니다.</p>
    </a>
    <a class="reading-card" href="{{ '/posts/?tag=Database' | relative_url }}">
      <p class="section-label">Database</p>
      <h3>트랜잭션, 인덱스, 정합성</h3>
      <p>성능과 정합성이 함께 걸리는 주제를 운영 관점에서 살펴볼 수 있습니다.</p>
    </a>
  </div>
</section>

<section class="home-section">
  <div class="section-kicker">블로그 방향</div>
  <div class="section-head compact">
    <h2>이 블로그에서 주로 다루는 질문</h2>
  </div>

  <div class="focus-list">
    <article>
      <h3>어디서 장애가 시작되는가</h3>
      <p>느린 응답, lock wait, N+1, 재시도 폭증처럼 운영에서 먼저 보이는 신호를 기준으로 설명합니다.</p>
    </article>
    <article>
      <h3>언제 이 선택이 맞는가</h3>
      <p>기술 자체 소개보다 언제 적용하고 언제 피해야 하는지, 어떤 팀 규모에서 문제가 커지는지를 적습니다.</p>
    </article>
    <article>
      <h3>무엇을 확인해야 하는가</h3>
      <p>코드 예시만으로 끝내지 않고 로그, 메트릭, 상태 코드, SQL, 배포 흐름까지 함께 연결합니다.</p>
    </article>
  </div>
</section>

<section class="home-section">
  <div class="section-kicker">새로운 소식</div>
  <div class="section-head compact">
    <h2>최신 포스트를 살펴보세요</h2>
    <a class="text-link" href="{{ '/posts/' | relative_url }}">더 살펴보기</a>
  </div>

  <div class="post-list featured-posts">
    {% for post in site.posts limit: 6 %}
      <article class="post-row">
        <a href="{{ post.url | relative_url }}">
          <div class="post-row-body">
            <div class="post-category">
              {% for tag in post.tags limit: 2 %}
                <span>{{ tag }}</span>
              {% endfor %}
            </div>
            <h3>{{ post.title }}</h3>
            <p>{{ post.excerpt | strip_html | truncate: 135 }}</p>
            <time datetime="{{ post.date | date_to_xmlschema }}">{{ post.date | date: "%Y.%m.%d" }}</time>
          </div>
        </a>
      </article>
    {% endfor %}
  </div>
</section>
