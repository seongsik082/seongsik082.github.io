---
layout: default
title: Home
---

<section class="home-hero">
  <div class="home-hero-inner">
    <p class="eyebrow">Backend Engineering Blog</p>
    <h1>서버 사이드 문제를 기록하고, 다시 설명합니다.</h1>
    <p>Java, Spring, Network, Database를 중심으로 백엔드 개발의 기본기와 문제 해결 과정을 남깁니다.</p>
  </div>
</section>

<section class="profile-intro">
  <aside class="profile-card">
    <div class="profile-mark" aria-hidden="true">S</div>
    <strong>김성식</strong>
    <span>Backend Developer</span>
    <a href="https://github.com/seongsik082">github.com/seongsik082</a>
  </aside>
  <div>
    <p class="section-label">About</p>
    <h2>문제를 작게 나누고, 동작 원리를 이해한 뒤 구현합니다.</h2>
    <p>
      이 블로그는 백엔드 개발자로 공부하고 구현하면서 마주친 개념과 시행착오를 정리하는 공간입니다.
      네트워크, Java, HTTP, 데이터베이스처럼 서버 개발의 바닥을 이루는 주제를 차근차근 기록합니다.
    </p>
    <div class="hero-actions">
      <a href="/posts/">Posts</a>
      <a href="/projects/">Projects</a>
      <a href="https://github.com/seongsik082">GitHub</a>
    </div>
  </div>
</section>

<section class="home-topics">
  <span>API 설계</span>
  <span>Spring Boot</span>
  <span>JPA</span>
  <span>MySQL</span>
  <span>Redis</span>
  <span>Docker</span>
  <span>CI/CD</span>
  <span>성능 개선</span>
</section>

<section class="home-section">
  <div class="section-kicker">새로운 소식</div>
  <div class="section-head compact">
    <h2>최신 포스트를 살펴보세요</h2>
    <a class="text-link" href="/posts/">더 살펴보기</a>
  </div>

  <div class="post-list featured-posts">
    {% for post in site.posts limit: 5 %}
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

<section class="home-section resume-preview">
  <div>
    <div class="section-kicker">Study Map</div>
    <h2>앞으로 채워갈 백엔드 기록</h2>
  </div>
  <div class="resume-items">
    <article>
      <span>01</span>
      <h3>Java와 Spring</h3>
      <p>문법, 객체지향, Spring MVC, 예외 처리, 테스트 코드를 학습 노트로 정리합니다.</p>
    </article>
    <article>
      <span>02</span>
      <h3>Network와 HTTP</h3>
      <p>요청이 서버에 도착하는 과정, 상태 코드, API 설계 기준을 백엔드 관점에서 기록합니다.</p>
    </article>
    <article>
      <span>03</span>
      <h3>Database와 운영</h3>
      <p>쿼리, 인덱스, 트랜잭션, 배포 자동화, 로그를 실제 문제 해결과 연결해 정리합니다.</p>
    </article>
  </div>
</section>
