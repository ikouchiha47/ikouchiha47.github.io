#import "@preview/modern-cv:0.10.0": *

#show link: underline
#show: resume.with(
  author: (
    firstname: "Amitava",
    lastname: "Ghosh",
    email: "amitava.dev@proton.me",
    phone: "(+91) 6294097693",
    github: "ikouchiha47",
    homepage: "https://ikouchiha47.github.io",
    linkedin: "segfault-survivor",
    address: "India",
    positions: (
      "Staff Software Engineer",
      "Platform Engineering, Distributed Systems & Backend Infrastructure",
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
Staff platform engineer with 11+ years of experience, focused on distributed systems, internal developer platforms, and high-throughput backends. Own architecture end-to-end - reliability, performance, multi-team leverage, and cost-aware infra tradeoffs (compute shape, managed data stores, CDN/cache) - from incident RCA to shared SDKs and workflow infrastructure.

#set text(size: 9.5pt)
= Technical Skills
#resume-skill-item(
  "Languages",
  (strong("Go"), strong("Python"), strong("JavaScript"), "Ruby on Rails", "Node.js", "Bash", "Lua"),
)
#resume-skill-item(
  "Data & Databases",
  (strong("PostgreSQL"), strong("MySQL"), "DynamoDB", strong("Redis"), "SQL"),
)
#resume-skill-item(
  "Platform & Tools",
  (strong("AWS"), "Terraform", "CI/CD", "Nginx", "Datadog", "Docker", "Linux", "Developer Experience", "SDK/DSL Design"),
)
#resume-skill-item(
  "Systems & Patterns",
  ("Event-driven architecture", "Workflow orchestration", "Observability", "Prompt/eval tooling", "Embeddings / retrieval"),
)

= Named Systems
#resume-item[
  - *Workflow Engine* - NetworkX DAG + transactional outbox for durable media generation (Affogato)
  - *Optimux* - on-the-fly image/video delivery, Go + libvips (Affogato); upstream govips contributions
  - *Platform Go SDK* - config, logging, PII, HTTP client, notification client; foundation for platform eng (Sequoia)
  - *go-batteries* - reusable Go backend scaffolding toolkit
  - Architecture notes: materials-science progressive indexing, research agents, hypothesis loops - #link("https://ikouchiha47.github.io")[blog]
]

= Professional Experience

#resume-entry(
  title: "Scalarity",
  location: "Bengaluru, India",
  date: "Dec 2025 - Feb 2026",
  description: "Software Engineer (Consulting) | Python, GCP, embeddings, agent systems",
)
#resume-item[
  - Defined success and trust metrics for the AI research product (time-to-first-useful-result, session depth, tenant isolation / no cross-user context leak, citation-faithful outputs) and prioritized delivery against them - e.g. progressive indexing so researchers could search and chat within \~2s of upload (vs \~90s all-or-nothing) cut upload drop-off 34%→8% and papers/session 2.1→4.7.
  - Handcrafted golden-set metrics and a separate eval loop for GEPA-style prompt optimization (rubrics, precision/recall): traced whether the right tools were invoked rather than minimizing raw tool-call count, so agent quality improved via measured iteration.
  - Claude skills for multi-cloud model deploy (Vertex + SageMaker) and app/IaC rollout; same loop enforced archlint, test coverage, and code-quality metrics while coding.
  - Built multi-tenant research-agent platform (hybrid semantic + SPECTER retrieval, section taxonomy, ColPali, agents-as-tools) with per-user/namespace isolation so identical papers/searches never shared agent context across tenants; hypothesis→experiment loop ranked falsifiable claims and executable workspaces in \~23 min vs 1-2 weeks manual setup.
  - Exposed materials compute in-loop (ML screen to DFT/GPAW via codegen + credential-isolating compute gateway) so agents could prune candidates before expensive runs.
  - Compressed a materials property corpus from \~11.25 GB to \~300 MB; served formula search from SQLite under 500 ms - open-sourced on Fly.io to cut third-party quota cost.
]

#resume-entry(
  title: "Affogato (formerly Rendernet)",
  location: "Bengaluru, India",
  date: "Dec 2024 - Dec 2025",
  description: "Senior Software Engineer | Python, Go, Postgres, Redis | Team: 5 BE, 4 FE, 3 PM",
)
#resume-item[
  - De-risked media orchestration with an *MVP Workflow Engine* (NetworkX DAG on the existing transactional outbox - no third-party orchestration framework), saving engineering, infra, adoption, and maintenance cost while keeping reliability for all stakeholders: media generation false fails \~30% → \~0%, stopped wrongful refunds/CS load, and let leads safely delegate new workflows.
  - Built Optimux, an *on-the-fly media optimisation and delivery* platform for canvases with 1k+ images (Go + libvips, nginx/EFS cache, HTTP/2 prefetch; ffmpeg farm for WebVTT captions + sprite-sheet scrub thumbs). Cut transfer \~4 GB → \~10 MB; \~8 images/s per box on 2 EC2 nodes (EFS/nginx over Lambda for unit cost); upstream govips fixes.
  - Decoupled prompt authorship from backend releases (Markdown units to CI to versioned S3, multi-env tags). Product prompt iteration went from hours to minutes; backend stopped owning prompt edits.
  - Templatized PRD → ADR → task breakdown → acceptance criteria; got leadership buy-in, then multi-agent handoff (architecture / BE / FE sub-agents). Tech leads co-authored prompts and shared FE/BE design guidelines so generated code stayed consistent; hexagonal ports for schema evolution; joint mock APIs so frontend built against contracts day one - cutting eve-of-ship crunches.
  - Claude/Opencode skills for code deploy, IaC, and quality gates (archlint, tests, coverage as quantifiable checks while coding) plus eval-driven development so the AI code generator was scored against acceptance criteria, not vibes.
  - Outage-analysis and scalability skills: AWS CLI + failure-mode hunt, then prove claims in sandboxed UAT (spin infra, write load code, simulate traffic) so recommendations were benchmarked, not guessed.
  - Shipped ffmpeg + VLM video analysis (color shifts, plots, subject-action graphs, audio tempo, sentiment) + Langfuse eval hooks so quality could be scored instead of tuned by eye; full metric-first product loop limited by org alignment before shutdown.
]

#resume-entry(
  title: "TheBackendCompany",
  location: "Bengaluru, India",
  date: "Dec 2023 - Dec 2024",
  description: "Freelance & Consulting",
)
#resume-item[
  - Career break: sport clothing brand attempt; PM crash course (market fit, prioritization, user needs).
  - Built *go-batteries* (Go backend scaffolding) and a SQLite-WASM CSV tool for large dataset transforms - led to getting noticed and hired. Side LLM API learning project (Ollama + LangChain).
]

#resume-entry(
  title: "Sequoia Group",
  location: "Bengaluru, India",
  date: "Aug 2020 - Jul 2023",
  description: "Senior Software Engineer | Go, Redis, AWS, DynamoDB, Python",
)
#resume-item[
  - Laid the foundation for Platform Engineering via a company-wide Go SDK other backend teams adopted: shared config, then logging and PII filters (all services), standardized HTTP client, and Notification client SDK with client-side rate limiting - eliminating per-team reimplementation of cross-cutting concerns.
  - Owned Notification Service end-to-end (SQS/SNS/SES: outbox, rate limiting, bounce handling, metrics) while growing that SDK; resolved a production OOM (unbounded query + rate-limiter bug to SQS duplicate flood). Incident plus the shared platform surface made platform eng a first-class org function.
  - Led org-wide S3 migration to private buckets with signed URLs; custom URL scheme and generic download layer became shared infrastructure - another pillar of the same platform foundation. Picked DynamoDB/S3/worker shapes with cost and ops load in mind; tracked usage.
  - Diagnosed login outages for Salesforce-onboarded employees to MySQL lock contention under repeatable-read isolation plus multi-hour replica lag; RCA drove a company-wide onboarding SLA change.
  - Built CSV bulk employee onboarding with validation, error reporting, and GORM read/write proxy for replica routing; improved memory efficiency via pprof.
]

#resume-entry(
  title: "Gojek",
  location: "Bengaluru, India",
  date: "2016 - 2020",
  description: "Product Engineer | Go, Rails, Postgres, Redis, Lua, Kong",
)
#resume-item[
  - Led the migration of authentication to the #strong[Kong API Gateway] across Gojek service hot paths at \~120k RPM peak (reportedly \~100M+ bookings/month). Moved token validation to the edge using custom Lua plugins backed by Redis (via Twemproxy), eliminating repeated downstream authentication calls that had become a bottleneck on Redis and the backing datastore. Migrated #strong[110 APIs across 6 services], establishing Kong as the #strong[organization-wide standard] API gateway.
  - Diagnosed a production gateway instability to #strong[retry amplification] caused by timeout mismatches, disabled connection reuse, and request pool contention between Kong and HAProxy. Correlated packet captures with latency, TCP connection, CPU, memory, and gateway success metrics to restore stable performance under load.
  - Validated gateway capacity by replaying #strong[\~5x peak] production traffic in UAT, profiling latency, resource utilization, and TCP connection metrics to size production deployment.
  - Automated Kong configuration deployment through CI using Kong Admin APIs with diff-based updates, replacing manual HAProxy edits and Jira-driven releases with #strong[Git-managed deployments]. Security reviewed and approved API whitelist changes as GitHub PRs instead of chasing Jira tickets - clearer audit trail and faster, reviewable gateway changes.
  - Integrated gateway observability through Kong's Datadog metrics and standardized request logging, later reused by the data engineering team for fraud detection pipelines.
  - Contributed to the decomposition of the Customer Service platform into Authentication, OTP, Notifications, and Booking History services. Built a Go authentication service with Redis-backed sliding-window rate limiting, added location-aware headers and localized error handling that enabled Gojek's later internationalization efforts, and developed SymSpell-powered global search and batched inventory synchronization processing millions of records daily.
]

#resume-entry(
  title: "Earlier roles",
  location: "India",
  date: "2014 - 2016",
  description: "Software Engineer | Kreeti, Leftshift | Rails, Node.js, React",
)
#resume-item[
  - Full-stack product work (social, marketplace, multi-tenant matrimony); Gojek app-review analysis project later acquired with Leftshift engagement.
]

= Education
#resume-entry(
  title: "West Bengal University of Technology",
  location: "Kolkata, India",
  date: "2010 - 2014",
  description: "B.Tech in Electronics & Communication Engineering",
)
