---
layout: default
title: Home
---

<section class="home-hero">
  <div class="home-hero-inner">
    <p class="eyebrow">Backend Developer Blog</p>
    <h1>백엔드 개발을 차근차근 기록합니다.</h1>
    <p>Java, Spring, Network, Database를 공부하며 배운 개념과 문제 해결 과정을 정리합니다.</p>
  </div>
</section>

<section class="profile-intro">
  <div>
    <p class="section-label">About</p>
    <h2>문제를 작게 나누고, 동작 원리를 이해한 뒤 구현합니다.</h2>
    <p>
      이 블로그는 백엔드 개발자로 공부하고 구현하면서 마주친 개념과 시행착오를 정리하는 공간입니다.
      네트워크, Java, HTTP, 데이터베이스처럼 서버 개발의 바닥을 이루는 주제를 차근차근 기록합니다.
    </p>
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
