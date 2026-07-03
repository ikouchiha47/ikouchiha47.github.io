#import "@preview/modern-cv:0.10.0": *

#show link: underline
#show: resume.with(
  author: (
    firstname: "Amitava",
    lastname: "Ghosh",
    email: "amitava.dev@proton.me",
    phone: "(+91) 629-409-7693",
    github: "ikouchiha47",
    homepage: "https://ikouchiha47.github.io",
    linkedin: "segfault-survivor",
    address: "India",
    positions: (
      "Staff Software Engineer",
      "Building Scalable, Fault-Tolerant Distributed Systems",
    ),
  ),
  date: datetime.today().display(),
  language: "en",
  profile-picture: none,
  colored-headers: true,
  show-footer: false,
)

// Global settings
#set text(size: 10pt)
#set par(leading: 0.65em)

= Profile Summary
Platform and Distributed Systems Architect with extensive experience designing and scaling high-throughput, mission-critical backend systems. Excel at translating ambiguous scientific or business requirements into reliable, production-grade architectures. Proven in leading architectural decisions, building internal developer platforms, and driving significant performance & reliability improvements across service ecosystems. Deep expertise in low-level debugging, cloud-native design, and AI/LLM infrastructure.

#set text(size: 9.5pt)
= Technical Skills
#resume-skill-item(
  "Languages",
  (strong("Go"), strong("JavaScript"), strong("Ruby on Rails"), "Node.js", "Python", "Bash", "Lua", "Zig"),
)
#resume-skill-item(
  "Data & Databases",
  (strong("PostgreSQL"), strong("MySQL"), "DynamoDB", strong("Redis"), "SQL"),
)
#resume-skill-item(
  "Platform & Tools",
  (strong("AWS"), "Datadog", "TICK Stack", "CI/CD", "Terraform", "Nginx", "Linux Tooling", "Developer Experience", "SDK/DSL Design"),
)
#resume-skill-item(
  "AI & ML Infrastructure",
  ("DSPy", "LangChain", "CrewAI", "Langtrace", "Prompt Engineering", "Workflow Orchestration", "Embeddings"),
)

= Professional Experience

#resume-entry(
  title: "Affogato (formerly Rendernet)",
  location: "Bengaluru, India",
  date: "Dec 2024 – Feb 2026",
  description: "Senior Software Engineer | Python, Go, Postgres, Redis, Distributed Tracing",
)
#resume-item[
  - Owned end-to-end collaborative video editor and media pipeline — from requirements to architecture and delivery. Introduced hexagonal architecture and decoupled prompting layer from rendering engine.
  - Authored PRDs and ADRs reviewed directly with the CTO to drive key architectural decisions (hexagonal architecture, Workflow DSL, prompting-layer decoupling); built an AI-assisted PRD-ADR-Stories workflow to scale the practice across the team. Eventually turning backend, frontend, deployments, into skills and subagents.
  - Designed Workflow DSL and graph execution engine enabling complex, scalable media workflows and real-time collaborative editing with fractional indexing.
  - Architected a high-throughput dynamic image pipeline (Go + libvips) powering a DAM layer with on-the-fly, arbitrary-size image transforms per consumer. Streaming compression and HTTP/2 Range prefetching cut transfer costs from ~4 GB to ~10 MB. Drove upstream contributions to govips.
  - Built an ffmpeg-based video processing farm producing editable, timeline-synced WebVTT transcript/caption tracks and scene-boundary markers; layered on a video analysis pipeline combining classical CV/audio processing (scene detection, speech-to-text) with multimodal LLM analysis to extract screenplay structure and metadata.
  - Designed a centralized outbound gateway for third-party AI provider calls (image/audio/video generation) with an optimized LLM router, enforcing per-vendor rate limiting for cost/quota control and content-safety filtering before requests reached external providers or content reached users.
  - Built a prompt-engineering platform decoupling prompt authorship from backend deployments - a structured Markdown repo organized per ad-type (jewellery, infomercial, demo-feature), where a CI pipeline resolved cross-file section references into a compiled system prompt and published versioned artifacts to S3. Product managers could author, test, and tag prompt versions per environment independently, without backend code changes or release coordination.

  *Scalarity (Consulting Engagement) — Founding Engineer*
  - Designed core architecture for a scientific data platform enabling secure federation and provenance tracking across institutions without centralizing large datasets.
  - Partnered with researchers to translate complex scientific workflows (DFT, GPAW materials science) into functional product surfaces and architectural decisions.
  - Built hierarchical PDF parser + semantic search engine using multiple embedding models, improving knowledge discovery and generating candidate research questions.
  - Optimized Figshare materials datasets, reducing storage and transfer costs from 2 GB to 300 MB.
  - Developed "Experiment Agent" pipeline with validation layer that ingests research papers and synthesizes high-quality outputs using GCP models.
]

#resume-entry(
  title: "TheBackendCompany",
  location: "Bengaluru, India",
  date: "Dec 2023 – Dec 2024",
  description: "Freelance & Consulting",
)
#resume-item[
  - Career break & taking a shot at building a sport clothing brand.
  - Took up a Product Management crash course to round out product-thinking alongside engineering — reasoning about market fit, prioritization, and user needs, not just system design.
  - Built `go-batteries`, a reusable Go toolkit for rapid backend scaffolding and standardized infrastructure.
  - Developed LLM-powered API service using Ollama + LangChain for real-time text categorization and sentiment analysis, as a learning engagement.
  - Created client-side CSV processing tool with SQLite WASM for large dataset transformation - led to getting noticed and hired.
]

#resume-entry(
  title: "Sequoia Group",
  location: "Bengaluru, India",
  date: "Aug 2020 – Jul 2023",
  description: "Senior Software Engineer | Go, Redis, AWS, DynamoDB, Python",
)
#resume-item[
  - Diagnosed critical login outages for Salesforce-onboarded employees to MySQL lock contention under repeatable-read isolation compounded by multi-hour read replica lag; the root-cause analysis directly informed a new company-wide onboarding SLA - changing how the org scheduled Salesforce onboarding going forward.
  - Led org-wide S3 security migration to private buckets with signed URLs; designed a custom URL scheme and generic download layer that became shared infrastructure - multiple backend teams built directly on top of it (e.g., encapsulating secure download URLs into their own service integrations) rather than reimplementing it.
  - Owned full lifecycle of Notification Service (SQS/SNS/SES) including outbox pattern, rate limiting, bounce handling, and metrics. Resolved production OOM incident caused by an unbounded query compounded by a rate-limiter bug that flooded SQS with duplicates.
  - Built CSV-based bulk employee onboarding service with validation, error reporting, and read/write proxy for GORM replica routing. Improved memory efficiency via pprof analysis.
  - Established org-wide Go standards (concurrency, logging, config) and built the internal SDK that became mandatory foundation across backend teams - other teams built directly on it for their own integrations (e.g., notification service clients), rather than each team maintaining separate implementations.
]

#resume-entry(
  title: "Gojek",
  location: "Bengaluru, India",
  date: "2016 – 2020",
  description: "Product Engineer | Go, Rails, Postgres, Redis, Lua, Kong",
)
#resume-item[
  - Migrated authentication from internal service to Kong API gateway (~100k concurrent bookings at peak) to eliminate self-DDoS on Redis/DB. Chose Kong over alternatives being evaluated and wrote custom Lua plugins, establishing Kong as the org-wide standard gateway pattern adopted by all teams. Debugged TCP backlog where slow requests starved fast ones; built config sync pipeline turning releases into PRs instead of Jira tickets.
  - Contributed to customer service decomposition (auth, notifications, OTP, booking history). Designed and load-tested Go auth service with Redis sliding-window rate limiting. Added location headers and localized error messages, enabling Gojek's later internationalization rollout.
  - Worked on global search platform (SymSpell fuzzy matching) and e-commerce inventory sync handling millions of records daily via batched workers.
]

#resume-entry(
  title: "Leftshift",
  location: "Pune, India",
  date: "Aug 2016 – Sep 2016",
  description: "Software Engineer | Node.js, React, Rails",
)
#resume-item[
  - Analyzed Gojek app reviews to deliver actionable insights for the data team (project later acquired by Gojek).
]

#resume-entry(
  title: "Kreeti Technologies",
  location: "Kolkata, India",
  date: "2014 – 2016",
  description: "Software Engineer | Rails, Node.js, React, Elixir",
)
#resume-item[
  - Built full-stack social network (Memento) including database design and Heroku deployment.
  - Developed core features for smarketplace (auth, image handling, promotions with reminders) and matrimony platform with multi-tenancy.
]

= Education
#resume-entry(
  title: "West Bengal University of Technology",
  location: "Kolkata, India",
  date: "2010 – 2014",
  description: "B.Tech in Electronics & Communication Engineering",
)
