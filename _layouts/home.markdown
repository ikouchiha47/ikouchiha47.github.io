---
layout: default
---

<!-- Page Header -->
{% if page.background %}
<header class="masthead" style="background-image: url('{{ page.background | prepend: site.baseurl | replace: '//', '/' }}')">
{% elsif page.background_color %}
<header class="masthead" style="background: {{page.background_color }}">
{% else %}
<header class="masthead">
  {% endif %}
  <div class="overlay"></div>
  <div class="container">
    <div class="row">
      <div class="col-lg-8 col-md-10 mx-auto">
        <div class="page-heading">
          <h1>{{ site.title }}</h1>
          {% if site.description %}
          <span class="subheading">{{ site.description }}</span>
          {% endif %}
        </div>
      </div>
    </div>
  </div>
</header>

<div class="container">
  <div class="row">
    <div class="col-lg-8 col-md-10 mx-auto">
      <i>Personal blog to keep a tack of my work, experiments, findings and thoughts.</i>
    </div>
  </div>

  <p>&nbsp;</p>

  <div class="row">
    <div class="col-lg-8 col-md-10 mx-auto">

      {{ content }}

      <!-- Home Post List -->
      {% for post in site.posts limit : 5 %}

      <article class="post-preview">
        <a href="{{ post.url | prepend: site.baseurl | replace: '//', '/' }}">
          <h2 class="post-title">{{ post.title }}</h2>
          {% if post.subtitle %}
          <h3 class="post-subtitle">{{ post.subtitle }}</h3>
          {% else %}
          <h3 class="post-subtitle">{{ post.excerpt | strip_html | truncatewords: 15 }}</h3>
          {% endif %}
        </a>
        <p class="post-meta">Posted by
          {% if post.author %}
          {{ post.author }}
          {% else %}
          {{ site.author }}
          {% endif %}
          on
          {{ post.date | date: '%B %d, %Y' }} &middot; {% include read_time.html content=post.content %}            
        </p>
      </article>

      <hr>

      {% endfor %}

      <!-- Pager -->
      <div class="clearfix">
        <a class="btn btn-primary float-right" href="{{"/posts" | relative_url }}">View All Posts &rarr;</a>
      </div>

    </div>
  </div>
</div>
