---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 7: Build, CI, F-Droid, Future Work"
subtitle: "Assets, tests, CI, F-Droid, roadmap"
date: 2026-08-08 07:00:00
background_color: '#101820'
---

## Asset pipeline

| Output | Command / source |
|--------|------------------|
| `assets/en.trie` | word list -> `node tools/build-trie.js` (see script header for `gen_wordlist.py` pipe) |
| `assets/bigrams.json` | `python3 scripts/extract_bigrams.py --input count_2w.txt --output android/app/src/main/assets/bigrams.json` |
| `assets/emoji.json` | `python3 scripts/gen_emoji.py` |

Measured sizes on this tree:

| File | Bytes |
|------|------:|
| en.trie | 2316326 |
| bigrams.json | 633187 |
| emoji.json | 171457 |

Runtime-only:

| File | Role |
|------|------|
| `filesDir/user.trie` | TRIE3 learned words |
| `filesDir/user_bigrams.json` | v2 user bigrams |

## Local APK

```bash
cd android && ./gradlew testDebugUnitTest assembleRelease --console=plain
# APK: app/build/outputs/apk/release/app-release.apk
```

Version in `android/app/build.gradle` (verify when you release; do not trust stale docs):

- `versionCode 9`
- `versionName "1.8"`

`CLAUDE.md` semver: tag `vMajor.Minor.Patch`, versionName matches tag, versionCode +1 per release.

## Unit tests as executable spec

Kotlin (`android/app/src/test/java/com/codekeyboard/`):

- TapMachineTest, KeyboardStateTest  
- TrieTest, UserTrieTest, TrieDecayTest  
- BevaTrieSearchTest, FuzzyTrieSearchTest, FuzzyIntegrationTest  
- WordLearnerTest, ComposingBufferTest, BackspaceRecomposeTest  
- SnippetStoreTest, SuggestionSlotLogicTest  
- SofleLayoutComputerTest  
- benchmarks: Trie, UserTrie, Beva, Fuzzy  

JS (`__tests__/`):

- `trie.test.js`, `build-trie.test.js` - TRIF layout (magic, 12-byte nodes, u24 index)  
- `modifier-state.test.js`  

CI runs Gradle unit tests. TRIF/TRIE2 mismatch in tests was a real failure mode; readers must match the shipped magic.

## GitHub Actions

File: `CodeKeyboard/.github/workflows/build.yml`

On push/PR to main|master:

1. checkout  
2. setup-java 17 temurin  
3. setup-node 20 + npm ci  
4. Gradle cache  
5. sdkmanager: platforms;android-36, build-tools;36.0.0, ndk;27.1.12297006, cmake;3.22.1  
6. `cd android && ./gradlew testDebugUnitTest`  
7. `assembleRelease`  
8. upload-artifact `app-release.apk`  

`workflow_dispatch` release job downloads the artifact and creates a GitHub Release with `softprops/action-gh-release`.

## F-Droid

Example recipe: `docs/fdroid-recipe.yml`.

**Stale numbers warning:** recipe lists versionName 1.6 / versionCode 7. App build.gradle is currently 1.8 / 9. When submitting, sync recipe to the git tag you want built.

Shape of the recipe:

- License MIT, source GitHub  
- `subdir: android/app` (relative to how F-Droid lays out the clone - confirm against their docs for monorepo paths)  
- npm install steps, NDK 27.1.12297006  
- `UpdateCheckMode: Tags`  

Root also has LICENSE and fastlane metadata for store listing. F-Droid builds from source and resigns.

Do not invent undocumented F-Droid breakage in this blog. If you hit RN gradle-plugin / includeBuild issues on their builders, log them as ops notes with the error text.

## What is not implemented

### GIF picker

`docs/adr-002-gif-picker.md` - Planned. BYOK for GIPHY/Tenor (public keys dead). Local MediaStore tab. Send with `commitContent`. Not in the Kotlin tree as a feature yet.

### Stronger LM seed

Keep two-layer BigramModel. Improve the **prior**:

1. HeliBoard/AOSP dictionaries - https://codeberg.org/Helium314/aosp-dictionaries  
   - `.combined` + `dicttool_aosp` -> `.dict`  
   - Offline extract into denser `bigrams.json` + maybe richer unigram table, **or** JNI binary dict like HeliBoard  
2. Trigram keys `"w2 w1"` with backoff to bigram  
3. Unigram backoff when predecessor missing (smallest win)  

User `formula_d`/`formula_p` layer stays for personal and mixed-script pairs AOSP will never ship.

### Mixed language packs

User bigrams already store any string pair. `en.trie` and Norvig seed are English. Pack download / second trie is future.

### Other gaps

- Slide typing: UX doc only, not IME  
- Tap-dance: designed in GESTURE_ARCHITECTURE, not coded  
- Full RN removal  
- Wire `TextInputConnection` through live IME  
- Infini-gram over personal history: research note only  

## Five things that make a reimplementation real

1. `InputMethodService` + canvas keys + correct `InputConnection` use  
2. Composing buffer + selection guard + recompose on backspace  
3. Dual tries + WordLearner policy (flush only known words)  
4. Bigram seed + user decay + after-space next-words + context in suggest  
5. Hold timing: 150ms home-row hold-tap, activate-on-down dedicated mods, 300ms double-tap lock  

Everything else is polish, packaging, and a denser seed.

## File map (quick)

| Path | Role |
|------|------|
| CodeKeyboardIME.kt | IME |
| NativeKeyboardView.kt | Keys + touch |
| SofleKeyData.kt | Layers |
| KeyboardState.kt / TapMachine.kt | State |
| ComposingBuffer.kt | Composing |
| Trie.kt / UserTrie.kt / TrieWriter.kt | Dictionaries |
| BigramModel.kt | Bigrams |
| SuggestionStrategy.kt / BevaTrieSearch.kt | Ranking |
| SuggestionBarView.kt / EmojiPanelView.kt | Chrome |
| SnippetStore.kt | Snippets |
| TrieDecayWorker.kt / MainApplication.kt | Decay |
| tools/build-trie.js | TRIF |
| scripts/extract_bigrams.py | Seed |
| scripts/gen_emoji.py | Emoji |
| GESTURE_ARCHITECTURE.md | Gestures |
| docs/blog/* | This series |

---

## Verification (part 7)

| Claim | Evidence |
|-------|----------|
| Asset byte sizes | measured under assets/ |
| versionCode 9 / versionName 1.8 | android/app/build.gradle |
| fdroid recipe 1.6/7 | docs/fdroid-recipe.yml (stale vs app) |
| CI steps | .github/workflows/build.yml |
| Test class list | android/app/src/test/... directory listing |
| GIF planned not shipped | adr-002-gif-picker Status Planned; no Gif* feature module in main kotlin list |
| NDK 27.1 in CI and fdroid | build.yml; fdroid-recipe.yml |
