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

## Why this exists

CodeKeyboard is a system Android keyboard (IME), not a text box demo. The layout is Sofle-inspired: split halves, column stagger, multiple layers, home-row modifiers. The point is coder-friendly modifiers and layers on a phone, plus prediction that can learn personal and mixed-script typing (for example Banglish) without a server.

React Native is still in the repo for the launcher app: settings, themes, snippet management, layout preview. The keys you type with in other apps are not RN views. They are a Kotlin `View` subclass drawn on a `Canvas` inside `InputMethodService`.

`docs/architecture/overview.md` still draws RN as transitional and lists an older component set. Treat that diagram as direction, then read the Kotlin package for what runs today.

## Three layers

```
Launcher app (React Native)
  settings, themes, preview keyboard
        |
        |  optional bridge (layout JSON, snippets, settings)
        v
IME process (Kotlin)
  CodeKeyboardIME
  NativeKeyboardView, KeyboardState, ComposingBuffer
  Trie, UserTrie, BigramModel, SuggestionBarView, EmojiPanelView
        |
        |  InputConnection only
        v
Host app field
```

You never find the host `EditText` in the view tree. You only use `InputConnection` methods: `commitText`, `setComposingText`, `finishComposingText`, `deleteSurroundingText`, `sendKeyEvent`, `performEditorAction`, `getTextBeforeCursor`, and so on.

## Register the IME

`android/app/src/main/AndroidManifest.xml`:

```xml
<service
    android:name=".CodeKeyboardIME"
    android:label="@string/ime_name"
    android:permission="android.permission.BIND_INPUT_METHOD"
    android:exported="true">
  <intent-filter>
    <action android:name="android.view.InputMethod" />
  </intent-filter>
  <meta-data
      android:name="android.view.im"
      android:resource="@xml/method" />
</service>
```

`res/xml/method.xml` points settings at `.MainActivity`. After install the user must enable the IME in system settings. That is normal Android.

## What ships vs what ADRs name

| ADR name | Shipped reality |
|----------|-----------------|
| `TextInputConnection` (ADR-001) | Designed; tests have `FakeTextInputConnection`. Live IME mostly uses `currentInputConnection` directly. |
| `ComposingEngine` (ADR-002) | Shipped as small `ComposingBuffer`; IME owns flush/recompose/suggestion calls. |
| IME uses ReactSurface (`CLAUDE.md`) | **Stale.** IME input view is `NativeKeyboardView` + `SuggestionBarView`. No `ReactSurface` reference in Kotlin sources. |

## supportsComposing

Set in `CodeKeyboardIME.onStartInput`:

```kotlin
supportsComposing = when {
    editorInfo == null -> false
    editorInfo.inputType == InputType.TYPE_NULL -> false
    isPasswordField(editorInfo) -> false
    isNumericField(editorInfo) -> false
    else -> true
}
```

- `TYPE_NULL`: terminals / raw key hosts (for example Termux).
- Password variations: no underlined composing.
- Number, phone, datetime classes: direct commits.

When false, characters go through `commitText` (or key events) without building a composing region the same way.

## onCreate wiring (preview of later parts)

```kotlin
trie = Trie.load(this)
userTrie = UserTrie.load(File(filesDir, "user.trie"))
bigramModel = BigramModel(this).also { it.load() }
suggestionStrategy = BigramAwareSuggestionStrategy(
    MergedSuggestionStrategy(userTrie, trie), bigramModel)
wordLearner = WordLearner(userTrie) { word ->
    trie.suggest(word, 1).firstOrNull() == word
}
```

That single stack is the whole suggestion product: user trie, base trie, fuzzy fill inside Merged, bigram promotion outside.

---

## Verification (part 1)

| Claim | Evidence |
|-------|----------|
| IME is `CodeKeyboardIME : InputMethodService` | `CodeKeyboardIME.kt` class line |
| Manifest BIND_INPUT_METHOD + method.xml | `AndroidManifest.xml`, `res/xml/method.xml` |
| No ReactSurface in Kotlin | repo grep: only `CLAUDE.md` mentions it |
| supportsComposing branches | `CodeKeyboardIME.onStartInput` |
| Strategy construction | `CodeKeyboardIME.onCreate` |
| ComposingBuffer not ComposingEngine | `ComposingBuffer.kt` exists; no ComposingEngine.kt |
