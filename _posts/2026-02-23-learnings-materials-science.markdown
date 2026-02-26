---
active: true
layout: post
title: "Learnings from Building LLM Systems"
subtitle: "What building an LLM-powered research platform actually looks like"
date: 2026-02-23 00:00:00
background_color: '#000'
---

My previous employment was at a company in the `Digital asset management` space, working on making short form commercial videos, towards the end.

One of the USP was, consistent character generation, which was until [Nano Banana](https://blog.google/technology/ai/nano-banana-pro/), and soon other mainstream models caught up. So the switch was to
generate short form commercial videos.
Once the shop closed, I spent time reflecting on how things went, and how the overlap landscape changes with AI in picture.
One of those thoughts gave birth to [krearts](https://github.com/ikouchiha47/krearts)

During the time I was also:

- Helping bootstrap an LLM-powered research platform for materials scientists.
  The kind where researchers upload papers, ask questions, and get structured answers with citations. Not a chatbot. A system.
- Was trying to make hot-chocolate, because 90% of hot chocolate served in Bangalore is either a middle-class bourvita drink with extra hot water,
  and the rest 10% adds a bunch of non-sense to hide their pathetic hot-chocolate.

This blog documents some of the observations, in building a research oriented framework, and my understanding of this space, apart from code.

---

## The GPT wrapper fallacy

When people see ChatGPT, Claude, Grok — the assumption is that building an LLM product is just API calls with a nice UI. Upload a PDF, call the model, return the answer. Ship it.

The gap between *using* these tools and *building with* them is massive.

Attachment parsing alone is a project. Scientific PDFs have multi-column layouts, inline equations, tables that span pages, figures with captions that reference other figures. Getting clean text out of that isn't `pdf2text`. It's a pipeline — layout detection, table extraction, figure-caption association, section boundary identification. And every format is different. A Nature paper looks nothing like an arXiv preprint.

Then there's retrieval. Without preprocessing and indexing:
- Every question re-parses everything from scratch.
- Every query pays the full cost of understanding the document.

The first prototype worked exactly this way - no tagging of sections, no embeddings, only enriched extractions.

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

**Reranking.** The initial retrieval casts a wide net. A reranker (cross-encoder or LLM-based) scores each chunk against the original question for fine-grained relevance. This is where you go from "related passages" to "the actual answer is in these three paragraphs."

> Reciprocal Rank Fusion (RRF) merges results from different retrieval methods into a single ranked list. The LLM then reasons over the top results instead of just returning links.

None of this retrieval composition is new. Google has done this for decades. The difference is composing these with an LLM reasoning loop instead of hand-tuned ranking signals. 

**What this replaces:**
Traditionally, doing this well meant deploying **Elasticsearch or Solr** — heavy infrastructure with its own operational cost, query DSLs, analyzers, synonym dictionaries, spell-check configs, and tokenizer tuning.

With an LLM and vector search, a lot of that goes away:

- **Spell correction, synonyms, query reformulation** — handled natively by the LLM. "therml stability" still matches "thermal stability" because the embedding is close enough, and the LLM rewrites the query anyway.
- **The search cluster itself** — a vector database (or even just `pgvector`) plus FTS on Postgres replaces what used to require a dedicated search deployment.

> The complexity of maintainance cost and migration costs, associated with elasticsearch, and its java baked ecosystem reduces to something much simpler - `GPUs`, `Database`, and `API calls`

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

This is the same pattern behind [Cinestar's](/2025/10/02/media-search.html) five-phase video indexing pipeline — make a video searchable the moment it's uploaded (phase 0, basic metadata), then progressively refine with multi-modal enrichment, coarse segmentation, fine segmentation, and cross-reference passes.

The domain is different but the architecture is identical: immediate utility, background refinement, each tier unlocking better search quality.

---

## Graph RAG — where it fits

Graph RAG has real value. But the costs are real too.

### Single document: usually not worth it

Building a knowledge graph over **one document** requires:
- Full entity extraction — identifying entities, properties, conditions, methods
- Relationship extraction between them
- Co-reference resolution
- Building a traversable graph

For a single document, this is expensive relative to the payoff. A well-chunked document with good metadata gets roughly 80% of the way there.

**The better alternative** — `section_covers`.

No matter how unstructured a PDF layout looks, the domain and the humans in it have a structure. Every scientific paper has an implicit hierarchy — title, abstract, hypothesis, methods, results, conclusion. The sections might be named differently, merged together, or split across pages, but the structure is always there. Researchers read papers this way instinctively.

The idea: teach the LLM this structure through the prompt, and have it classify each chunk during ingestion. The classification is an array — `["methods", "results", "datasets"]` — not a single label, because sections overflow. A "methods" section often contains datasets and preliminary results too.

**How the LLM knows the structure.** The agent prompt is hierarchically organized with custom tags — identity, capabilities, workflows, security, output rules — each scoped and nested. Within this, the paper-reading workflows define phased strategies:

- **Summarization:** extract six elements from any paper — hypothesis, claim, evidence, assumption, experiment, result — mapped to section types
- **Comparison:** compare across papers element-by-element, using section types as the navigation axis
- **Hypothesis generation:** scan → deep-read → synthesize, with section-aware retrieval at each phase

The `Researcher` agent, is given detailed instructions on how a "researcher" reads — which sections to check first for which kind of question, when to fall back to broader reading, how to cross-reference across documents.

At query time, filtering by section type is a simple indexed array lookup.
"Show me just the methods across these three papers" — no graph traversal needed. The LLM can then drive a ReAct loop to compare across sections, navigate the hierarchy, and synthesize — all without an entity graph.

### Across a workspace over time: where it shines

Researchers don't work with one paper. They work with a dozens of papers, experimental notes, simulation results, reviewer feedback. Over weeks and months, connections accumulate:
- This paper's synthesis conditions produced the same phase as that paper's computational prediction
- This reviewer's objection was addressed by that experiment
- This failed hypothesis ruled out a class of compositions

That's where a knowledge graph becomes valuable. **Not blind LLM extraction** — asking a model to "extract all entities" from a paper produces confident garbage. 

What works is:
- **Curated, validated connections** built incrementally
- **Human-in-the-loop validation** for each new paper and result
- The graph grows as the research grows

> Graph RAG for single-document retrieval is usually overkill. Graph RAG as an epistemic knowledge web built over months of research — that's where it becomes worth the investment.

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

## Video Generation, Spatial Awareness and Hot Chocolate

Foundational models are trained on a lot of data. The assumption is that because of how embedding spaces work, the LLM would be the one that sees all patterns — but more powerful.

Maybe it does. But what it does and doesn't depends on **how it was trained**. Combining different domains means mapping them to the same embedding space. General LLMs are not an answer to this.

### Domain knowledge has layers

In video generation, the underlying models have to be tweaked enough to guard how the LLM generates media. The nuances are real:

| Level | What it determines | Example |
|-------|-------------------|---------|
| **Macro** | Physics, environment, scene composition | Bags are not displayed the same way as watches |
| **Micro** | Audience, messaging, tone | A wrist watch is not advertised the same way as a wall clock. A mechanical watch is not advertised the same way as a quartz. |
| **Cultural** | Aesthetics, conventions, expectations | A Japanese website looks nothing like a US-built website. Japanese fashion magazines are structured for data extraction — what to wear, how to pair it, what it's for. |

LLMs tend to take the path of least work. Hence the need for detailed planning, guardrails, and extensive instruction following. If these foundational models had all this world knowledge baked in, why would anyone need custom embedding models?

> This sounds more like a Mixture of Experts, but constrained to a domain.

### LLMs lack spatial awareness

When working with non-textual data, it's fairly impossible for an LLM to predict things in real life. Back in very late 2025, none of the LLM models were consistently good at:
- Dynamic camera angles mid-scene
- Heavy action sequences — even something simple as parkour would fall apart
- Predicting anything that needs **visual cues or real-world feedback loops**

The failure has multiple layers, and it's well-documented:

- **Text encoders lose spatial information before generation even starts.** CLIP-based encoders (used in most diffusion models) establish representations in early layers and don't compose spatially. T5-based encoders (Imagen, DeepFloyd) do ~10% better because they process sequentially — but still fall short. ([Unlocking Spatial Comprehension in T2I Diffusion Models](https://arxiv.org/abs/2311.17937))
- **Training data rarely contains explicit spatial language.** Captions say "a dog in a park" not "a dog positioned 2 meters left of a bench." The models have minimal exposure to spatial relations like "inside", "below", "smaller than." ([Improving Explicit Spatial Relationships in T2I Generation](https://arxiv.org/html/2403.00587))
- **No internal 3D or physics model.** The generator learns statistical co-occurrence — "pocket" appears with "phone", "boombox" appears with "music player" — but never learns that a pocket has a fixed volume, or that an object must be smaller than its container.
- Ask an image model for "a big music player bulging in someone's pocket" — you'll get a person holding a boombox. It retrieved the strongest visual pattern for "big music player", never computed whether it fits inside the pocket.
- [T2I-CompBench](https://arxiv.org/abs/2307.06350) (NeurIPS 2023) confirms **spatial relationships are the weakest category** across all tested models. OpenAI's own [Sora technical report](https://arxiv.org/html/2402.17177v2) acknowledges failures in physics, causality, and left/right differentiation.

The precise term from the literature: **statistical co-occurrence without compositional constraint satisfaction**. The models know what things look like together, but can't enforce constraints between them.

> LLMs are probabilistic systems. `If you expect a probabilistic system to reliably (do X), it will probably, reliably (do X)`

### The hot chocolate test

GPT has a lot of information about how good hot chocolate is made. It can tell you how different countries and regions like theirs, **if you ask for it**. It has access to all kinds of recipes, ratings, discussions — enough for a fair idea.

But an LLM has never **seen or tasted** hot chocolate. It relies on what I call **"collective truth"**. So it can't accurately predict how changes in quantities lead to different taste.

This is the same with materials research — CHGNet and other tools provide contextual models with **computation baked in**, rather than an LLM trying to predict outcomes.

When I asked the LLM to adjust quantities for 4 people, the amount of water and sugar was way off from reality. **What actually worked:**
- The LLM knew the **desired result** of each step — "a creamy paste, not pudding-thick, but not watery"
- The LLM knew what **good taste means** (not going into the details of one-shot or ReAct)
- But it needed **real-world feedback** to get the quantities right

### The sensory gap

For automation, this means: as long as the LLM has access to eyes, ears and other senses into the real world, foundational models can actively guide towards real-life usable outcomes.

The same principles apply to sequential or batched image and video generation — with a corrective feedback loop. But costs shoot up.

_With enough effort — YOLO for vision, RPi Zero or ESP32 to capture images in batches, actual instruments and sensors providing continuous feedback — most real-life applications of AI will come when we add sensory elements to it. The LLM continuously validates against the desired outcome at each stage.
The easier version would be just to let an app do the compute_

---

## Shipping LLM Powered Apps

The obvious first move is a web app. Upload papers, ask questions, get answers. Fastest to ship, easiest to demo. For a lot of teams, it's the right choice.
But once the architecture is model-agnostic, it doesn't actually *need* to be centralized.

The workspace, the agents, the retrieval layer — all of it can run on a researcher's machine or a lab's own infrastructure. That opens up delivery options worth considering.

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

The interesting observation is that model-agnostic design (the cage and the wind) is what makes these options possible at all.

> Once inference is swappable — hosted, self-hosted, open-source, Model Garden, whatever — the delivery question becomes about where the *data* lives, not where the *model* lives.


In terms of business models, at the time of writing this, I see three prevalent ones.

1. That bets on the foundational model being better, using simple adapters, all forms of prompt and context engineering, to build a product.
2. The ones that are building their own foundational models, embedding models, ocr and other llm-ification of existing tools.
3. Using 2, or building 2, by providing narrow expertise in a certain domain. For example, Windsurf, has their own SWE models, we dont know if they will get better over time, beyond the foundational models
   But, companies like moonshot.ai , with `moondream`, gives us a pretty good idea, what a focussed model can do.
   The materials hypothesis engine, which uses `chgnet` and `gpaw` etc, to run actual predictions, and dft relaxation.


The 1st one however, would probably not survive, if it's not a niche the big players don't want to focus on, and public data is unavailable. Without a proper moat, the fear of being
invalidated or competitor proliferation is much higher. The DocuSign incident is a glaring example — OpenAI launched DocuGPT, and DocuSign's stock [dropped 17%](https://finance.yahoo.com/news/docusign-docu-falls-12-openai-044456722.html) overnight. Open-source alternatives like [OpenSign](https://www.opensignlabs.com/) and [Documenso](https://documenso.com/) were already circling.

When everyone has a gun, you need a bigger gun (leverage).


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

## Thoughts

Overall, as I understand, llm's use on textual data, is pretty limited use of this technology. Yes one can convert a natural language to an sql query.
The system you might have built, using agents and tools, to produce a valid grounded query, might as well be one shotable with a long enough context window.

So there isn't much inherent value in building such systems. Looking back, I realize, for sure, if an MVP or bootstrapped product, is headon with
existing features available on the available SaaS platform, and is presented to the users, the **in-evitable, un-avoidable and un-answereable question, how is that different from GPT**,
will be presented.

In all honesty, its probably not, because building a production grade ChatGPT like interface, with all the functionalities and edge cases take time.
It would be similar to asking `Build me Twitter`. _Sure, but why?_

> The users do not and should not care about such engineering challenges.

- Businesses should identify an actual gap or pain-point, which is much narrow, and yet generic enough for 10 people.
- Evaluate where in a LLM and its Senses are needed, if at all.
- Build on the narrow domain, and choose the pain points early on. Especially for bootstrap teams or startups, choosing the right battle is necessary

Chat becomes another interface to communicate with the system, much like REST. And hence the comparison against GPT or other models never come along.

Overall I dont feel like much has affected in terms of how one does business.
When the internet came along, there were loads of websites just built with no actual substance, and as time went by,
the web just became a medium or enabler for actual labour.

I think the same will happen for AI, most companies, whose identities are based around LLM will not survive in the end.
Anything and most things, that was generated or is one shotable by an LLM, will eventually get replicated and saturated.

So one way I guess could be to build wrappers very fast, on multiple domains. I mean, there are 100s and 1000s of n8n workflows,
skills, subagents, entire repositories of "leaked" prompts for agentic coding tools.

The only leverage these tools have is funding. If funding, networking and marketing were readily available, everyone could sell their own spinoff of `opencode`.
Which again is business as usual. There are a lot of twitter clones, and reddit alternatives, but the rate of success doesn't depend on just code execution.

> Code execution at base level has always been cheap. Especially in India, where culture is mostly managerial driven. CxOs all over the world, earn disproportionately more, not because they can write code.

And it's getting cheaper. Cross-provider deployment can be automated pretty easily now — Terraform, Pulumi, SST, whatever your flavor. Code generation is commoditized. Porting concepts from one language's ecosystem to another is a weekend project with a coding agent. Elixir's supervision trees in Go, Python's Ray actors in Rust, Ruby's convention-over-configuration patterns anywhere — the implementation barrier between "I know this pattern exists" and "it's running in my stack" has collapsed. Which means the moat is never in the code.


### Org changes

I don't think this is new practice now, but still to acknowledge, AI has caused some cultural shifts in org. It also has somehow set the wrong expectations from a lot of people.

Osho once said, "Democracy basically means government by the people, of the people, for the people — but the people are retarded." I think to some extent its terribly true. This is more prevalent and out in the world today
because of social media.

Only a handful of companies have presented their experiments as-is to the real world. Most lean into marketing — "LLM wrote a C compiler from scratch", "AI agents built an entire browser in a week."

To be fair, Anthropic did disclose costs for the C compiler — [$20,000 in API costs](https://www.anthropic.com/engineering/building-c-compiler), 2 billion input tokens, ~2,000 sessions. The compiler passed 99% of GCC torture tests. But $20K for a compiler that a senior engineer could write for less, and actually maintain afterwards — that's a question worth asking.

Cursor's [FastRender](https://www.softwareimprovementgroup.com/blog/quality-of-fastrender/) browser, on the other hand, produced 3 million lines of code — and scored 1.3/5 on maintainability (bottom 5% of all analyzed systems), had an 88% job failure rate, and recent commits [didn't even compile](https://www.theregister.com/2026/01/22/cursor_ai_wrote_a_browser/). The JS interpreter was hand-included, not AI-generated. No cost disclosure.

I don't blame anyone, everyone is doing their part to survive. Lets not forget such waves of `data science`, have already hit us before twice, and both times
the companies were all in losses.

So building a sustained customer facing model is a lot of pressure.

But you dont need to `XD`. It begins with educating everyone alike, juniors, seniors, management, stakeholders. 

An org should take the time in first doing a planned research on whats possible, to set the records straight. Some basic expectations on either end:

For developers it can be:
- using AI assist, to deliver faster.
- reduce tech debt, by being able to refactor or find patterns faster
- with some base setup, onboarding process can be smoothened a lot.
- using some spec based approach, with spec PRs, approved by peers or seniors.
- to build platforms which would allow non tech people to also be a part of the process, (versioning, access control etc)

For non developers, to understand:
- execution is cheap, and so you can build mockups, and iterate yourself, before handing off some idea
- if the platform supports, run your a/b tests with a small enough team, and iterate faster
- for managers, your code powered editor is more than enough to track developer task updates
- writing code is quite nuanced, when you think about LLM lies/hallucinations, bad instruction following, technical debts, corner cases, code quality
- Given that LLMs are not cheap, who gets how much token budget, when real pricings hit you.
- Think of the developers long term. Good software doesn't come from a better LLM, but a better person driving the LLM.
  Which you can see is totally in congruence with how just an LLM itself isn't enough to be a good product.

An LLM doesn't reduce the complexity of a business problem, if at all it increases some workload. Because now one has to think about how to bridge the probabilistic and deterministic parts.

An LLM does make you faster, but the quality of code, the philosophy, the foresight, doesn't come from the LLM.
A novice coder now produces more bad code, faster, and vice versa.

Its medically stupid, to make an LLM learn a very well established set of rules, and turn it into a probabilistic model in real life. Yeah, maybe it can be used to figure a better, faster, alternate way,
but the process of exploration can't be the way.

There is no point in making an LLM add two numbers, or add two numbers using a GPU consuming 16Amps.

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

## Testing from both directions

Not being a materials science expert meant there was no way to eyeball whether the system was producing good hypotheses. So the build happened in two directions simultaneously.

### Direction 1: Build the subsystems

Same approach as building a compiler — lexer, parser, codegen, each independently testable:

| Subsystem | What it does | Testable in isolation? |
|-----------|-------------|----------------------|
| Document pipeline | Parse, chunk, index scientific PDFs | Yes — output is structured text, verifiable |
| Retrieval | Hybrid search across indexed papers | Yes — relevance scoring against known queries |
| Domain tools | CHGNet, GPAW, materials databases | Yes — known inputs, known outputs |
| Agents | Orchestrate tools, maintain context | Yes — given fixed retrieval, does the plan make sense |
| Experiment runner | Execute computational experiments | Yes — scripts produce reproducible results |

Each piece could be validated without domain expertise. The document pipeline either extracts tables correctly or it doesn't. CHGNet either returns a valid energy prediction or it doesn't.

### Direction 2: Build the evaluation

The harder question: **does the whole system, end-to-end, produce hypotheses that are actually good?**

The approach:
- Pick a **resolved scientific controversy** with a known outcome (LK-99 superconductivity)
- Build the paper chain **without** the final resolution paper
- Feed the incomplete chain to the system **in a conversational pattern** — not "tell me the answer", but the way a researcher would actually explore: "what are the competing claims?", "what experiments would resolve this?", "which hypothesis has the strongest evidence?"
- Score the generated hypotheses against the withheld paper

The conversational pattern matters. A direct request — "what caused the LK-99 results?" — would test whether the model memorized the answer. A conversational exploration tests whether the *system architecture* can guide reasoning through literature, contradictions, and evidence toward a defensible hypothesis.

The hypothesis engine was essentially reverse-engineered from this evaluation. The question "how do you know if it's any good?" shaped every architectural decision — what agents exist, how they communicate, what tools they call, how hypotheses get ranked.

### Testing probabilistic systems

This evaluation approach generalizes. Once tests exist for LLM-driven workflows, they become a model selection ground — run the same test suite against different models, collect golden results, compare.

But testing probabilistic systems is fundamentally different from testing deterministic code. Three patterns that worked:

**1. Black box / outcome-only testing**

Treat the LLM like a private method. Don't assert on internal reasoning. Only check:
- Did the output match the expected schema?
- Did citations reference real passages?
- Did domain values fall within valid ranges?

This is the most robust approach — it survives model swaps without rewriting tests.

**2. Value-in-collection assertions**

When the output should contain specific elements but order doesn't matter:
- Assert that key entities appear in the extracted list
- Assert that required sections are covered
- Assert that tool calls include the expected tools

Not "the answer is X" but "the answer contains X, Y, Z."

**3. Workflow / DAG testing**

A goal can have multiple valid pathways, even with cycles. But:

| What stays the same | What can vary |
|---------------------|---------------|
| The set of nodes visited | The order of traversal |
| The final memory state | The number of correction cycles |
| The tools invoked | Which tool was called first |
| The types of intermediate results | The exact values |

Test the DAG shape, not the exact path. If "retrieve → extract → validate → synthesize" is the expected workflow, assert that all four steps happened and the memory state after each step contains what downstream steps need. The path between them — whether the agent took one cycle or three, whether it backtracked — is the probabilistic part. The nodes and final state are the deterministic contract.

This turns model comparison from "which one feels better" into "which one reaches the same nodes in fewer cycles, with fewer validation failures."

---

## What I'd tell someone starting this

- Start with the data pipeline, not the model. Parsing, chunking, indexing, retrieval — that's where the work is. The LLM call is one step in a twenty-step pipeline.
- Build correction loops from day one. If the system can't handle a malformed LLM response gracefully, it can't handle production.
- Measure retrieval quality separately from generation quality. When the answer is wrong, it's almost always because retrieval surfaced the wrong context, not because the model can't reason.
- Treat every shortcut as debt. Skipping the indexing pipeline feels fast until every query takes 30 seconds. Hardcoding prompts for one model feels easy until you need to switch. Building for one document format feels simple until researchers upload the weird one.

This post is the map. The territory is in the implementation.
