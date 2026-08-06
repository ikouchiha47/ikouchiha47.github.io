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
Staff platform engineer focused on distributed systems, internal developer platforms, and high-throughput backends. Own architecture end-to-end - reliability, performance, and multi-team leverage - from incident RCA to shared SDKs and workflow infrastructure.

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
  title: "Affogato (formerly Rendernet)",
  location: "Bengaluru, India",
  date: "Dec 2024 - Dec 2025",
  description: "Senior Software Engineer | Python, Go, Postgres, Redis | Team: 5 BE, 4 FE, 3 PM",
)
#resume-item[
  - Eliminated false generation failures from lost updates in choreographed media pipelines (success shown as fail to wrongful refunds, CS load). Replaced scattered orchestration with a *Workflow Engine*: NetworkX DAG on the existing transactional outbox - durable, idempotent nodes and fork-join reconciliation without Temporal/Orkes.
  - Cut false-fail rate from \~30% to \~0%; team leads could safely delegate new workflow work to junior engineers.
  - Built *Optimux*, an on-the-fly image/video delivery layer (Go + libvips, nginx/EFS cache, HTTP/2 prefetch) after editor canvases with 1k+ AI images (3-5 MB each) transferred \~4 GB per refresh and froze browsers.
  - Reduced transfer from \~4 GB to \~10 MB; removed FE service-worker compression from the hot path; sustained \~8 images/s per box across 2 EC2 nodes; contributed memory-path fixes upstream to govips.
  - Decoupled prompt authorship from backend releases (Markdown units to CI to versioned S3, multi-env tags). Product prompt iteration went from hours to minutes; backend stopped owning prompt edits.
  - Established design practices across a \~13-person product/eng org: PRDs/ADRs with CTO buy-in, hexagonal ports for schema evolution, joint FE/BE design with mock APIs so frontend built against contracts day one - cutting eve-of-ship integration crunches.
  - Shipped ffmpeg video analysis + Langfuse eval hooks so quality could be scored instead of tuned by eye; full metric-first product loop limited by org alignment before shutdown.
]

#resume-entry(
  title: "Scalarity",
  location: "Bengaluru, India",
  date: "Dec 2025 - Feb 2026",
  description: "Founding Engineer (Consulting) | Python, GCP, embeddings, agent systems",
)
#resume-item[
  - Designed progressive PDF indexing so external researchers could search and chat within \~2s of upload (vs \~90s all-or-nothing). Figures/tables and deep extraction arrived in background stages.
  - Upload drop-off fell 34% to 8%; papers per session rose 2.1 to 4.7.
  - Built research-agent platform (hybrid semantic + SPECTER retrieval, section taxonomy, ColPali, agents-as-tools) and a hypothesis to experiment loop - ranked falsifiable claims and executable workspaces in \~23 minutes vs 1-2 weeks manual setup for external users.
  - Exposed materials compute in-loop (ML screen to DFT/GPAW via codegen + credential-isolating compute gateway) so agents could prune candidates before expensive runs.
  - Compressed a materials property corpus from \~11.25 GB to \~300 MB; served formula search from SQLite under 500 ms - open-sourced on Fly.io to cut third-party quota cost.
  - Enforced per-user/namespace workspace isolation so identical papers or searches never shared agent context across tenants (no cross-user context pollution).
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
  - Led org-wide S3 migration to private buckets with signed URLs; custom URL scheme and generic download layer became shared infrastructure - another pillar of the same platform foundation.
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
