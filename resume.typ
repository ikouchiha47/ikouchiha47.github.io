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

A generalist software engineer, building, scaling and improving perforamnce of systems and processes, with an interest in building fault tolerant distributed systems, databases and some emulators.
I build platform services, profiled applications, optimize data and databases, file encoding and network issues, handle production outages stabilizing and monitoring the systems to facilitate application and developer productivity across cross-functional teams.


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
  ("AWS", "Terraform", "Containerization (Docker) & Namespaces", "SDKs", "DSL", "Grpc", "Protobuf", "Some Kafka", "Redis streams"),
)

#resume-skill-item(
  "Other Skills",
  ("Distributed Systems", "Overservability", "Debugging convoluted problems", "Zig"),
)

\
= Experience

#resume-entry(
  title: "Affogato (formerly Rendernet)",
  location: "Bengaluru, India",
  date: "12/2024 - Now",
  description: "Senior Software Engineer",
)

#resume-item[
  *Desigining systems to support media generation and delivery, evolving schemas, MVPs and POCs to help product make decisions*

*Platform Engineering* (Oversaw products including):
  - Workflow DSL backed by graphs (with concurrency handling), helping in faster integration
  - Designing Screenplay service to support video editing, allowing for collaborative editing (using fractional indexing)
  - DSL to facilitate easy Cross-embedding, Full Text Search
  - Team-based authorization system
  - Centralizing services like moderation, reverse proxy gateway for external services to control api limits, with queues for degraded experience

*Image & Video Optimization*:
  - Built dynamic image delivery pipeline with on-the-fly + background compression (Golang + libvips) reducing transfer for 1K+ images from 4G to ~10 MB;
  - Drove upstream libvips improvements by shifting to file pointer/reader APIs, enabling automated C-bindings. Designed dynamic Golang scaling and ran extensive performance benchmarks.
  - Got govips team to integrate Reader interface instead of returning bytes. #link("https://github.com/davidbyttow/govips/issues/476")[Issue]
  - *[WIP]* ffmpeg farm to handle video compression, delivery and edits.

*Agentic AI & LLM Infrastructure*:
  - Build agentic AI topologies, combining tools for faster scaffolding; optimized LLM Router with shorter prompts + vector search; developed internal tooling for rapid prompt experimentation.
  - Visual Intelligence: Built video analysis platform to extract screenplay structure, colors, and product metadata—foundation for knowledgebase refinement and campaign evaluation.
  - Building a critique system, combining LLM based scoring, embedding scoring, readibility scores, emotional scores. (Learning about Natural Language)

*Developer Velocity*:
  - Set up CI/CD pipelines, QA checks, and Claude-Code/Opencode powered agents to accelerate PRD->ADR conversions, code reviews, tests, and refactors.
]

\

#resume-entry(
  title: "TheBackendCompany", 
  location: "Bengaluru, India",
  date: "12/2023 - 12/2024",
  description: "Freelance & Consulting",
)

#resume-item[
- Web based CSV processing system with Sqlite WASM, helping in quick analysis, cleanup, and computation of data.
- Consulted a startup on setting up their online presence, providing them landing page designs, cost estimation to start up and scale with online service providers like Zoho, Microsoft emails, server cost, domain pricing etc.
- Building on github.com/go-batteries, an one stop shop for most platform services, and tools to scaffold projects with them.
- Worked on a python project, with LLM, backed by ollama to provide an api to categorize text. Using Langchain and vector databases to summarize customer reviews sentiment, for fun.
- Mr.Notorious
  - Wanting to see how to start a business. I managed to start an apparel company for serious weight-lifters. I handled most things, tech, graphic design, ideation, fabric research, market research for vendors and order quantities. 
  - The cool factor was providing a customizable QR code on the sleeves to link directly to product page or self promote. The reminisance can be found on instagram #link("https://www.instagram.com/impowerbuff")[impowerbuff], and mr-notorious was the name of the cohort.
- I ended up learning deployment and CI, adding terraform and some AWS products, sorting out what I want in life.
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
  - Led the development of multiple new features and addressed SSO login issues, centralizing CSV management across use cases for clients like Snap and Mongo.
  - Built an OpenID-based OAuth2 layer for employment history sharing, while resolving database locking issues from syncing new users and handling login requests.
  - Orchestrated the migration of unencrypted files and integrated Datadog APM to address slow queries and later introducing application and system metrics.
  - Developed and maintained core services, including a notification system using AWS(SQS, SES, SNS) and an internal developer platform to streamline workflows (PII log filters, database migrations, and more).
  - Building the developer platform for engineers for faster development, including SDK, docs generation, database migrations, PII log filters, merge conflict predictor etc.
  - Standardized processes through the Golang SDK for configuration management, request tracing, and file encryption, while debugging production issues and resolving Redis connection issue to enable token caching and rate limiting.
  - Conducted code reviews, lectured on Go concurrency and Node.js Promises, and assisted teams in integrating with existing services, including generating Swagger docs, Securing APIs with rate-limiting and more stringent request validations in collaboration with Security Team.
  - Other notable work includes building a DB resolver library for Gorm V1, migrating code from Lambda to Airflow, and improving performance through pprof benchmarking and Flamegraphs.
  - Build the initial POC and helped complete a GraphQL backed API aggregator for Medical Records, Doctors from multiple different external sources, with hystrix timeouts.
  - Helping new teams integrate with existing services, and generating swagger docs and request/response models using
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

