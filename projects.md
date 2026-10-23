---
layout: default
title: Projects
permalink: /projects/
---

{% assign career = site.data.portfolio.career %}

<section class="page-title">
  <p class="eyebrow">Projects</p>
  <h1>실제 서비스 운영과 개인 프로젝트에서 쌓은 문제 해결 경험입니다.</h1>
  <p class="page-description">
    실무 사례는 무엇이 문제였고, 어떻게 접근했고, 결과가 어땠는지 순서로 정리했습니다.
  </p>
</section>

<section>
  <div class="section-head compact">
    <div>
      <p class="section-kicker">Work Experience</p>
      <h2>웹서비스 기능 개선 및 운영 안정화</h2>
    </div>
  </div>
  <p class="project-context">{{ career.period }} · {{ career.company }} {{ career.team }} · {{ career.stack }}</p>

  <div class="case-list">
    {% for item in site.data.portfolio.highlights %}
      <article class="project-card">
        <div>
          <p class="section-label">{{ forloop.index | prepend: '0' | slice: -2, 2 }} / {{ item.label }}</p>
          <h3>{{ item.title }}</h3>
          <p>{{ item.summary }}</p>
        </div>
        <dl>
          <dt>Problem</dt>
          <dd>{{ item.problem }}</dd>
          <dt>Approach</dt>
          <dd>{{ item.approach }}</dd>
          <dt>Result</dt>
          <dd>{{ item.result }}</dd>
        </dl>
        <p class="card-stack">{{ item.stack }}</p>
      </article>
    {% endfor %}
  </div>
</section>

<section>
  <div class="section-head compact">
    <div>
      <p class="section-kicker">Side Projects</p>
      <h2>개인 프로젝트</h2>
    </div>
  </div>

  <div class="post-list project-list">
    {% for project in site.data.portfolio.projects %}
      <article class="post-row project-row">
        <p class="section-label">{{ project.label }}</p>
        <h3>{{ project.title }}</h3>
        <p>{{ project.summary }}</p>
        <p class="card-stack">{{ project.stack }}</p>
        <p class="project-links">
          {% for link in project.links %}
            <a class="text-link" href="{{ link.url }}">{{ link.label }}</a>
          {% endfor %}
        </p>
      </article>
    {% endfor %}
  </div>
</section>
