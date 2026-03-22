#import "@preview/modern-cv:0.6.0": *

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
      "Software Engineer",
      "Software Architect",
      "Developer",
    ),
  ),
  date: datetime.today().display(),
  language: "en",
  colored-headers: true,
  show-footer: false,
)

= Profile

I’m a platform engineer who enjoys building scalable, fault-tolerant systems and making them faster and more reliable. I spend a lot of time profiling and benchmarking to uncover bottlenecks,
reduce production issues, and improve system stability. I’ve led architectural decisions through ADRs, supported teams in building services, and worked across teams to improve delivery.
Working across different parts of the platform, and my familiarity with some low-level debugging tools has also made me comfortable adapting quickly to new domains and problems.


\
= Skills

#resume-skill-item(
  "Languages",
  (strong("Go"), strong("Javascript"), strong("Rails"), "NodeJS", "Lua", "Python", "Bash"),
)

#resume-skill-item(
  "Databases",
  ("MySQL", "PostgreSQL", strong("Redis"), "DynamoDB*"),
)

#resume-skill-item(
  "Technologies",
  (
    "AWS",
    "Terraform",
    "Docker & Containers",
    "gRPC",
    "Protobuf",
    "Redis Streams",
    "SDK & DSL Design",
  ),
)

#resume-skill-item(
  "Applied AI",
  ("Dspy", "CrewAI", "Langchain", "Langtrace", "Prompt and Context Engineering", "Workflow Orchestration", "Embeddings and Applications")
)

#resume-skill-item(
  "Other Skills",
  ("Distributed Systems", "Overservability", "Few Unix tools", "Zig"),
)

\
= Experience

#resume-entry(
  title: "Affogato (formerly Rendernet)",
  location: "Bengaluru, India",
  date: "12/2024 - 31/2025",
  description: "Senior Software Engineer",
)

#resume-item[
  *Desigining systems to support media generation and delivery, evolving schemas, MVPs and POCs to help product make decisions*

\

*Architecture & System Design Ownership*
- Designed an orthogonal architecture for a collaborative video editor, cleanly separating timelines, assets, workflows, and rendering concerns to enable independent evolution and rapid experimentation.
- Architected a workflow DSL backed by graph execution with concurrency controls, enabling faster integration of media-generation pipelines and reducing coordination overhead.
- Designed fractional indexing–based primitives for non-linear collaborative editing, avoiding global reindexing and write contention.
- Defined asynchronous, event-driven system patterns with queues and notifications to decouple user actions from long-running media processing and external dependencies.

\
*Platform Engineering*
- Owned platform-level architectural decisions across media generation, search, authorization, moderation, and gateway services, balancing latency, cost, and operational complexity.
- Designed a team-based authorization system and centralized reverse-proxy gateway with rate control and degraded-mode handling for external APIs.
- Built internal DSLs for cross-embedding, full-text search, and metadata enrichment to standardize retrieval and evaluation across products.
- Owned internal developer platform decisions, including CI/CD standards, QA gates, and automated PRD→ADR workflows using Claude-Code / Opencode agents.
- Standardized deployment, configuration, and review workflows across services, reducing cognitive load and improving developer velocity.
\

*Image & Video Optimization*
- Architected a dynamic image delivery pipeline (Golang + libvips) with on-the-fly and background compression, and dynamic go worker scaling, reducing transfer for 1K+ images from ~4GB to ~10MB.
- Drove upstream libvips and govips improvements by shifting to reader-based APIs, enabling streaming processing and automated C-bindings.
  #link("https://github.com/davidbyttow/govips/issues/476")[Upstream Issue]
- Designing a scalable ffmpeg farm for video compression, delivery, and editing workflows (and AWS MediaConvert for later)

\
*Agentic AI & LLM Infrastructure*:
  - Build agentic AI topologies, combining tools for faster scaffolding; optimized LLM Router with shorter prompts + vector search; developed internal tooling for rapid prompt experimentation.
  - Visual Intelligence: Built video analysis platform to extract screenplay structure, colors, and product metadata—foundation for knowledgebase refinement and campaign evaluation.
  - Building a critique system, combining LLM based scoring, embedding scoring, readibility scores, emotional scores. (Learning about Natural Language)

\
*Development Velocity*:
  - Set up CI/CD pipelines, QA checks, and Claude-Code/Opencode powered agents to accelerate PRD->ADR conversions, code reviews, tests, and refactors.
  - Bridged the gap between product team and dev team for faster iteration on prompt changes.
  - Other smaller convention changes, to match the deployment readiness of frontend-backend releases, reducing late nights and multiple refactors post release.
]

\

#resume-entry(
  title: "TheBackendCompany", 
  location: "Bengaluru, India",
  date: "12/2023 - 12/2024",
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
  date: "08/2020 - 07/2023",
  description: "Senior Software Engineer",
)

*Tech Stack* : Golang, Mysql, Redis, AWS, DynamoDB, Python, Airflow, Apache Benchmark, Linux tools: gdb, valgrind, perf.

\
#resume-item[
  - Led the development of multiple new features and addressed SSO login issues, centralizing CSV management across use cases for clients like Snap and Mongo, and handling file *encoding* issues
  - Build the developer platform for engineers for faster development, including *internal SDK*, docs generation, database migrations, PII log filters, merge conflict predictor etc.
  - Orchestrated the migration of unencrypted files and integrated Datadog APM to address slow queries and later introducing application and system metrics, across multiple teams.
  - Led efforts for Securing APIs with rate-limiting and more stringent request validations in collaboration with Security Team.
  - Collaborated on building an OpenID-based OAuth2 layer for employment history sharing, while resolving database locking issues from syncing new users and handling login requests, and maintaining compliance.
  - Developed and maintained core services, including a *notification system* using AWS(SQS, SES, SNS) and an internal developer platform to streamline workflows (PII log filters, database migrations, and more).
  - Standardized processes through the Golang SDK for configuration management, request tracing, and file encryption, while debugging production issues and resolving Redis connection issue to enable token caching and rate limiting.
  - Other notable work includes building a DB resolver library for Gorm V1, migrating code from Lambda to Airflow, and improving performance through pprof benchmarking and Flamegraphs.
  - Conducted code reviews, lectured on Go concurrency and Node.js Promises, and assisted teams in integrating with existing services, including generating Swagger docs,
]

\
#resume-entry(
  title: "Gojek",
  location: "Bengaluru, India",
  date: "2016 - 2020",
  description: "Product Engineer",
)

*Tech Stack* : Golang, Rails, Postgres, Redis & Twemproxy, Ansible, Wireshark, Lua, Kong(nginx).

\
#resume-item[
  -  During the monolith decomposition of customer service, I worked on OAuth-based authentication and authorization, otp sending, rebalancing with multiple provider, migrating from Rails to Golang, and setting application and system metrics.
  -  Led the customer gateway migration from HAproxy to Kong, improving API security, reducing AWS costs, and load optimization. This involved learning Lua, writing authentication plugins, setting system limits, planning percentage rollouts, and analyzing tcpdumps to resolve reconnection issues.
  -  Improved API whitelisting and fraud prevention, providing the security team with better visibility over public-facing APIs.
  - Help out security team, as they now had greater visibility and control over public facing API whitelisting, preventing frauds. 
  - Other Contributions
    - Implemented SymSpell to enhance ElasticSearch's Global Search service, improving fuzzy search accuracy and cross-selling, based on alpha-user feedback.
    - Helped resolve Kafka failures during GCP live migration by adjusting system parameters (ZOO_TICK_TIME, migration policies, and API timeouts) to prevent stream leader crashes, #link("https://issues.apache.org/jira/browse/KAFKA-4084")[kafka issue].
    - Contributed to the internationalization phase by adding location headers and localizing error messages in collaboration with translators to translate app errors.
    - Played a key role in Gojek’s e-commerce project, managing inventory synchronization and coordinating driver bookings across multiple services using existing APIs. 
    - Build and maintained a slack bot to get boxes and other system information, translations.
]

\
#resume-entry(
  title: "Leftshift",
  location: "Pune, India",
  date: "08/2016 - 09/2016",
  description: "Software Engineer",
)
*Tech Stack* : Nodejs, Javascript, React, Electron, Rails.
\
#resume-item[
  - Worked on a project to periodically get Gojek app reviews, writing API and database structure, for data team to analyze, etc. Acquired by Gojek
]

#resume-entry(
  title: "Kreeti Technologies",
  location: "Kolkata, India",
  date: "2014 - 2016",
  description: "Software Engineer",
)

*Tech Stack* : Rails, Postgres/Mysql, Redis, React, Nodejs, Phoenix(Elixir)

\
#resume-item[
  - Setup of the full stack of Memento , a social network app, database design,in MERN stack and deployment with Heroku. #link("https://web.archive.org/web/20171030101912/https://www.smarketplace.com/")[preview]
  - Implementation of login and account creation for CPG and Retailer, authentication, and authorization in Rails. Worked with UI/UX engineers. Photo upload using s3 and ImageMagick for image formatting. #link("https://web.archive.org/web/20171030101912/https://www.smarketplace.com/")[preview]
  - Implementing a commenting feature on the promotions page for communication between multiple parties, Email-based weekly and daily reminder of promotions with ActiveJob, sidekiq.
  - Rebuilding the internal payslip generation, with dashboard in Elixir.
  - Matrimony app, handling caste system with multitenancy, handling authentication with devise, tenancy with act_as_tenant, search and angular frontend #link("https://web.archive.org/web/20171030101912/https://merayog.com/")[preview]
]
\

= Education

#resume-entry(
  title: "West Bengal University of Technology",
  location: "Kolkata, India",
  date: "2010 - 2014",
  description: "B.Tech in Electronics & Communication Engineering",
)

