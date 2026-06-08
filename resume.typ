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

// Override template font size globally (must come AFTER the show rule)
#set text(size: 10pt)
#set par(leading: 0.5em)

= Profile Summary

Platform and Distributed Systems Architect with extensive experience designing and scaling mission-critical, high-throughput backend systems. I specialize in bridging the gap between ambiguous scientific/business requirements and concrete, reliable product surfaces. Proven ability to lead architectural decisions (ADRs), build internal developer tooling (DevEx), and execute complex performance and reliability improvements across entire service ecosystems. Deep technical fluency in low-level debugging, cloud-native patterns, and modern AI/LLM infrastructure.


\
// Shrink everything from here down (Technical Skills + Professional Experience)
#set text(size: 6pt)

= Technical Skills

#resume-skill-item(
  "Languages",
  (strong("Go"), strong("JavaScript"), strong("Rails"), "NodeJS", "Python", "Bash", "Lua", "Zig"),
)

#resume-skill-item(
  "Data & Databases",
  (strong("PostgreSQL"), strong("MySQL"), "DynamoDB", strong("Redis"), "SQL"),
)


#resume-skill-item(
  "Platform & Tools",
  (strong("AWS"), "Datadog", "TICK stack", "AppSec", "CI/CD", "Queues", "Linux Tools", "Nginx", "Terraform", "SDK/DSL Design", "Developer Experience"),
)

#resume-skill-item(
  "AI & ML Infrastructure",
  ("Dspy", "Langchain", "CrewAI", "Langtrace", "Prompt/Context Engineering", "Workflow Orchestration", "Embeddings"),
)


= Professional Experience

\
#resume-entry(
  title: "Scalarity",
  location: "Bengaluru, India",
  date: "12/2025 - 02/2026",
  description: "Founding Engineer",
)

\
#resume-item[
  _Consulting with previous CTO to build a scientific data platform_

  - *Scientific Platform Architecture:* Defined and materialized the core platform architecture around data federation and inter-institution data movement, allowing experimental provenance and data to flow seamlessly across academic boundaries without centralizing massive datasets.
  - *Domain Translation:* Partnered directly with researchers and scientists to translate ambiguous scientific workflows (e.g., DFT, GPAW materials science) into a concrete, functional product surface, making informed architectural decisions.
  - *Data & Search Engineering:* Developed a hierarchical PDF reader and implemented advanced semantic search, significantly improving knowledge access by integrating diverse embedding models and generating candidate research questions.
  - *System Optimization:* Optimized complex materials datasets stored on Figshare, achieving a substantial reduction in storage and transfer costs (from 2GB to 300Mb).
  - *Agentic Pipelines:* Built an "Experiment agent" and validation ecosystem capable of ingesting historical research papers and attempting to synthesize final, high-quality research documents. Deployed multiple models for embeddings and qa on *GCP*
]

\
#resume-entry(
  title: "Affogato (formerly Rendernet)",
  location: "Bengaluru, India",
  date: "12/2024 - 12/2025",
  description: "Senior Software Engineer | Python, Golang, Postgres, Redis, Distributed Tracing",
)

\
#resume-item[
  _Designing large-scale systems for media generation and delivery_


  *System Architecture & Design Ownership*
  - *Workflow DSL & Collaboration:* Designed an orthogonal, scalable architecture for a collaborative video editor, cleanly separating core concerns (timelines, assets, rendering). Developed a Workflow DSL backed by graph execution, enabling faster integration of complex media pipelines.
  - *Concurrency & Indexing:* Architected fractional indexing primitives to support non-linear, collaborative editing in real-time, effectively eliminating global reindexing overhead and write contention issues.
  - *Event-Driven Backbone:* Defined and owned asynchronous, event-driven patterns (queues, notifications) to decouple long-running media processing from user interactions, improving reliability and scalability.

  *Platform Engineering & Tooling*
  - *Developer Platform Ownership:* Standardized the entire internal developer experience (DevEx) by owning CI/CD standards, QA gates, and implementing automated PRD → ADR workflows using AI agents (Claude-Code / Opencode), significantly increasing developer velocity.
  - *Authorization & Gateway Services:* Designed a team-based authorization system and the centralized reverse-proxy gateway with rate control and degraded-mode handling for external APIs, enhancing platform security and resilience.
  - *Internal DSLs:* Built internal DSLs for cross-embedding, full-text search, and metadata enrichment to standardize retrieval and evaluation across products.

  *Image & Video Optimization*
  - *Image Pipeline:* Architected a high-throughput dynamic image delivery pipeline (Golang + libvips) with on-the-fly and background compression and dynamic worker scaling, reducing image transfer costs from ~4GB to ~10MB.
  - *Upstream Contributions:* Drove upstream `libvips` and `govips` improvements by shifting to reader-based APIs, enabling streaming processing and automated C-bindings. #link("https://github.com/davidbyttow/govips/issues/476")[Upstream Issue]
  - *Video Pipeline:* Designing a scalable ffmpeg farm for video compression, delivery, and editing workflows (with AWS MediaConvert as a later option).

  *AI & Intelligence Capabilities*
  - Built sophisticated agentic AI topologies, including an optimized LLM Router (shorter prompts + vector search) and internal tooling for rapid prompt experimentation, scaffolding entire product features.
  - *Visual Intelligence:* Built a video analysis platform to extract screenplay structure, colors, and product metadata — foundation for knowledgebase refinement and campaign evaluation.
  - Developed a robust critique system that combines LLM-based scoring, embedding scoring, and readability/emotional metrics for quality assessment.

  *Development Velocity*
  - Bridged the gap between product and dev teams for faster iteration on prompt changes; introduced convention changes to align frontend-backend deployment readiness, reducing post-release refactors.
]

\
#resume-entry(
  title: "TheBackendCompany",
  location: "Bengaluru, India",
  date: "12/2023 - 12/2024",
  description: "Freelance & Consulting",
)

\
#resume-item[
  - Consulted multiple startups on early-stage architecture, infrastructure cost modeling, and strategic cloud adoption.
  - Developed `go-batteries`, a reusable platform toolkit written in Go for scaffolding backend services and standardizing internal infrastructure.
  - Built and deployed an LLM-backed API service using Ollama and LangChain for real-time text categorization and sentiment analysis experiments.
  - Engineered a web-based CSV processing system leveraging SQLite WASM for fast, client-side analysis and transformation of large datasets.
]

\
#resume-entry(
  title: "Sequoia Group",
  location: "Bengaluru, India",
  date: "08/2020 - 07/2023",
  description: "Senior Software Engineer | Golang, Redis, AWS, DynamoDB, Python, gdb, valgrind, perf.",
)

\
#resume-item[
  - *Feature Delivery:* Led development of multiple new features and addressed SSO login issues, centralizing CSV management across use cases for clients like Snap and Mongo, and handling file encoding issues.
  - *Developer Platform Enhancement:* Built and maintained the internal developer platform — internal SDK, docs generation, database migrations, PII log filters, and a merge-conflict predictor — streamlining engineer workflows.
  - *System Reliability & Observability:* Led migration of unencrypted files and integrated Datadog APM, systematically addressing slow queries and establishing centralized application and system metrics across multiple teams.
  - *Security & Access Control:* Implemented and maintained the OpenID-based OAuth2 layer for secure employment history sharing, and developed robust API rate-limiting and validation mechanisms in collaboration with the Security Team. Resolved Redis connection issues to enable token caching and rate limiting.
  - *Performance Engineering:* Improved core services through `pprof` benchmarking and Flamegraphs to identify and resolve deep-seated bottlenecks.
  - *Core Service Ownership:* Developed and maintained critical services, including a notification system (AWS SQS/SES/SNS) and standardized configuration management via a Golang SDK for tracing and file encryption.
  - *Other Notable Work:* Built a DB resolver library for Gorm V1, migrated code from Lambda to Airflow, and lectured on Go concurrency and Node.js Promises while assisting integration efforts (including Swagger doc generation).
]

\
#resume-entry(
  title: "Gojek",
  location: "Bengaluru, India",
  date: "2016 - 2020",
  description: "Product Engineer | Golang, Rails, Postgres, Redis, Lua, Kong",
)

\
#resume-item[
  - *API Security & Gateway Migration:* Led the migration of the customer gateway from HAproxy to Kong (Nginx), significantly improving API security, optimizing load, and reducing AWS costs. This required deep learning of Lua for custom authentication plugins and advanced network analysis (`tcpdumps`).
  - *System Decomposition:* Played a key role in the complex decomposition of the customer service monolith, involving implementing OAuth-based authentication, rebalancing providers, and managing the migration from Rails to Golang.
  - *Global Search Enhancement:* Improved global search accuracy for e-commerce services by implementing SymSpell, enhancing fuzzy search capabilities and cross-selling logic based on user feedback.
  - *API Whitelisting & Fraud Prevention:* Improved API whitelisting and fraud prevention, giving the security team greater visibility and control over public-facing APIs.
  - *Disaster Recovery:* Contributed to the resolution of Kafka failures during a GCP live migration by adjusting critical system parameters (ZOO_TICK_TIME, API timeouts) to ensure stream leader stability, #link("https://issues.apache.org/jira/browse/KAFKA-4084")[kafka issue].
  - *Internationalization:* Contributed to the i18n phase by adding location headers and localizing error messages in collaboration with translators.
  - *E-commerce:* Played a key role in Gojek's e-commerce project, managing inventory synchronization and coordinating driver bookings across multiple services.
]

\
#resume-entry(
  title: "Leftshift",
  location: "Pune, India",
  date: "08/2016 - 09/2016",
  description: "Software Engineer | Nodejs, Javascript, React, Electron, Rails",
)

\
#resume-item[
  - Worked on collecting and analyzing Gojek app reviews to provide actionable data insights for the data team. _(Project acquired by Gojek)._
]

#resume-entry(
  title: "Kreeti Technologies",
  location: "Kolkata, India",
  date: "2014 - 2016",
  description: "Software Engineer | Rails, Nodejs, React, Elixir",
)

\
#resume-item[
  - Full-stack setup of Memento, a social network app — database design, MERN stack, Heroku deployment.
  - Implemented login and account creation for CPG and Retailer flows in Rails (auth/authz) on smarketplace, with S3 + ImageMagick for photo upload and formatting, working alongside UI/UX engineers. #link("https://web.archive.org/web/20171030101912/https://www.smarketplace.com/")[preview]
  - Built a commenting feature on the promotions page for multi-party communication, plus weekly/daily promotion reminders via ActiveJob and Sidekiq.
  - Rebuilt the internal payslip generation with a dashboard in Elixir.
  - Built a matrimony app with multi-tenancy (`act_as_tenant`), Devise-based auth, search, and an Angular frontend. #link("https://web.archive.org/web/20171030101912/https://merayog.com/")[preview]
]


= Education

#resume-entry(
  title: "West Bengal University of Technology",
  location: "Kolkata, India",
  date: "2010 - 2014",
  description: "B.Tech in Electronics & Communication Engineering",
)
