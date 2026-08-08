---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 3: Composing, Selection, Recompose"
subtitle: "Buffer, selection guard, recompose, enter"
date: 2026-08-08 03:00:00
background_color: '#0d0d0d'
---

## Why composing

`InputConnection.setComposingText(text, 1)` shows underlined in-progress text in many apps. `commitText` finalizes. Mid-word suggestions need a buffer the IME owns so a tap can replace the whole partial word. Without composing you only insert characters and scrape `getTextBeforeCursor` forever.

## ComposingBuffer

File: `ComposingBuffer.kt`

```kotlin
class ComposingBuffer {
    val text: String
    fun append(char: String): String
    fun backspace(): Boolean  // false if empty
    fun flush(): String       // return copy and clear
    fun setText(s: String)    // clear then append (recompose)
    fun clear()
}
```

No Android types. Unit-testable alone (`ComposingBufferTest.kt`).

## Character input (supportsComposing true)

In `handleKey` else-branch for character keys (simplified):

1. `text = kbState.resolveLabel(key)`
2. If single char and meta active (ctrl/alt/meta): flush composing, send key events with meta, `onCharCommitted`, return
3. If `text == ";"`: append, setComposingText, snippet suggestions
4. Else if length 1 and not punctuation: append, setComposingText, dictionary suggestions with `context = prevCommittedWord`
5. Else: flush, commitText
6. Always (for char path): `kbState.onCharCommitted()` and refresh key draw state

Punctuation set is a fixed char set in `CodeKeyboardIME` (period, comma, operators, quotes, etc.).

## Space

```kotlin
"space" -> {
    flushComposing(ic)
    ic?.commitText(" ", 1)
    val next = bigramModel.nextWords(prevCommittedWord, n = 5)
    if (next.isNotEmpty()) suggestionBar.update("", next)
}
```

## flushComposing

```kotlin
val word = composing.flush()
if (word.isNotEmpty()) {
    ic?.commitText(word, 1)
    wordLearner.learnFromFlush(word)
    kbState.onCharCommitted()
    // metrics...
    if (prevCommittedWord.isNotEmpty())
        bigramModel.recordTransition(prevCommittedWord, word)
    prevCommittedWord = word
}
keystrokesSinceCommit = 0
suggestionBar.clear()  // space path may refill immediately after
```

Note: the space handler calls flush (which clears the bar) then may show bigrams.

## onUpdateSelection

Problem: user taps elsewhere; composing region is stale; next char would replace the wrong span.

Also: IME calls that change selection must not look like user taps.

```kotlin
val imedriven = SystemClock.uptimeMillis() < expectSelectionUpdateBy
if (composing.text.isEmpty()) return
if (imedriven) return
// if cursor outside candidatesStart..candidatesEnd (or candidates unset):
ic.finishComposingText()
composing.clear()
suggestionBar.clear()
```

## Recompose after backspace into committed text

When composing is empty and backspace deletes one committed character:

1. `deleteSurroundingText(1, 0)` (or DEL key event fallback)
2. `recomposeWordAtCursor(ic)`

```kotlin
val before = ic.getTextBeforeCursor(RECOMPOSE_SCAN_CHARS, 0) // 50
val fragment = before.takeLastWhile { it.isLetterOrDigit() || it == '\'' }
// get absolute cursor via ExtractedText
expectSelectionUpdateBy = now + 500L
ic.beginBatchEdit()
ic.finishComposingText()
ic.setComposingRegion(absCursor - fragment.length, absCursor)
composing.setText(fragment)
ic.endBatchEdit()
suggestionBar.update(fragment, suggestionStrategy.suggest(fragment, 5, prevCommittedWord))
```

Tests: `BackspaceRecomposeTest.kt`. Debug logs used tag `CKB_COMPOSE` during development.

## Backspace order

1. Non-empty selection: batch finish composing, clear buffer, `commitText("")` to delete selection  
2. Else if `composing.backspace()`: update composing text + suggestions  
3. Else: delete surrounding + recompose  

## Enter

```kotlin
flushComposing(ic)
// if IME_FLAG_NO_ENTER_ACTION or action NONE/UNSPECIFIED -> KEYCODE_ENTER
// else performEditorAction(action), fallback KEYCODE_ENTER
```

Search/done fields need `performEditorAction`.

## onStartInput / onFinishInput

Start: set supportsComposing, clear composing and prevCommittedWord, finishComposingText, clear bar.  
Finish: finish composing, clear buffer/bar, `scheduleUserTrieFlush()` saves `user.trie`.

---

## Verification (part 3)

| Claim | Evidence |
|-------|----------|
| RECOMPOSE_SCAN_CHARS = 50 | CodeKeyboardIME companion |
| expectSelectionUpdateBy + 500ms | recomposeWordAtCursor |
| flush records bigram and WordLearner | flushComposing |
| space shows nextWords with empty word | handleKey "space" |
| ComposingBuffer API | ComposingBuffer.kt |
| Enter uses imeOptions mask | handleKey "enter" |
