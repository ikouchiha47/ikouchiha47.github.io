---
active: true
layout: post
title: "Learnings from Working at a Materials Science Company"
subtitle: "What building an LLM-powered research platform actually looks like"
date: 2026-02-23 00:00:00
background_color: '#000'
---

My previous employment was at a company in the `Digital asset management` space, working on making short form commercial videos, towards the end.

One of the USP was, consistent character generation, which was until `nano banana`, and soon other mainstream models caught up. So the switch was to,
generate short form commercial videos.
Once the shop closed, I spent time reflecting on how things went, and how the overlap landscape changes with AI in picture.
One of those thoughts gave birth to [krearts](https://github.com/ikouchiha47/krearts)

During the time I was also:

- Helping bootstrap an LLM-powered research platform for materials scientists.
  The kind where researchers upload papers, ask questions, and get structured answers with citations. Not a chatbot. A system.
- Was trying to make hot-choclate, because 90% of hot choclate served in Bangalore is either a middle-class bourvita drink with extra hot water,
  and the rest 10% adds a bunch of non-sense to hide their pathetic hot-choclate.

This blog documents some of the observations, in building a research oriented framework, and my understanding of this space, apart from code.

---

## The GPT wrapper fallacy

When people see ChatGPT, Claude, Grok — the assumption is that building an LLM product is just API calls with a nice UI. Upload a PDF, call the model, return the answer. Ship it.

The gap between *using* these tools and *building with* them is massive.

Attachment parsing alone is a project. Scientific PDFs have multi-column layouts, inline equations, tables that span pages, figures with captions that reference other figures. Getting clean text out of that isn't `pdf2text`. It's a pipeline — layout detection, table extraction, figure-caption association, section boundary identification. And every format is different. A Nature paper looks nothing like an arXiv preprint.

Then there's retrieval. Without preprocessing and indexing:
- Every question re-parses everything from scratch.
- Every query pays the full cost of understanding the document.

As a first prototype worked exactly this way - no tagging of sections, no embeddings, only enrchied extractions.

**It was slow, and it had to be tweaked continuously to support new types of queries**

Corrective RAG, structured extraction, citation grounding — each turned out to be its own subsystem with its own failure modes.
The "wrapper" ended up being the smallest part of the system.

---

## What actually happens to a query

A user types: *"What compositions showed the lowest formation energy across these three papers?"*

The naive assumption is "send to LLM, get answer." In practice, there's a whole pipeline before the model ever sees the question:

**Query expansion.** The raw question gets rewritten. "Formation energy" might need to expand to "enthalpy of formation," "DFT-computed stability," or specific notation like ΔHf. A single user question becomes multiple retrieval queries.

**Intent classification.** Is this a comparison across papers? A lookup in a single table? A synthesis question that needs reasoning? The retrieval strategy changes depending on the answer.

**Hybrid retrieval.** Full-text search (FTS), n-gram matching, and semantic embeddings each catch different things. FTS finds exact terms. N-grams handle partial matches and chemical formulas that embedding models mangle. Embeddings capture semantic similarity — "thermal stability" matching "resistance to decomposition."

None of this retrieval composition is new. Google has done this for decades. The difference is composing these with an LLM reasoning loop instead of hand-tuned ranking signals. Reciprocal Rank Fusion (RRF) merges results from different retrieval methods into a single ranked list. The LLM then reasons over the top results instead of just returning links.

**Reranking.** The initial retrieval casts a wide net. A reranker (cross-encoder or LLM-based) scores each chunk against the original question for fine-grained relevance. This is where you go from "related passages" to "the actual answer is in these three paragraphs."

---

## Video Generation, LLM focus and Hot Chocolate

At this point, we understand, that these foundational models are trained on a lot of data, and they have some inherent knowledge.
I would have imagined, that because of neural networks and how embedding space works, the llm would be the one who sees all patterns, but more powerful.

And maybe it does, but what is does and doesn't depends on how it was trained. So if one were to actually combine differnet domains, they would
have to map it to the same embedding space.

General LLMs are not an answer to this. In terms of video generation, it meant, that the underlying models have to be tweaked enough
to guard how the llm generates the media. An example being:

- Bags are not displayed the same way as watches.
- A wrist watch is not advertised the same way as a wall clock
- and, A mechanical watch is not adverstied the same way as a quartz.

The differences are at both macro and micro levels.
- The macro level define the physics, environment
- Micro determines where to market, whom to market, what to say, and even sometimes dictates the environment.

Such details become more visible, when we add cultural context to mix.
Say for a website builder, a common japaneese website looks quite different from a US built website.

Fashion is not the same. I mean, if anyone were to build an AI-based fashion brand, the first target should be Japan.
I have seen Japan, has magazines, which tell how about the clothing, what its for, how to pair it. Its very structured for data extraction and suggestions.

I am not entirely sure, but it appears to me that, with all these neural networks, LLMs tend to usually take the path of least work, and hence the need
for such detailed planning and guardrails, and extensive efforts at instruction following. Why would one need to use a custom embedding model if these foundational
models had all these world knowledge.

The paper should have been: "Focussed Attention is all you Need"


The **second problem** is LLM's lack of spatial awareness. When working with non-textual data, its fairly impossible for an LLM to predict things in real life.
This was back in very late 2025, no one of the llm models are consistenly good at dynamic camera angles mid scene.
Heavy action sequences, even something simple as parkour would fall apart.


The problem is not a video or image generation specific problem. If a system already has all the grounded data it needs, slapping an LLM on it, and
expecting things to turn out right, is a stupidity to embark on. LLMs are probablistic systems, so `If you expect a probablistic system to reliably (do X), it will probably, reliably (do X)`

The problem comes with predicting, anything that needs visual cues or actual feedback loops from predictions. This was confirmed, when I used gpt to make hot chocolate.

GPT probably had a lot of information, about how a good hot chocolate is made, even can tell you how countries or regions, liked their hot-chocolate to be like, **if you asked for it**.
It would have access to all kindof receipes, ratings, discussions, to give you a fair enough idea. 

Obviously an LLM has never seen or tasted hot chocolate, so it relies on what I call, "collective truth". So its not possible for an LLM to accurately predicit
the changes in quantities of different items, leading to different taste.

This is the same with materials research, CHGNet and other tools provide Contextual Models, which have computation baked in, than a LLM trying to predict.

So, when I asked the LLM to adjust the quantites for 4 person. Its replied with an amount of water or sugar, that was way far off from reality. What worked was:
- The LLM knew the desired result of each step, like: "a creamy paste, not a pudding thick. but not watery"
- The LLM also knows the taste (not going into the details of Oneshot or React)

So as long as you feed these signals back, 

---

## The preprocessing tax

Without an embedding and indexing pipeline, every query pays the full cost. Parse the PDF. Chunk it. Embed the chunks. Search. Answer. For a 40-page paper, that's 30+ seconds before the user sees anything.

The alternative is progressive indexing: make the paper useful immediately and build deeper indexes in the background.

This works in tiers:

1. **Instant** — Raw text extraction + section splitting. The paper is searchable within seconds.
2. **Fast** — Table detection, figure extraction, metadata parsing. Available within a minute.
3. **Deep** — Full embedding generation, entity extraction, cross-reference resolution. Runs in the background.

A query that arrives at tier 1 gets FTS-only retrieval. Not perfect, but fast and useful. By the time the researcher has read the first answer and typed a follow-up, tier 2 or 3 is ready.

The key insight: researchers don't upload a paper and immediately ask their hardest question. They start with "what's this about?" and work their way to specifics. Progressive indexing matches the system's readiness to the user's actual behavior.

---

## Graph RAG — where it fits

Graph RAG has real value. But the costs are real too.

Building a knowledge graph over a single document requires full entity extraction — identifying entities, properties, conditions, methods, extracting relationships, resolving co-references, building a traversable graph. For a single document, the cost is hard to justify. A well-chunked document with good metadata gets roughly 80% of the way there.

A lighter alternative is hierarchical section tagging — labeling sections with what they cover ("synthesis conditions," "characterization results," "computational methods," or whatever the domain's taxonomy looks like). This gives the retrieval system structural awareness without full graph construction. The LLM can then drive a ReAct loop to compare across sections, navigate the document hierarchy, and synthesize information — all without needing an entity graph.

Where graph RAG earns its keep is the slow-build case.

Researchers don't work with one paper. They work with a workspace — dozens of papers, their own experimental notes, simulation results, reviewer feedback. Over weeks and months, connections accumulate: this paper's synthesis conditions produced the same phase as that paper's computational prediction. This reviewer's objection was addressed by that experiment.

That's where a knowledge graph becomes valuable. Not blind LLM extraction — asking a model to "extract all entities" from a paper produces confident garbage. What works is curated, validated connections built incrementally. Each new paper, each new result gets integrated with human-in-the-loop validation. The graph grows as the research grows.

The distinction: graph RAG for single-document retrieval is usually overkill. Graph RAG as an epistemic knowledge web built over months of research — that's where it becomes worth the investment.

---

## The cage and the wind

Models get switched. Pricing changes, a new model drops with better structured output, an open-source option gets good enough for a subtask. Each time, it means rewriting prompts and fixing output parsing — unless the system is built for it.

The prompt is the cage geometry — it shapes the output. But real portability comes from treating LLM output as untrusted input.

- Expected a JSON object with specific fields? Parse it, validate the schema, check the types.
- Expected citations? Verify they reference real passages in the retrieved chunks.
- Expected a numerical comparison? Check that the numbers actually appear in the source material.

When validation fails, the system retries with a corrective prompt that includes the validation error. Self-correcting loops. In practice, most queries resolve in one pass. Some need two. When it takes three, the problem is almost always in the prompt design or the retrieval, not the model.

This leads to a useful model-agnostic metric: not "which model is best" but "how many correction cycles does this model need for this task." GPT-4 might need one cycle where Claude needs two, or vice versa, depending on the task class. The system handles both.

One observation: most open-source models share failure modes — they're fine-tuned from the same bases. A correction loop that handles Llama's JSON formatting quirks tends to handle Mistral's too. Build the cage right and the wind can change direction.

---

## How you deliver this matters

The obvious first move is a web app. Upload papers, ask questions, get answers. Fastest to ship, easiest to demo. For a lot of teams, it's the right choice.

But once the architecture is model-agnostic, it doesn't actually *need* to be centralized. The workspace, the agents, the retrieval layer — all of it can run on a researcher's machine or a lab's own infrastructure. That opens up delivery options worth considering.

### The options as I see them

| | **Web / SaaS** | **Editor (JetBrains / Cursor-style)** | **VSCode / Codium plugin** |
|---|---|---|---|
| **Where the workspace lives** | Cloud | Researcher's machine or lab infra | Researcher's machine |
| **Model inference** | Hosted endpoints | Local, lab cluster, or hosted — their choice | Same |
| **Data residency** | Provider-managed | User-managed | User-managed |
| **Git-backed tracking** | Possible but uncommon | Natural fit — queries, experiments, hypotheses all versioned | Same |
| **Lab equipment access** | Via API tunnels | Direct — instruments register as tools | Direct |
| **Distribution** | URL | Installer / package manager | Marketplace (shared across Codium-based editors) |
| **Trade-off** | Fastest to ship. Data residency is a conversation with every enterprise customer. | Most integrated, most opinionated. Bigger upfront investment. | Lowest barrier to adoption. Less integrated long-term. |

No single right answer:

- SaaS is simpler to operate
- An editor gives researchers a workspace that feels like *theirs*
- A plugin meets them where they already are
- Different labs, different constraints, different choices

The interesting observation is that model-agnostic design (the cage and the wind) is what makes these options possible at all. Once inference is swappable — hosted, self-hosted, open-source, Model Garden, whatever — the delivery question becomes about where the *data* lives, not where the *model* lives.

### What local delivery unlocks

**Git-based tracking.** When the workspace is local, versioning research artifacts in git becomes natural. Every query, experiment config, hypothesis — versioned. Branch a research direction. Diff two experimental setups. Revert a dead end. Researchers already think in version control for code; extending it to research is a small step.

**The device-driver pattern.** With local or lab-hosted infrastructure, physical equipment can connect directly. The framework defines the tool interface; labs implement the connector for their instruments — a synthesis furnace, an XRD machine, a spectrophotometer. Same interface as any other tool in the registry. This is harder to pull off through a cloud intermediary, though not impossible.

---

## Don't replace domain tools — compose with them

Every research domain already has validated tools:

- **Materials science:** Pymatgen, ASE, NIST-JANAF, AFLOW
- **Biotech:** BLAST, PDB, UniProt
- **Chemistry:** RDKit, Open Babel
- **Machine learning:** scikit-learn, PyTorch model zoos, HuggingFace

Researchers know and trust these tools. Building an LLM system that tries to replace them means reimplementing domain logic badly and asking an LLM to do math it will get wrong.

The better pattern: give the agent access to these tools. The LLM understands the question, picks the right tool, formats the input, interprets the output. The computation stays with code that's been validated by the domain for decades. Same for existing ML models — if a trained classifier or prediction model exists for a subtask, use it. The agent orchestrates; the specialists compute.

---

## A research framework you can actually build

The pattern that fell out of building this is domain-agnostic. What follows is the architecture — contracts, conventions, build order, and acceptance criteria. Pick your language, pick your domain. The shape stays the same.

### Input: domain configuration

Before building anything, define these for the target domain. Everything downstream depends on them.

| What | Example (materials science) | Example (biotech) | Example (ML research) |
|------|---------------------------|-------------------|----------------------|
| **Document formats** | Scientific PDFs, CIF files, VASP output | PDB files, FASTA, clinical trial PDFs | arXiv PDFs, Jupyter notebooks, model cards |
| **Domain tools** | Pymatgen, ASE, Materials Project API | BLAST, UniProt API, RDKit | scikit-learn, HuggingFace model hub, W&B API |
| **Domain ML models** | Crystal system classifiers, GNNs for molecular dynamics | Protein structure predictors, toxicity models | Benchmark evaluators, dataset quality scorers |
| **Lab equipment** | Furnaces, XRD, spectrophotometers | Sequencers, PCR machines, plate readers | GPU clusters, training pipelines, eval harnesses |
| **Domain-specific query patterns** | Chemical formulas (Li₂FePO₄), crystal notation | Gene names (BRCA1), protein IDs (P53_HUMAN) | Model identifiers, dataset names, metric names |
| **Validation rules** | Formation energy ∈ [-10, +10] eV/atom; temperature > 0K | Gene names match HGNC; dosage within safe range | Accuracy ∈ [0, 1]; loss is non-negative |
| **Experiment schema** | Hypothesis → synthesis params → characterization → result | Hypothesis → protocol → assay → measurement | Hypothesis → hyperparams → training run → eval metrics |

### Component architecture

```
workspace/
├── contracts/              ← message types, shared by all components
│   ├── messages            ← every inter-component interaction is a typed message
│   └── schemas             ← domain entity schemas (documents, experiments, graph nodes)
│
├── document_store/         ← ingest, parse, chunk, index
│   ├── parsers/            ← one parser per document format, registered by MIME type
│   ├── chunkers/           ← section-aware splitting (not blind fixed-size)
│   └── indexers/           ← progressive: raw → sectioned → embedded → fully indexed
│
├── retriever/              ← hybrid search across whatever indexes exist
│   ├── strategies/         ← fts, semantic, hybrid (RRF fusion)
│   └── domain_matcher      ← scores chunks using domain-specific logic
│
├── tool_registry/          ← domain tools, ML models, lab connectors — one interface
│   ├── tools/              ← each tool: name, description, input/output schema, handler
│   └── connectors/         ← lab equipment drivers (same tool interface)
│
├── experiment_tracker/     ← runs, parameters, results, lineage — git-backed
│
├── agents/                 ← long-running stateful processes
│   ├── supervisor          ← spawns, monitors, restarts, checkpoints
│   ├── research_agent      ← handles user queries, invokes tools
│   ├── indexer_agent       ← background progressive indexing
│   ├── experiment_agent    ← designs experiments, monitors runs, logs results
│   └── watcher_agent       ← monitors external sources for new documents
│
├── workspace_state/        ← shared blackboard
│   ├── documents           ← registry of ingested docs and their index tier
│   ├── history             ← query/response log with tool call traces
│   ├── experiments         ← run registry with full lineage
│   └── graph               ← knowledge graph: entities, relations, evidence chains
│
├── validation/             ← pure functions, no LLM calls, deterministic
│   ├── schema              ← does output match expected structure
│   ├── citations           ← does every claim trace to a source passage
│   ├── domain_rules        ← is output physically/logically plausible
│   └── experiment_safety   ← are params within safe bounds before reaching equipment
│
└── domains/
    └── {domain_name}/      ← all domain-specific config in one place
        ├── parsers         ← document format implementations
        ├── tools           ← tool registrations + connector configs
        ├── matcher         ← domain query pattern scorer
        ├── rules           ← validation rules + safety bounds
        └── experiment      ← what constitutes hypothesis, run, result
```

### Build order

Components have dependencies. Build in this order — each layer only depends on layers above it.

| Phase | Component | Depends on | Done when |
|-------|-----------|-----------|-----------|
| **1** | **contracts/** | Nothing | Message types defined for: tool_call/tool_result, retrieve/results, ingest/indexed, experiment_create/experiment_result, state_read/state_write. All components will import these. |
| **2** | **workspace_state/** | contracts | Can store and retrieve documents, history entries, experiment runs, and graph nodes/edges. Supports concurrent reads. |
| **3** | **validation/** | contracts | Each validator accepts output + rules, returns ok or error with details. No network calls, no LLM calls. Experiment safety validator rejects out-of-bounds parameters. |
| **4** | **document_store/** | contracts, workspace_state | Can ingest a file, run it through a parser, chunk it, and register it in workspace state. Progressive indexing: ingest returns immediately at tier 1, background jobs upgrade tiers. Search works against whatever tiers exist. |
| **5** | **retriever/** | contracts, document_store, workspace_state | Accepts a query and strategy (fts/semantic/hybrid). Returns ranked chunks with scores and source references. Domain matcher plugs in as a scoring function. |
| **6** | **tool_registry/** | contracts, validation | Tools register with typed schemas. Call dispatches to handler, validates output against schema. Lab connectors implement the same interface. Agent can list available tools and their descriptions. |
| **7** | **experiment_tracker/** | contracts, workspace_state, validation | Can create a run from a hypothesis + params, log results, trace lineage back to source hypothesis/papers/queries. Git-backed: each run is a commit, params are diffable. |
| **8** | **agents/** | Everything above | Each agent is a long-running process with its own lifecycle. Supervisor manages spawn/monitor/restart/checkpoint. Agents communicate through workspace_state, not direct calls. |

### Conventions

**Everything is a message.** Components never call each other directly. Every interaction — tool invocation, retrieval request, state update, experiment result — is a typed message on a bus. This maps to whatever concurrency model the language provides (actors, channels, async queues). The constraint: no shared mutable state between components, only messages. This is what makes the system distributable without a rewrite.

**Tools are the domain extension point.** A tool has: name, description, input schema, output schema, handler. The agent reads the tool catalog at runtime and picks tools based on descriptions and schemas — not hardcoded dispatch. Domain computation, ML models, and lab equipment all enter the system as tools. If a validated domain tool or model exists for a subtask, register it. The LLM orchestrates; specialists compute.

**Lab equipment follows the device-driver model.** The framework defines the tool interface. Labs implement the connector for their specific equipment — communication protocol, safety interlocks, data formatting. From the agent's perspective, measuring an XRD pattern and computing a phase diagram are the same operation: call a tool, get a result.

**Agents are stateful, long-running processes.** Not request handlers. Each agent maintains context across interactions — loaded documents, active hypotheses, running experiments. The agent loop: receive → classify intent → plan steps → execute (with validation at each step) → on failure, retry with corrective context (budget: N attempts) → accumulate results → update workspace state → respond. If an agent crashes, the supervisor restarts it from its last checkpoint. If an indexer dies mid-document, the research agent keeps serving from whatever tiers are already built.

**Experiments are first-class.** A run records: triggering hypothesis, parameters, tools called, data in, results out. Full lineage — traceable back through the graph to the papers and queries that generated the hypothesis. Git-backed: each run is a commit, params are diffable, branching an experiment direction keeps the history clean.

**The epistemic loop.** The knowledge graph grows through a cycle:

1. **Literature** → papers ingested, entities and claims extracted
2. **Hypotheses** → agents identify contradictions or gaps, propose testable hypotheses
3. **Experiments** → runs designed, lab connectors or simulation tools called
4. **Results** → outcomes validated and added as evidence
5. **Updated knowledge** → graph now contains empirical results alongside literature claims → new hypotheses emerge → repeat

The graph isn't a retrieval index. It's accumulated understanding — which claims have been tested, which hypotheses failed, which things were actually verified vs. only predicted.

**Validation is not optional.** Every agent step passes through validation. Validators are pure functions — deterministic, no LLM calls. Four categories: schema (structure), citations (grounding), domain rules (plausibility), experiment safety (bounds before reaching equipment). The correction loop feeds validation errors back as retry context. Experiment safety validation is the guardrail between an AI system and real equipment. No exceptions.

### Infrastructure mapping

The framework needs backing services. Start embedded, graduate to distributed.

| Concern | Dev (laptop) | Production |
|---------|-------------|------------|
| Message bus | In-process (language's native concurrency) | NATS, RabbitMQ, or Redis Streams |
| Document storage | Filesystem + SQLite | Object storage + Postgres |
| Search indexes | SQLite FTS5 + sqlite-vss (or pgvector) | Postgres tsvector + dedicated vector store |
| Agent runtime | Single process, multiple actors/goroutines/tasks | Distributed nodes (OTP, Ray, K8s pods) |
| Job queue | In-process task queue | Durable job queue (language-appropriate) |
| Experiment storage | Git + SQLite | Git + Postgres + object storage for artifacts |
| Model inference | API calls to foundation model providers | Self-hosted (vLLM, TGI), Model Garden, Azure ML, or local GPUs |

The message bus convention means moving from dev to production is configuration, not a rewrite.

### To configure for a new domain

1. Create `domains/{domain_name}/`
2. Implement parsers for the domain's document formats
3. Register domain tools and ML models in the tool registry
4. Write connectors for any physical equipment (same tool interface)
5. Implement a domain matcher for specialized query patterns
6. Define validation rules — both for agent outputs and experiment safety bounds
7. Define the experiment schema — what constitutes a hypothesis, a run, a result
8. Everything else — contracts, retrieval, agent lifecycle, progressive indexing, correction loops, workspace state, epistemic graph, git-backed tracking — is the framework

---

## What I'd tell someone starting this

- Start with the data pipeline, not the model. Parsing, chunking, indexing, retrieval — that's where the work is. The LLM call is one step in a twenty-step pipeline.
- Build correction loops from day one. If the system can't handle a malformed LLM response gracefully, it can't handle production.
- Measure retrieval quality separately from generation quality. When the answer is wrong, it's almost always because retrieval surfaced the wrong context, not because the model can't reason.
- Treat every shortcut as debt. Skipping the indexing pipeline feels fast until every query takes 30 seconds. Hardcoding prompts for one model feels easy until you need to switch. Building for one document format feels simple until researchers upload the weird one.

This post is the map. The territory is in the implementation.
