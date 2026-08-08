---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 6: Fuzzy Correction, Emoji, Snippets, Trie Decay"
subtitle: "BEVA, emoji panel, snippets, WorkManager"
date: 2026-08-08 06:00:00
background_color: '#14213d'
---

## Spell correction / fuzzy fill

### ADR vs code

`docs/architecture/decisions/ADR-005-spell-correction.md` evaluates:

- Schulz & Mihov Levenshtein automata  
- Hanov 2011 DP-row DFS on a trie  
- BEVA (Zhou et al. 2016)  
- SymSpell (rejected: memory)  
- BK-trees (rejected)  

ADR accepts Hanov as v1. **Production path uses BEVA.**

`MergedSuggestionStrategy.fuzzyFill` calls `BevaTrieSearch.search` on `UserTrieAdapter` and `BaseTrieAdapter`.  
`FuzzyTrieSearch.kt` still implements Hanov DFS and is used in tests/benchmarks.

### When fuzzy runs

```kotlin
val exact = exactSuggest(prefix, k)
if (exact.size >= k) return exact
val threshold = FuzzyThreshold.forLength(prefix.length)
if (threshold == 0) return exact
// fill k - exact.size
```

```kotlin
// FuzzyThreshold
len <= 3 -> 0
len == 4 -> 1
else     -> 2
```

So fuzzy is not "only when exact is empty"; it fills remaining slots. Short prefixes skip fuzzy entirely.

### Ranking rule

Comment in Merged: collect **all** within threshold (Int.MAX_VALUE cap on search), then sort by edit distance, then longer common prefix with query, then frequency. Do not stop DFS early at `maxResults` if that yields alphabetical junk (historical bug).

BEVA sketch (from file header): per-node edit-vector bitmasks `evBits[e]`; transitions for match/sub/del/ins; prune when no reachable bits; terminal edit distance = min e with bit n set. Words up to length 30 fit in 32-bit masks.

## Emoji panel

### Data pipeline

`scripts/gen_emoji.py`:

- Source URL Unicode 15.0 `emoji-test.txt` (cached under `scripts/`)  
- fully-qualified only  
- skin tones stripped into `variants` under `base`  
- writes `android/app/src/main/assets/emoji.json`  

Measured size: 171457 bytes.

### UI

`EmojiPanelView.kt`, not `SuggestionBarView`.

IME:

```kotlin
// showEmojiPanel: build with kbHeight + nav padding, setInputView(emojiPanel)
// hideEmojiPanel: emojiPanel = null; setInputView(onCreateInputView())
```

Tap emoji: `currentInputConnection?.commitText(emoji, 1)`.

Focus (prevents IME dismiss):

```kotlin
descendantFocusability = FOCUS_BLOCK_DESCENDANTS
isFocusable = false
```

Category tab icons in companion `CATEGORY_ICONS` (Smileys, People, Animals, Food, Travel, Activities, Objects, Symbols, Flags, Component).

Height: `onMeasure` can lock to `fixedHeightPx` so the panel matches the keyboard slot; nav padding keeps content above system chrome. Several git commits were about panel height and tab layout.

## Snippets

`SnippetStore` object, SharedPreferences via `KeyboardSettings`, key prefix `snippet_`.

First run seeds empty: `em`, `ph`, `addr`, `me`, `gh`, `li` when `snippets_seeded` is false.

```kotlin
fun matching(prefix: String): List<String>  // expansions, max 3 non-empty
fun add(shortcode, expansion): Boolean     // validates ^[a-z0-9_]+$, no collide
fun update / delete / get / exists / all
```

IME: typing `;` starts composing with semicolon; suggestions from `SnippetStore.matching` instead of tries. Settings UI in RN writes the same prefs through the bridge.

## User trie overnight decay

Problem: unbounded `user.trie` after months of inserts.

`MainApplication.scheduleTrieDecay`:

```kotlin
Constraints.Builder()
    .setRequiresCharging(true)
    .setRequiresDeviceIdle(true)
    .build()
PeriodicWorkRequestBuilder<TrieDecayWorker>(1, TimeUnit.DAYS)
WorkManager.enqueueUniquePeriodicWork("trie_decay", KEEP, request)
```

`TrieDecayWorker`:

```kotlin
val trie = UserTrie.load(file)
trie.applyDecay(factor = 0.9, newEpoch = trie.decayEpoch + 1)
trie.save(file)
```

`UserTrie.applyDecay`: multiply terminal freqs by `0.9^deltaEpoch`, compact dead subtrees, recompute max freq, if `totalNodes > 50_000` rebuild keeping top 5000 words by frequency.

Typing path does not call decay. Session end only saves the trie as-is.

ADR-004 describes the same constraints and hard cap idea.

---

## Verification (part 6)

| Claim | Evidence |
|-------|----------|
| Production fuzzy is BevaTrieSearch | SuggestionStrategy.fuzzyFill |
| FuzzyThreshold 0/1/2 | FuzzyTrieSearch.kt object FuzzyThreshold; tests |
| Hanov still in FuzzyTrieSearch | file header + class |
| emoji.json from gen_emoji.py | script OUTPUT_FILE path |
| EmojiPanelView + setInputView | CodeKeyboardIME show/hide; EmojiPanelView |
| FOCUS_BLOCK_DESCENDANTS | EmojiPanelView init |
| Snippet defaults and regex | SnippetStore.kt |
| WorkManager charging+idle daily | MainApplication.kt |
| decay 0.9 and 50k/5000 cap | UserTrie.applyDecay / pruneToTop |
| emoji.json size ~171KB | measured |
