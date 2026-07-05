---
active: true
layout: post
title: "Stop shipping prompt templates"
subtitle: "Category-aware routing, LoRA adapters, and the generation layer that compounds"
description: "Most generative ad platforms are thin wrappers over third-party models. A lightweight classifier + router + per-category LoRA adapters gives you actual ownership of the output strategy."
date: 2026-07-05 21:00:00
background: 'blue'
---

# The wrapper trap

I joined a generative media startup expecting to work on real architecture decisions. What I found was a fixed set of hand-written prompt templates for a handful of ad types, sitting in front of Flux or GPT-image. No routing. No model selection. No adaptation to what was actually being generated.

That approach is fundamentally limited. It is not a moat. It is a demo that someone else can replicate in a weekend.

The problem is not the models. The problem is treating every generation request as the same problem.

# Categories break models in different ways

A watch hanging from a pocket fails differently than a piece of jewellery or a bag. Diffusion models struggle with object relationships, scale, material properties, and occlusion. These failure modes are not uniform across product categories.

- A watch requires precise attachment geometry and realistic chain physics.
- Jewellery needs accurate metal reflectance and small-detail preservation.
- Clothing involves fabric deformation, drape, and body occlusion.

One prompt template cannot handle all three without constant firefighting. The model does not know which failure mode it is in. It just generates.

Video makes this worse. Image-to-video coherence, audio-video sync, non-abrupt cuts, and transitions are real, hard problems. One company (Higgsfield) built an entire business just on transitions and effects. Most teams treat these as afterthoughts that a general pipeline will solve for free. It does not work.

# What actually owns the generation strategy

The defensible work is what sits between the user's raw intent and the model call. Three layers:

1. **Classification layer** — lightweight model or heuristic that identifies product category, intent type, and any constraints (aspect ratio, brand palette, output length).

2. **Routing layer** — decides which base model, LoRA adapter, generation parameters, and post-processing pipeline to use. This is conceptually a mixture-of-experts router, though not in the model-architecture sense.

3. **Prompt middleware + adapter layer** — translates the classified intent into category-specific prompts, injects constraints, and applies a LoRA adapter fine-tuned on "golden" examples for that category.

Do this well and you stop being a wrapper. You start owning the adaptation logic that improves with usage data.

# Why LoRA is the right tool here

Full fine-tuning per category is expensive and slow. LoRA adapters are small, cheap to train, and can be swapped at inference time without reloading the base model.

- Train one adapter per category on 200–500 high-quality examples that actually performed well.
- Keep the base model frozen. Only the adapter weights change.
- At inference, the router picks the adapter (or none) based on the classification.
- You can run multiple adapters in parallel and A/B test them.

The data you collect — category, prompt, model, adapter, user rating or downstream metric — becomes the real asset. It tells you which adapter wins for which subcategory. That dataset is hard to replicate because it is tied to your actual usage patterns.

# What "golden metrics" look like per category

You need a way to judge success that is not just "the user liked it." For each category, define 2–3 observable signals:

- Watch category: chain attachment success rate, correct scale relative to pocket, metal reflectance score from a small vision model.
- Jewellery: detail preservation on small elements, correct metal type (gold vs silver reflectance), no floating components.
- Clothing: fabric drape realism, body occlusion handling, no distorted limbs or missing buttons.

These are not subjective. They are measurable. You log the generation, run the checks, and feed the result back into the router. Over time the router learns which adapter + parameter set produces the highest golden metric score for each category.

# A minimal implementation sketch

Start simple. You do not need a full MoE model.

```python
# pseudocode, not production
class GenerationRouter:
    def __init__(self):
        self.classifier = load_lightweight_classifier()  # e.g. DistilBERT or even regex + heuristics
        self.adapters = {
            "watch": load_lora("watch_v1"),
            "jewellery": load_lora("jewellery_v2"),
            "clothing": load_lora("clothing_v1"),
        }
        self.metrics = load_golden_metrics()

    def generate(self, prompt, user_context):
        category, intent = self.classifier.classify(prompt)
        adapter = self.adapters.get(category)
        params = self.metrics.best_params(category, intent)

        result = call_model(
            prompt=self.middleware.rewrite(prompt, category),
            adapter=adapter,
            **params
        )

        score = self.metrics.evaluate(result, category)
        self.metrics.log(category, params, score)
        return result
```

The middleware layer is where you do the category-specific prompt rewriting:

```python
# middleware.py
def rewrite(prompt, category):
    if category == "watch":
        return f"product photography of a {prompt}, precise chain attachment, realistic pocket interaction, macro detail, commercial lighting"
    if category == "jewellery":
        return f"close-up of {prompt}, accurate metal reflectance, small detail preservation, no floating elements, studio lighting"
    ...
    return prompt
```

You start with two or three categories that show clearly divergent failure modes. Build the classifier first. Log everything. Add adapters only after you have data showing one strategy beats the others on your golden metrics.

# The data flywheel

Usage data → better classification → better adapter performance → higher retention in the categories that actually use you → more data.

Static prompt templates do not improve with usage. They just sit there. Every generation is a cold start.

A router + adapter system gets better the more you use it. The router learns which adapter wins for each subcategory. The adapters themselves can be retrained on your own high-scoring outputs. This compounds.

If you are still shipping the same prompt templates you wrote in month one, you are not building a product. You are maintaining a demo that someone else can replace the moment they point a similar set of templates at the same APIs.

Own the routing and adaptation instead.
