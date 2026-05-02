#import "@preview/modern-cv:0.9.0": *

#show link: underline
#show: resume.with(
  author: (
    firstname: "Amitava",
    lastname: "Ghosh",
    email: "amitava.dev@proton.me",
    phone: "(+91) 629-409-7693",
    github: "ikouchiha47",
    homepage: "https:/ikouchiha47.github.io",
    linkedin: "https://www.linkedin.com/in/segfault-survivor",
    address: "India",
    positions: (
      "Senior Software Engineer",
      "Platform Engineer",
      "Software Architect",
    ),
  ),
  date: datetime.today().display(),
  language: "en",
  profile-picture: none,
  colored-headers: true,
  show-footer: false,
)

= Profile

Senior backend and platform engineer with 9+ years of experience designing, building, and owning high-scale systems in production. Specialized in platform architecture, fault-tolerant distributed systems, and developer infrastructure, with a strong track record of making architectural tradeoffs under ambiguity. Trusted to define system boundaries, stabilize complex production environments, and guide teams through critical technical decisions impacting reliability, performance, and velocity.

= Skills

#resume-skill-item(
  "Languages",
  (strong("Go"), strong("JavaScript"), strong("Ruby"), "Node.js", "Python", "Lua", "Bash"),
)

#resume-skill-item(
  "Databases",
  ("PostgreSQL", "MySQL", strong("Redis"), "DynamoDB"),
)

#resume-skill-item(
  "Technologies",
  (
    "AWS",
    "Terraform",
    "Docker & Containers",
    "gRPC",
    "Protobuf",
    "Kafka",
    "Redis Streams",
    "SDK & DSL Design",
  ),
)

#resume-skill-item(
  "Systems",
  (
    "Distributed Systems",
    "Observability",
    "Performance Profiling",
    "Failure Analysis",
    "Debugging Production Systems",
  ),
)

\

= Experience

#resume-entry(
  title: "Affogato (formerly Rendernet)",
  location: "Bengaluru, India",
  date: "12/2024 – Present",
  description: "Senior Software Engineer — Platform / Architecture",
)

#resume-item[
*Architecture & System Design Ownership*
- Designed an orthogonal architecture for a collaborative video editor, cleanly separating timelines, assets, workflows, and rendering concerns to enable independent evolution and rapid experimentation.
- Architected a workflow DSL backed by graph execution with concurrency controls, enabling faster integration of media-generation pipelines and reducing coordination overhead.
- Designed fractional indexing–based primitives for non-linear collaborative editing, avoiding global reindexing and write contention.
- Defined asynchronous, event-driven system patterns with queues and notifications to decouple user actions from long-running media processing and external dependencies.

*Platform Engineering*
- Owned platform-level architectural decisions across media generation, search, authorization, moderation, and gateway services, balancing latency, cost, and operational complexity.
- Designed a team-based authorization system and centralized reverse-proxy gateway with rate control and degraded-mode handling for external APIs.
- Built internal DSLs for cross-embedding, full-text search, and metadata enrichment to standardize retrieval and evaluation across products.
- Owned internal developer platform decisions, including CI/CD standards, QA gates, and automated PRD→ADR workflows using Claude-Code / Opencode agents.
- Standardized deployment, configuration, and review workflows across services, reducing cognitive load and improving developer velocity.

*Image & Video Optimization*
- Architected a dynamic image delivery pipeline (Golang + libvips) with on-the-fly and background compression, reducing transfer for 1K+ images from ~4GB to ~10MB.
- Drove upstream libvips and govips improvements by shifting to reader-based APIs, enabling streaming processing and automated C-bindings.
  #link("https://github.com/davidbyttow/govips/issues/476")[Upstream Issue]
- Designing a scalable ffmpeg farm for video compression, delivery, and editing workflows (*WIP*).

*Agentic AI & LLM Infrastructure*
- Designed agentic system topologies using CrewAI-style orchestration, structuring agents as composable, tool-driven workflows rather than ad-hoc prompt chains.
- Optimized LLM routing using embeddings and vector search to reduce latency and improve response quality.
- Built a critique and evaluation system combining LLM-based scoring, embeddings, readability, and emotional analysis for content quality assessment.
]

\

#resume-entry(
  title: "TheBackendCompany",
  location: "Bengaluru, India",
  date: "12/2023 – 12/2024",
  description: "Freelance & Consulting",
)

#resume-item[
- Designed and built a web-based CSV processing system using SQLite WASM for fast, local analysis and transformation of large datasets.
- Consulted startups on early-stage architecture, infrastructure cost modeling, and cloud adoption strategies.
- Built github.com/go-batteries, a reusable platform toolkit for scaffolding backend services and internal infrastructure.
- Built LLM-backed APIs using Ollama and LangChain for text categorization and sentiment analysis experiments.
- Founded and operated a small D2C apparel brand, owning end-to-end execution across product design, vendor sourcing, tech, and operations.
]

\

#resume-entry(
  title: "Sequoia Group",
  location: "Bengaluru, India",
  date: "08/2020 – 07/2023",
  description: "Senior Software Engineer",
)

#resume-item[
- Owned backend architecture decisions for core services handling authentication, notifications, and data ingestion, balancing performance, security, and operational simplicity.
- Led migrations and stabilization efforts, resolving database locking issues and introducing observability via Datadog APM.
- Designed and maintained internal developer platform components (SDKs, migrations, tracing, PII filtering) adopted across teams.
- Diagnosed and resolved complex production failures using pprof, flamegraphs, Redis analysis, and system-level debugging tools.
]

\

#resume-entry(
  title: "Gojek",
  location: "Bengaluru, India",
  date: "2016 – 2020",
  description: "Product Engineer",
)

#resume-item[
- Led architectural components of customer-service platform decomposition, including OAuth-based authentication, gateway migration, and service hardening.
- Designed and implemented Kong/Lua plugins for authentication and rate limiting, improving API security and reducing infrastructure costs.
- Diagnosed Kafka and networking failures during large-scale migrations using tcpdump, Wireshark, and system tuning.
- Contributed to platform-wide reliability and internationalization efforts through shared libraries and standards.
]

\

#resume-entry(
  title: "Leftshift",
  location: "Pune, India",
  date: "08/2016 – 09/2016",
  description: "Software Engineer",
)

#resume-item[
- Built internal tools for collecting and analyzing mobile app reviews, including API design and data modeling. Project later acquired by Gojek.
]

\

#resume-entry(
  title: "Kreeti Technologies",
  location: "Kolkata, India",
  date: "2014 – 2016",
  description: "Software Engineer",
)

#resume-item[
- Built and deployed full-stack applications using Rails, React, and Node.js, owning database design, authentication, and deployment.
- Implemented multitenant systems, background processing pipelines, and media handling workflows on AWS.
]

\

= Education

#resume-entry(
  title: "West Bengal University of Technology",
  location: "Kolkata, India",
  date: "2010 – 2014",
  description: "B.Tech in Electronics & Communication Engineering",
)
