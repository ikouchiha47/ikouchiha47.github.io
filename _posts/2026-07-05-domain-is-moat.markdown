---

active: true
layout: post
title: "Domain is Moat"
subtitle: "Why most generative AI products fail at the creator layer"
description: "Most teams treat prompts and models as the product. The real moat is understanding the domain deeply enough to build the right decision systems and feedback loops."
date: 2026-07-04
background_color: linear-gradient(135deg, #0f172a 0%, #1e2937 50%, #334155 100%)
---
I thought I'd be building AI systems

When I joined a startup building AI generated images and videos, I expected to spend my time solving difficult generation problems.

- Model routing.
- Evaluation.
- Fine tuning. (Although not my forte)
- Specialized pipelines.

Instead, I found myself building folders full of prompt templates.

```
experts/
    ecommerce/
      prompts.txt
    jewellery/
      prompts.txt
    watches/
      prompts.txt
    fashion/
      prompts.txt
```

To give credit where due, the `prompts.txt` is not a single file, but a structured set of files, which allows sharing of prompts, templating, and even versioning.

- Every feature meant adding another prompt.
- Every failure meant tweaking another prompt.

It worked well enough to ship products, but something felt fundamentally wrong.

Whenever I suggested evolving the architecture, the response was usually the same.

> "We're in a red ocean. We have to keep sailing."

I understood the business pressure. Speed matters.
But every week I became more convinced we were optimizing the wrong layer.

*Different products fail for different reasons.*

---

The first thing that bothered me was how differently models behaved across categories.

To humans, these prompts are obviously different.

- A pocket watch.
- A wrist watch.
- A wall clock.
- A handbag.
- A necklace.

To a diffusion model, they are simply distributions of pixels and language.

Sometimes that difference matters a lot.

I remember asking a model to generate a watch dangling from a pocket.

Instead of a pocket watch hanging from a chain, it generated something closer to a wall clock attached to clothing.

- The physics made no sense.
- The object relationship was wrong.
- Changing the wording to "pocket watch" suddenly produced much better results.

Interestingly, another model interpreted the original prompt correctly.

That was the moment something clicked.

**The problem wasn't just prompt engineering.**

Different models understood different concepts with different levels of accuracy.

A prompt isn't a strategy, if one is serious about making a business. Given the advent of agentic cli tools and cursor like editors, there is nothing preventing another person to replicate and refine prompts. 

The more categories I looked at, the more obvious it became.

- A watch fails differently from jewellery.
- Jewellery fails differently from clothing.
- Clothing fails differently from furniture.

Even within watches, a luxury wrist watch and an antique pocket watch have different visual expectations.

Yet our pipeline treated every request as the same problem.

- Take a prompt.
- Insert it into a template.
- Call the model.
- Hope for the best.

**That isn't really a generation strategy. It's a wrapper.**

The interesting work happens before generation. At some point I stopped asking,

"How do we write a better prompt?"

Instead I started asking,

"How do we decide what should happen before generation even begins?"

That completely changed how I thought about the system.

A user asking for an advertisement isn't really asking for pixels. They're describing intent.
- What are they selling?
- Who is the audience?
- Is this luxury?
- Is it fashion?
- Is it food?
- Does this become an image?
- A short video?
- A cinematic product showcase?

Those decisions shouldn't be hidden inside prompt text.
They should exist as first class components of the system.

I started imagining a team of specialists. Instead of one giant generation pipeline, I started thinking about specialists.

**Imagine a creative director instead of a prompt template.**

The director receives a request. The first decision isn't which prompt to use.

The first decision is which expert should handle the request.

- A jewellery expert.
- A fashion expert.
- A luxury goods expert.
- A food photography expert.

Each expert:
- Understands different failure modes.
- Choose a different model.
- Choose different generation parameters.
- Choose an entirely different pipeline.

Some categories might use a LoRA. Others might use a custom workflow. Others might rely on a different base model entirely.

The important part is that specialization becomes intentional instead of accidental.

**The router becomes the product**

---

### The Missing Creator Loop

There was one fatal flaw that no amount of clever routing or LoRA adapters could fix.

**We had no creators.**

Not a single person on the team regularly made marketing content for a living. We were a group of technical people trying to build a creative tool for a domain we didn’t deeply understand.

We assumed that if we built a good enough prompt-to-video system, creators would naturally come and use it. That was a serious mistake.

Professional short-form video is not a "write one good prompt" problem. It is a craft that involves:

- Understanding hook structures that work in the first 1-3 seconds
- Color grading and visual rhythm specific to the platform
- Pacing, cut timing, and visual storytelling
- Rapid iteration across dozens of variations
- Tight feedback loops between concept, generation, and editing

None of this was researched. There was no internal studio, no embedded creator, no regular user testing with actual marketing professionals. Even the one video specialist on the team refused to use the product.

We spent months building prose-mirror features and debating internal architecture while completely ignoring the fundamental truth: **if real creators won't use your tool to make their living, nothing else matters.**

The best generative media companies treat creators as the primary feedback mechanism from day one. We treated them as the last-mile problem.

This wasn't a technical failure.  
It was a **creator bankruptcy**.

---

People often say AI startups are just wrappers around foundation models.

They're usually right.

But I don't think the wrapper is the interesting part.

The interesting part is everything between user intent and the model call.

A good system might
- classify the request.
- Select the appropriate model.
- Choose a category specific adapter.
- Inject constraints, Run validation.
- Evaluate the output, and
- Record what succeeded.

> Over time, that decision layer becomes smarter. Not because the frontier models changed, because your system learned which decisions produce better outcomes.

*That is much harder to copy than a collection of prompts.*

---

This is where LoRA adapters become useful. LoRA is one piece, not the destination

- Not because every category needs fine tuning.
- Not because every model should have an adapter.

But because some domains genuinely benefit from specialization.

Imagine training adapters only on high quality examples for a specific category.

- One for watches.
- One for jewellery.
- One for cosmetics. etc.

Now the router isn't just choosing prompts. It's choosing expertise.

That expertise can evolve independently as new data arrives.

**Data becomes your advantage**

---

Every generation tells you something.

- Which model was used?
- Which adapter? and parameters?

- Did the user regenerate?
- Did they download it?
- Did they publish it or reject it?

Over time you stop collecting prompts. You start collecting decisions and outcomes.

That feedback loop becomes increasingly difficult for competitors to replicate because it reflects how your users actually create content.

---

## Looking back

When I first joined, I thought prompt engineering would be the interesting part of the job.

It wasn't.

The interesting part was realizing that prompts were only the visible surface of a much larger system.

The companies that survive won't win because they discovered the perfect prompt.

They'll win because they build better decision systems.

Foundation models will continue improving.

The real question is no longer which model you call.

It's how intelligently you decide to call it.
