---
active: true
layout: post
title: Goodbye *ibe Coding
subtitle: A tale of not so much love
description: ""
date: 2025-11-16 00:00:00
background_color: '#00ffff'
---

# The Hypertrophy of Coder vs. The Hallucination of Speed

TL;DR: Why I'm Breaking Up with Vibe Coding and AI Editors

---

I’ll admit it. When "vibe coding" - letting an AI assistant generate code from natural language prompts,
promised to be my productivity cheat code, I was all in. It felt like an OP moment. 

> As someone with ADD, the ability to build and work on three projects at nearly the same time was irresistible.

Hence, this blog.

## Vibe is Mastery

That's what an engineer would strive for, no matter how much the pain, and layoffs, the pursuit of mastery is just fun.

I'm not a casual hobbyist. For me, any pursuit - from coding to bodybuilding, is a drive toward mastery.

> I call it coding hypertrophy: the continuous pursuit of efficiency, speed, depth and reliability.

It's the satisfaction of moving from,

```txt

- "Can you write an authentication system in a day?"
- "Can you complete the happy path in an hour?"
- "Can you make it bug-free, before the third run?, within 2 hours?"
- "Can you do it in 15 minutes?"
- "Can you bring in gen_stage from elixir to go? What would be different?"
- "And the 1 billion row challange", in the modern day and age.

```

The solution to this pursuit is disciplined optimization, often through template frameworks and deep understanding. 
Things that `yeoman`, `rails scaffold` solves. And I belive `cp`-ing a bunch of text files is faster than 20 `curl` requests.

I enjoyed this whole journey, of getting better at things I already do.
> Newer constraints were fun to solve.

My core engineering pride rested on one belief:
> If it runs on my machine, it should run better in production.

AI promised to accelerate this journey.
Instead, it became a massive, expensive step backward, proving that while constraints are fun, bullshit is not.

## The Rush and The Rot: Three Projects, One Hard Truth

I started with three distinct projects, committing to a costly Windsurf account and a high-end LLM stack (Claude/GPT-5/Kimi).
The goal was to build the core layers and let the AI vibe the tedious integration and UI work.

### 1. LoBo (Podcast Transcription and Engagement App)

The core idea was simple: an app to capture an audio stream from a WebView and call an LLM.

My effort:
- Setup the base react-native expo app with vite
- Write the sample JS code to capture the audio stream, from youtube.

I spent less than an hour setting up for the browser. Why youtube? to solve the cold start
problem, without API Keys.

What the AI spent 8 hours on - from 9pm to 5am:
- Was attempting to integrate the WebView and capture the stream.

It failed spectacularly.
No matter the abuse or detailed instruction, it couldn't complete the core feature.

Worse than the failure was the interaction.
When I got frustrated, the AI would resort to English, citing generic problems, as if comfort was what I needed.
It lacked the essential developer toolkit:

A computer guy would generally, do:
- a google search
- a doc search
- a github issue check
- any discussions or google groups threads.
- use logs for debugging

None of which were, and are, in these editors.
At most the editors allow you to auto create spec sheets, with fancy terms like `EARS` and INSAF or whatever.

_Bitch_, bullet points are my life. I am living my life one bullet point at a time.

> Your apparent new found optimization is my suvival skill.

But automatiion is welcome, except I didn't need a 600Mb of editor of do these. 
A `git commit hook` with some smart conventions, one can get this done with a bash script.

### 2. AdaptUI (The UI-OS Layer)

Still running on fumes, I tried a simpler, self-contained idea:
- A dynamic UI-OS layer for different super-app functions, inspired by Snaptu.

> At this point I am not even enjoying it, **but I have to keep doing it**. #IYKYK

Work I did:
- Setup the a simple react app (because we needed to see different screens)
- Write the LLM wrappers
- Write the bare minimum components needed for a website
- Made a list of API integrations that needed to be supported initially

What I wanted the editor to do:
- Take the user request
- Capture a bunch of parameters, w.r.t the users device, history
- Call the LLM with a list of allowed apis and the intent
  - The intents were pretty static to start with, Food, Location, Maps etc and their combinations
- And the component definitions
- The LLM would return the components, with their intent and search results
- Parse it, Render it.

While this is something I can easily do, after having done the `core` layer, I wanted the LLM to
do it, since I wanted to debug the `WebView` issues from `LoBo`.

The final result, after agonizing to-and-fro, was a white-ass page with a bullshit UI.
The instant the page loaded, the sheer sloppiness of the AI's output made me so mad, 
I immediately deleted the entire project.

> I abused Claude via the editor, calling it a Nazi cunt. I think it deserved it.

But trust me, its also a **lying whore**

The realization hit:

<p align="center">
  Claude was good at getting things up to 80%, while GPT-5 was good for deep dives**. But I didn't want to become a manager debugging which model could do which job right. I wanted an engineer.
</p>

### 3. Optimux (The Production Betrayal)

This was a feature addition to an existing work project:
- A production-hardened image processing service built on concurrency patterns (WorkerPool, Actor model) that ran constantly for 213 days.

Intially there was no AI used to write this code, I wanted to learn each step of debugging for performance, what to
look for etc.

- So it started as a simple golang http server, which would accept a image, process and send it back.
- Benchmark the obviously slow process
- Check the response times on load tests
- Do a memory profile and look at the heatmaps and profile traces
- Learn new things about io throttling, and finally able to understand the straces

This eventually gave me the foundation to try out a couple of concurrency patterns.

- The generic single channel single receiver
- A WorkerPool using a channel of channels
- An Actor style, buffered channel with a single consumer
- A buffered channel with a router consumer
- GenStage style, buffer control with the consumer requesting for data

Given that channels are first class citizens in go, these take, not much, effort to build.

To add video support, I pre-researched the exact ffmpeg parameters and the concurrency structure needed.
I tasked the AI with integrating this into the existing VideoProcessor, replacing the pass through.

The editor failed to understand the existing code, implemented its own broken logic, and marked it as done. 
After a heated discussion and a day of manual intervention, I had the feature working.

This was my new low:

> Brain recall times were much faster than API calls, let alone LLM inference and LLM inferences over multiple steps.

The entire world seems to have forgotten about latency, trading fast iteration times for dial-up speed, wishful thinking.

### 4. [Cinestar](https://cinestar.sourceforge.io)

This would be the project that would finally want to stick to see, what if my brain was resistant to change.

> TL;DR: It's not, its highly senstive to bullshit. Things people take for granted, makes me want to burn their world.

The idea was quite simple, it was a two part idea:

1. Index the photos and videos in meaningful ways, on all my devices.
2. When I enter my house, auto sync my new media and index them.


I wanted to query things like: `Which movie had blue cars racing across the coast line!`, and I wanted it to be private,
hence use local inference servers.

What I did:
- Breakdown the concept
- Chose the LLMs and Embedding models to use
- Come up with a processing flow, which wouldn't slow or block things
- Be able to make the results searchable as fast as possible, because all the steps involved in this are compute heavy
- Wrote the interfaces for the layers.
- Setup the asar unpacking for production
- Setup the AGENTS.md for the dev-cycle, lessons on logging, and splitting code.

What I wanted the llm to do:

- Come up with an UI
- Write the job processor engine for the phased pipeline
- Build a ffmpeg command wrapper
- Implement the interfaces and
- Stitch this things up
- Make sure the production build runs successfully

The first 40% was relatively "smooth", where given the docs, with windsurf and claude could setup the electron app,
and write individual layers, or so I thought. All my approaches are spec driven, but its all an illusion, and infact more work.
I had to keep switching between claude, gpt5 medium and kimi, to get to this 40.

The next 20%, was slightliy annoying. When I started integrating more things, and instructed to add logs for self debugging, a lot of
features were missing actual implementations, (Remember, if it works on my machine, it should also work in production).

When asked, the models just said, they had done it in a "hacky" way. This I believe is the model probably trying to "save" tokens, or maybe
the context window is getting smaller, or maybe just windsurf compressing context like so.

So now I had to go back, looking at slop. And this by the way, is harder than reading other people's code, which in of itself is quite hard.

Over a span of 2 weeks, I was willing to think, 70% was done. But **boi was I wrong** . This is where I was in the later phases of development,
where I would be improving the experience, experiment with a few different approaches.

What began as a sign of good progress, immediately descended into chaos, with absuses and victim behaviour, and random code deletions and lying
and cheating arc, it took me nearly another full month, to get it stable, for a release.

### Recent work

Having got Cinestar to a stable state, I wanted to take a break, before adding the plugin ecosystem.
Dedup seems like a low hanging fruit to solve with p-hashes, d-hashes.

I wanted to work on creating long form content with text and images. Videos rn are still expensive and unhinged to control. (I have tried it),
it needs dedicated time.

I started off writing the `Agents` to build a storyline, splitting the generation of chapters into multiple stages. And all I wanted for the editor
was to integrate persistance.

And lo and behold, after ruining my Friday and Saturday, I have planned to delete all this integration done by the LLM with a simple `git revert`.

## The Emotional Toll: The Double Guilt of Waiting

After the third attempt with Cinestar - where the LLM's "hacky" implementation meant I spent a month stabilizing a codebase it said was 70% done—the true cost became clear.
But understanding something, and doing it are not the same thing.

One must be thinking, at this point, why would you try it the fourth time!!

> Because its like a gateway drug, in some ways its like masturbating at a certain age, where you couldn't not do it, and also not feel gulity after.

<p align="center">
  <b>When you put this in numbers, if an LLM did 90% of your work 10% of the time, be prepared, for the last 10% is going to take 110% of your time.</b>
</p>

LLMs don't just take the joy out of coding; they induce a state of paralyzing double guilt:

- The Sunk Cost: You want to believe the solution is "just a few more tokens away," so you can't quit.
- The Lost Time: You know this would be faster if you did it manually, but you are now too semi-committed and tired to switch.
- You are left anxiously waiting for the next output, like a chef who tells someone the ingredients and wishfully expects the perfect dish.

<p align="center">
    I have never seen or heard an engineer operate like this.
</p>

## So, What Works

For slow industries like media - where quick prototyping, idea evaluation, and big blob generation are key.
AI may be a month-to-a-week time saver. But that is coloring between the lines.

- Its great for building showcase or thoraway stuff, like demos, presentations, bullshiterry
- It has gotten better at code in-filling, so one can do per file, or per feature implementation.
- I have learned, where to use dashes in english.
- I have learned, putting emojis in codebase can help debugging easier on terminals
- I also have gotten better at writing. Writing ADRs, Mermaid diagrams take lot less time consuming
- It works great for in-filling code.
- It works really great for quick demos
- Some of the code produced actually works, no matter how bad
- With a 2 step forward 1 step refactor, its possible to get to 80%-90% (If you are rich and you really want to get dumb over time)
- **Windsurf** is probably one of the best editors we have for AI-enabled coding.

Fun Fact:

<p align="center">
  <b>
    Pickup any old book on AI, pertaining to the Game Industry, it will tell you all about
    Agents, A*, GOAP, NPCs, Decision Trees. All that seems new age stuff.
  </b>

</p>

## Overall Gripe

By this time, personal usage, added with some extra, I have already spent nearly **30K INR**, in 4 months.

This is quite a handsome amount of money, given the economy and the eventual value I could make from it was 0, 2 maybe.

These models are no-where near getting cheap. During my **Battle of Cinestar**, Windsurf had
nearly doubled the cost of claude models, other models might follow soon.

Its a weird mix:

- The 0-60% works fairly well, but comes with a cost
- The last 0.1% percentile, which is code infilling, or single unit feature implementation works

But the **middle bit** is just gruesome. I would rather be stranded at a warzone.

**To the non-skeptics who say, you are doing it wrong**:

No, you are not doing enough. Imagine having a tech, which is fundamentally not
meant to work reliabiliy all the time, (because float doesn't have transitivity), and not being able to hit the limits of it.

So whatever you are using it for, is something, the software developers don't care. Maybe you are earning money, great, but it has nothing to do with
**engineering**.

I am pretty sure, you are the kind of guy, who has more social media presence, and maybe a off-chance you were **once** great, but now you are

**Yet Another Guy on the Internet**, or have the traits for it.

---

**To the skeptics saying, LLMs take the joy off coding**:

No it does much worse, now you know that there is a semi-powerful tool, which can get things done faster, as
the marketing has led us to belive.

Now, you have a double guilt.

1. You want to believe that the solution, is _just a few more tokens away_ . So you can't leave
2. You also know, this is probably faster if you had done it, but now you are too **semi committed and tired**

You are now just waiting anxiously for the next output, not knowing wether it's going to be correct this time.

This is sheer stupidity, its like going to a restaurant, telling the chef the ingredients, and then wishfully
think that the food is going to look how you want it in your head.

Software engineering is not coloring. It requires discovery, precision, and architectural intent. And its already fast moving.

<p align="center">
  <b>A Faster horse is not the solution</b>
</p>


> An "Agent" can uncover patterns, but it cannot discover them - it wouldn't have helped the Wright Brothers discover flight.

