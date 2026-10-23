---
layout: default
title: Home
---

{% assign career = site.data.portfolio.career %}

<section class="home-hero">
  <div class="home-hero-inner">
    <p class="eyebrow">Java / Spring Backend Developer</p>
    <h1>서비스가 안정적으로 돌아갈 때까지 확인하는 백엔드 개발자 김성식입니다.</h1>
    <p class="home-hero-summary">
      Java/Spring Boot 기반 웹서비스의 기능 개선과 운영·유지보수를 {{ career.duration }}간 경험했습니다.
      고객 요청 분석부터 SQL 개선, 테스트, 운영 반영까지 직접 맡아 왔습니다.
    </p>
    <p class="home-hero-meta">{{ career.period }} · {{ career.company }} {{ career.team }}</p>
    <div class="hero-actions">
      <a href="{{ site.author.resume_url }}">이력서 보기</a>
      <a href="{{ '/projects/' | relative_url }}">프로젝트 보기</a>
      <a href="https://github.com/{{ site.author.github }}">GitHub</a>
    </div>
  </div>
</section>

<section class="home-stats" aria-label="요약">
  <div class="stat-card">
    <strong>{{ career.duration }}</strong>
    <span>Java/Spring Boot 웹서비스 개선·운영 실무</span>
  </div>
  <div class="stat-card">
    <strong>{{ site.data.portfolio.highlights.size }}건</strong>
    <span>문제 · 접근 · 결과로 정리한 실무 개선 사례</span>
  </div>
  <div class="stat-card">
    <strong>{{ site.posts.size }}편</strong>
    <span>백엔드 개념과 운영 이슈를 정리한 기술 글</span>
  </div>
</section>

<section class="home-section">
  <p class="section-kicker">Technical Experience</p>
  <div class="section-head compact">
    <h2>실무에서 해결한 문제</h2>
    <a class="text-link" href="{{ '/projects/' | relative_url }}">자세히 보기</a>
  </div>

  <div class="focus-list">
    {% for item in site.data.portfolio.highlights %}
      <article>
        <p class="section-label">{{ item.label }}</p>
        <h3>{{ item.title }}</h3>
        <p>{{ item.summary }}</p>
        <p class="card-stack">{{ item.stack }}</p>
      </article>
    {% endfor %}
  </div>
</section>

<section class="home-section">
  <p class="section-kicker">Skills</p>
  <div class="section-head compact">
    <h2>기술 스택</h2>
  </div>

  <dl class="skill-list">
    {% for group in site.data.portfolio.skills %}
      <div>
        <dt>{{ group.level }}</dt>
        <dd>
          {% for item in group.items %}<span>{{ item }}</span>{% endfor %}
        </dd>
      </div>
    {% endfor %}
  </dl>
</section>

<section class="home-section">
  <p class="section-kicker">Writing</p>
  <div class="section-head compact">
    <h2>최근 작성한 글</h2>
    <a class="text-link" href="{{ '/posts/' | relative_url }}">전체 글 보기</a>
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

<section class="contact-cta">
  <div>
    <p class="section-kicker">Contact</p>
    <h2>함께 일할 기회를 찾고 있습니다.</h2>
    <p>이력서와 포트폴리오에서 더 자세한 경험을 확인하실 수 있습니다. 편하게 연락 주세요.</p>
  </div>
  <div class="hero-actions">
    <a href="mailto:{{ site.author.email }}">이메일 보내기</a>
    <a href="{{ site.author.resume_url }}">이력서 보기</a>
    <a href="{{ site.author.portfolio_url }}">포트폴리오</a>
  </div>
</section>
