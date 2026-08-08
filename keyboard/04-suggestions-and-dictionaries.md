---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 4: Suggestion Bar, Strategy Stack, Tries, Learning"
subtitle: "Bar, strategy stack, TRIF, TRIE3, WordLearner"
date: 2026-08-08 04:00:00
background_color: '#1b263b'
---

## Why the bar is Kotlin

ADR-003: RN never sees IME `commitText`. A JS bar bound to local `text` state does not update in IME mode. Latency across the bridge is the wrong model for every keypress.

Shipped UI: `SuggestionBarView` in `onCreateInputView`, above `NativeKeyboardView` in a vertical `LinearLayout`.

## SuggestionBarView behaviour

File: `SuggestionBarView.kt` - `HorizontalScrollView` + row of `TextView`s.

```kotlin
fun update(word: String, suggestions: List<String>) {
    if (word.isEmpty()) {
        // next-word mode after space
        if (suggestions.isEmpty()) { clear(); return }
        rebuildSlots(suggestions, dp)
        return
    }
    val items = mutableListOf(word) + suggestions.filter { it != word }
    rebuildSlots(items, dp)
}
```

Slot 0 (when composing): typed word, accent color, tap confirms as-is.  
Further slots: suggestions.  
Empty word: bigram next-words only.

ADR-003 still says "three fixed slots". Code is a scrollable list. Prefer code.

## Strategy stack

Interface:

```kotlin
interface SuggestionStrategy {
    fun suggest(prefix: String, k: Int, context: String = ""): List<String>
}
```

### MergedSuggestionStrategy

1. `exactSuggest`: userTrie.suggest then baseTrie.suggest, user first, dedupe, take k  
2. If exact.size >= k, return  
3. `threshold = FuzzyThreshold.forLength(prefix.length)`; if 0 return exact  
4. `fuzzyFill` via **BevaTrieSearch** on both tries (see part 6), merge, sort, fill remainder  

### BigramAwareSuggestionStrategy

```kotlin
val baseResults = base.suggest(prefix, k + 5)
if (context.isEmpty()) return baseResults.take(k)
val bigramMatches = bigram.nextWords(context, prefix = prefix, n = k)
return (bigramMatches + baseResults.filter { it !in bigramMatches }).take(k)
```

Built once in `onCreate` as BigramAware(Merged(user, base), bigramModel). No runtime strategy enum.

### Snippet intercept

Before dictionary suggest, if composing text starts with `;`, IME uses `SnippetStore.matching(word.drop(1))` instead.

### Suggestion tap

```kotlin
ic.commitText("$word ", 1)
composing.clear()
wordLearner.learnFromTap(word)
// bigram transition, prevCommittedWord = word
val next = bigramModel.nextWords(word, n = 5)
// update bar or clear
```

## Base trie (TRIF)

Asset: `android/app/src/main/assets/en.trie`

Build: `tools/build-trie.js`  
Tests that document the layout: `__tests__/trie.test.js`

Format (from build script header + tests):

- Magic ASCII `TRIF` (4 bytes); nodeCount u32 LE at offset 8; header size 12  
- Node 12 bytes: char u8, flags u8, childrenOffset u32 LE, frequency u32 LE, reserved u16  
- flags: bit0 = isEnd, bit1 = hasChildren  
- Child block: count u8, then entries of 4 bytes (char u8 + index u24 LE)  
- childrenOffset in node is relative to start of child section (Kotlin adds `childrenBase`)

Input lines: `word\tfrequency` or word alone (freq 1). Lowercase a-z, length 2..20.

Kotlin `Trie.kt`:

- `load(context)` reads asset bytes  
- Accepts TRIF or legacy TRIE2 (8-byte nodes, freq 0)  
- `suggest(prefix, max)` walks prefix, DFS collects terminals with non-empty suffix, sorts by frequency desc  

Measured on this tree: file size 2316326 bytes, magic TRIF, nodeCount 136254.

## User trie (TRIE3)

Files: `UserTrie.kt`, `TrieWriter.kt`, path `filesDir/user.trie`

Not the same binary as TRIF. Magic int `0x54524933` ("TRI3"). Nodes carry frequency, maxDescendantFreq, lastDecayEpoch; header has decayEpoch.

`suggest`: best-first priority queue on maxDescendantFreq, prune when bound <= floor of k-th result. Design notes in `docs/plans/plan-phase5-user-trie.md` (Hsu/Ottaviano completion trie, PruningRadixTrie).

`insert` increments terminal frequency and updates maxDescendantFreq along the path.

Persist: `onFinishInput` -> executor -> `userTrie.save(file)` (write `.tmp`, rename).

## WordLearner

```kotlin
fun learnFromFlush(word: String) {
    if (!isLearnable(word)) return
    if (!dictionary.isKnownWord(word)) return
    userTrie.insert(word)
}

fun learnFromTap(word: String) {
    if (!isLearnable(word)) return
    userTrie.insert(word)
}

private fun isLearnable(word: String) =
    word.length > 1 && !word.startsWith(";")
```

IME passes base-dict check as: `trie.suggest(word, 1).firstOrNull() == word`.

`WordLearnerTest` covers: known flush learns, unknown flush does not, tap learns OOV, `;` and length-1 rejected.

Do not reimplement as "learn every space commit" or the user trie becomes a typo log.

---

## Verification (part 4)

| Claim | Evidence |
|-------|----------|
| HorizontalScrollView bar | SuggestionBarView class declaration |
| update empty-word branch | SuggestionBarView.update |
| Merged uses BevaTrieSearch | SuggestionStrategy.kt fuzzyFill |
| BigramAware promote order | BigramAwareSuggestionStrategy |
| TRIF magic and sizes | build-trie.js; trie.test.js; file bytes |
| TRIE3 separate | TrieWriter MAGIC; UserTrie |
| WordLearner flush needs known word | WordLearner.kt + WordLearnerTest |
| user.trie flush on finish | scheduleUserTrieFlush |
| en.trie ~2.2MB, 136254 nodes | measured assets |
