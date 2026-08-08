---
active: true
layout: group_index
title: "CodeKeyboard Rebuild Notes"
subtitle: "How a coder-friendly Android IME actually works, part by part"
date: 2026-08-08 08:00:00
background_color: '#1a1a2e'
group: keyboard
permalink: /keyboard/
---

<img src="/assets/keyboard/keyboard.png" alt="CodeKeyboard — split Sofle-inspired layout" style="max-width:100%;height:auto;display:block;margin:0 auto 1.5rem;">

Written so a human or an LLM can rebuild the keyboard without inventing APIs.

CodeKeyboard is a system Android keyboard (IME), not a text box demo — split Sofle-inspired layout, multiple layers, home-row modifiers, and on-device prediction that learns personal and mixed-script typing (Banglish included) without a server. These notes walk through the canvas rendering, composing/selection handling, the suggestion strategy stack, bigram prediction, fuzzy correction, and the build/CI/F-Droid pipeline — in the order the system actually depends on itself, not the order features got added.

Source: [github.com/ikouchiha47/codekeyboard](https://github.com/ikouchiha47/codekeyboard)
