---
layout: default
title: Home
---

<section class="home-hero">
  <div class="home-hero-inner">
    <p class="eyebrow">Backend Developer · 김성식</p>
    <h1>김성식의 기술 블로그</h1>
    <p>Be steady, Be reliable, Be better.</p>
  </div>
</section>

<section class="profile-intro">
  <div class="profile-mark" aria-hidden="true">S</div>
  <div>
    <p class="section-label">Manifesto</p>
    <h2>문제를 끝까지 추적하고, 이해한 만큼 단순하게 구현하려고 합니다.</h2>
    <p>
      Java, Spring Boot, 데이터베이스, 인프라를 중심으로 서비스의 핵심 흐름을 만들고 기록합니다.
      만든 것보다 왜 그렇게 만들었는지, 어디서 막혔고 어떻게 풀었는지를 남기는 블로그입니다.
    </p>
    <div class="hero-actions">
      <a href="/posts/">Posts</a>
      <a href="/projects/">Resume</a>
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
    <div class="section-kicker">Resume</div>
    <h2>백엔드 개발자로 보여주고 싶은 것</h2>
  </div>
  <div class="resume-items">
    <article>
      <span>01</span>
      <h3>API와 도메인 설계</h3>
      <p>요구사항을 요청 흐름, 데이터 모델, 예외 처리 기준으로 나누어 정리합니다.</p>
    </article>
    <article>
      <span>02</span>
      <h3>데이터와 성능</h3>
      <p>쿼리, 인덱스, 캐시 적용 기준을 실험과 기록으로 남깁니다.</p>
    </article>
    <article>
      <span>03</span>
      <h3>배포와 운영</h3>
      <p>Docker, CI/CD, 로그를 통해 고칠 수 있는 서비스를 지향합니다.</p>
    </article>
  </div>
</section>
