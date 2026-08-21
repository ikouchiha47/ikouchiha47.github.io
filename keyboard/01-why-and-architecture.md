---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 1: Why, and the Three Layers"
subtitle: "Motivation, layers, IME registration, composing flag"
date: 2026-08-08 01:00:00
background_color: '#1a1a2e'
---

## The problem

A phone keyboard for programmers has two things working against it at once: there's only a thumb's reach of screen, and programmers need a denser, weirder set of characters than anyone texting in plain English — brackets that have to nest correctly by feel, modifiers, symbols that don't fit on a QWERTY row without a second thought.

The standard fix is "add a symbols page." That doesn't actually solve the problem — it just moves the cost from *not enough keys* to *not enough taps to reach the key you need*, mid-sentence, while you're trying to close three brackets in the right order. The real fix has to change how many things one physical key can mean, not how many pages of keys exist.

## The constraint that shapes everything else

There's a second problem underneath the first one, and it's not about keys at all: an Android keyboard never actually touches the app it's typing into. It doesn't see the host app's text field, doesn't get to reach into its view tree. Every keystroke has to go out through a narrow, fixed protocol — `InputConnection` — methods like `commitText`, `setComposingText`, `deleteSurroundingText`, `getTextBeforeCursor`. That's the whole vocabulary. Anything the keyboard wants to do (autocorrect, undo a suggestion, show a word mid-edit with an underline) has to be expressible in that vocabulary, or it doesn't happen.

That's why CodeKeyboard isn't a UI overlay drawn on top of a text box — it's a Kotlin `View` rendered on a `Canvas`, running inside Android's `InputMethodService`, talking to the host app only through that one narrow channel. The launcher app (React Native — settings, themes, snippet management) is a separate process that never touches a keystroke. The keys you actually type on are not RN views; RN can't reach across that `InputConnection` boundary fast enough to matter, and doesn't need to.

## Answering the actual problem: layers, not pages

Given those two constraints — limited space, and a fixed narrow protocol to the outside world — the fix is to let each physical key mean something different depending on which *layer* is active: base, shift, symbol. Not extra pages to swipe to; a held or latched state that changes what the next tap produces. `KeyboardState` tracks this as a plain string (`layer`), with a small state machine (`TapMachine`) deciding whether a modifier press is a tap, a hold, or a latch — because on a small touch target, those three are genuinely ambiguous, and getting that wrong makes every key second-guess the user. That state machine is worth its own part later.

One place this boundary actually leaks into visible behavior: not every field wants a composing region. Password fields, numeric fields, and raw terminal-style inputs (Termux, for instance) either can't or shouldn't get the underlined "still typing this word" treatment — so `CodeKeyboardIME` checks the field type on `onStartInput` and turns composing off for those, falling back to committing characters directly. It's a small check, but it's the kind of detail that only becomes obvious once you've internalized that the keyboard doesn't know what app it's in — it only knows what the field *declares itself to be*.

## Three Layers

```
Launcher app (React Native)
  settings, themes, snippet management, preview keyboard
        |
        |  optional bridge (layout JSON, snippets, settings)
        v
IME process (Kotlin)
  CodeKeyboardIME
  NativeKeyboardView, KeyboardState, ComposingBuffer
  LanguagePack (en.cklm -- vocab, char-trie, n-gram trie, phrases)
  WordDictionary, UserTrie          -- prefix + fuzzy completion
  PackBackedBigramModel             -- static pack seed + user decay layer
  PackNgramModel (bigram/trigram)   -- context-keyed follower lists
  SuggestionStrategy, SuggestionBarView, EmojiPanelView
        |
        |  InputConnection only
        v
Host app field
```
