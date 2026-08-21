---
active: true
layout: group_page
group: keyboard
group_title: "CodeKeyboard Rebuild Notes"
group_url: "/keyboard/"
title: "CodeKeyboard Part 9: KN vs Katz vs SwiftKey WDP"
subtitle: "Three smoothing variants, one binary pack, 31% smaller"
date: 2026-08-19 09:00:00
background_color: '#1b2838'
---

We built the same trigram model three ways -- Kneser-Ney (KN), Katz backoff, and
Katz + SwiftKey-style weighted-difference pruning (WDP) -- on the full 583 MB
SwiftKey capstone corpus (Coursera-SwiftKey `en_US`: blogs + news + twitter,
concatenated into `swiftkey_all.txt`), and compared them on size and prediction
agreement.

**Verdict up front:** SwiftKey-WDP produces the same predictions as Katz
(99.2% top-1 agreement at our shipping threshold) in a smaller file. We ship
SwiftKey-WDP.

| Build | Raw trigrams.json | thr=25 | Contexts | Avg followers (thr=25) |
|---|---|---|---|---|
| KN | 377 MB | 54.0 MB | 1,940,183 | 10.0 (capped) |
| Katz | 341 MB | 53.9 MB | 1,940,183 | 10.0 (capped) |
| **SwiftKey-WDP** | **231 MB** | **53.5 MB** | 1,938,465 | **9.82** (min 1, max 10) |

All three builds share the same counting/merge pipeline and emit identical
support files (`bigrams_support.json`, byte-identical across builds) and
identical bigram files. The only thing that differs is how the trigram tier is
scored and pruned.

## What each variant actually solves

These three aren't independent designs -- each one is a response to a specific
failure of the one before it. Read them as a chain, not a menu:

- **KN (Kneser-Ney) solves: "what should the model guess when it has never
  seen this context?"** Plain frequency backoff gets this wrong -- a word like
  *"Francisco"* has high raw frequency (because "San Francisco" is common) but
  is a bad generic guess, since it only ever completes one context. KN's fix
  is `cont_p`: back off to how many *different* contexts a word continues,
  not how often it appears. This is the right answer to the cold-start
  problem. **What it doesn't solve:** KN's discounting is tuned for
  unpruned, academic-scale models. It interacts badly with the hard pruning a
  keyboard app actually needs -- Chelba et al. (2010, Gboard) found this is
  exactly why production keyboard LMs use Katz instead of KN.

- **Katz solves: "make the discounting robust enough to survive aggressive
  pruning."** Instead of KN's continuation-probability backoff, Katz uses
  Good-Turing discounts derived straight from count-of-counts (how many
  n-grams were seen exactly once, twice, ...), with a clean backoff weight
  `` that keeps the seen + unseen distribution summing to 1. It's simpler
  and more stable under the size constraints a mobile app has to live within.
  **What it doesn't solve:** Katz (like KN) still fills every context's
  follower list up to the hard cap (avg 10.0 followers, every slot used, on
  our corpus) -- it has no concept of "this candidate is uninformative,
  drop it." Every follower list is exactly as full as the size budget
  allows, whether or not the extra entries actually help prediction.

- **SwiftKey-WDP solves: "which of Katz's followers are actually worth
  keeping?"** WDP takes the Katz model as-is (same statistics, same scores)
  and adds a selection criterion on top: keep a follower only if its
  trigram-conditioned probability differs enough from what the bigram
  backoff alone would have predicted, weighted by how likely the whole
  phrase is. A follower that merely restates the bigram tier carries no
  trigram information and gets dropped -- sometimes emptying the context
  entirely (1,718 contexts pruned outright on the full corpus). Result:
  ~31% smaller than Katz at equal corpus size, while still matching Katz's
  top-1 prediction 99.2% of the time at the shipping threshold (thr=25).
  **What it doesn't solve:** WDP is a pruning layer on top of Katz, not a
  new probability estimate -- it inherits whatever Katz got right or wrong
  about the underlying scores; it only decides what's worth storing.

In short: KN answers *what to predict when you've seen nothing*, Katz answers
*how to discount what you have seen so backoff stays coherent under pruning*,
and WDP answers *which of those predictions are worth the bytes to ship*.
That's why we ship Katz + WDP together -- Katz supplies the estimate, WDP
decides what of it survives onto a phone.

---

## What changes across the three scripts

The three builders are one codebase with two surgical forks:
`scripts/build_ngrams.py` (KN) -> `scripts/build_ngrams_katz.py` (Katz) ->
`scripts/build_ngrams_swiftkey.py` (WDP). Two regions change: the **normalize**
step (what helper statistics get precomputed into `normalized.sqlite`) and the
**score** step (how a context's followers are scored).

### 1. Normalize step

**KN** precomputes continuation probabilities (the "Francisco" fix) and
per-context totals:

```python
# build_ngrams.py (KN)
dst.execute("CREATE TABLE cont_p(w TEXT PRIMARY KEY, p REAL)")
dst.execute("CREATE TABLE bigram_ctx(ctx TEXT PRIMARY KEY, total INTEGER, distinct_n INTEGER)")

# P_continuation(w) = (# distinct bigram types ending in w) / (# bigram types)
total_types = src.execute("SELECT COUNT(*) FROM bigrams").fetchone()[0]
dst.executemany(
    "INSERT INTO cont_p(w, p) VALUES(?, ?)",
    ((w, c / total_types) for w, c in
     src.execute("SELECT w, COUNT(*) FROM bigrams GROUP BY w")),
)
```

**Katz** replaces those with unigram MLE probabilities (the bottom of the
backoff chain) and Good-Turing count-of-counts histograms per order:

```python
# build_ngrams_katz.py
dst.execute("CREATE TABLE uni_p(w TEXT PRIMARY KEY, p REAL)")
dst.execute("CREATE TABLE hist(ngram_order INTEGER, r INTEGER, n INTEGER, PRIMARY KEY(ngram_order, r))")

# Unigram MLE: p(w) = c(w) / N -- the lowest-order backoff.
uni_total = src.execute("SELECT SUM(count) FROM unigrams").fetchone()[0] or 1
dst.executemany(
    "INSERT INTO uni_p(w, p) VALUES(?, ?)",
    ((w, c / uni_total) for w, c in src.execute("SELECT w, count FROM unigrams")),
)

# N_r = # n-gram types with count exactly r, per order (2, 3).
for order, table in ((2, "bigrams"), (3, "trigrams")):
    dst.executemany(
        "INSERT INTO hist(ngram_order, r, n) VALUES(?, ?, ?)",
        ((order, r, n) for r, n in
         src.execute(f"SELECT count, COUNT(*) FROM {table} GROUP BY count")),
    )
```

**SwiftKey-WDP** uses the same normalize step as Katz (it prunes a Katz model;
it doesn't change the statistics).

#### Reading those SQL tables in plain English

The normalize step exists because each smoother needs different "helper
statistics" precomputed before it can score anything. What each table actually
*means*:

**KN's two tables** (`cont_p`, `bigram_ctx`):

- **`cont_p(w, p)` -- "continuation probability."** For every word *w*, count in
  how many *different* contexts *w* ever appeared as a follower (i.e. how many
  distinct bigram types end in *w*), divided by the total number of distinct
  bigram types in the corpus. This is deliberately **not** raw frequency -- it's
  the fix for the classic "San Francisco" problem: *"Francisco"* has a high raw
  frequency (because "San Francisco" occurs constantly) but is a terrible
  generic guess, because it only ever continues **one** context ("San ___").
  Raw frequency can't tell "genuinely common word" apart from "word that
  completes one very common phrase"; continuation count can. This table is the
  bottom tier of the KN backoff chain -- what the model falls back to when it
  has never seen the context.
- **`bigram_ctx(ctx, total, distinct_n)` -- per-context bookkeeping.** For each
  context word *w1*: `total` = the total number of bigram *tokens* that start
  with *w1* (the sum of all its follower counts), and `distinct_n` = how many
  *different* words ever followed *w1* (the number of follower types). These
  two numbers produce KN's interpolation weight
  **(w1) = d  distinct_n / total** -- "how much probability mass should this
  context reserve for backoff?" A context with many rare followers (large
  `distinct_n` relative to `total`) is one where unseen continuations are
  likely, so it hands more mass to the backoff tier; a context dominated by one
  frequent follower keeps most mass on what was seen.

**Katz's two tables** (`uni_p`, `hist`):

- **`uni_p(w, p)` -- plain unigram frequency.** `p(w) = count(w) / total tokens
  in corpus`. No cleverness at all -- this is the absolute bottom of the Katz
  backoff chain: when the model knows nothing about the context, it guesses the
  globally most frequent words.
- **`hist(order, r, n)` -- the "count-of-counts" histogram.** Read a row as:
  *"for n-grams of length `order`, exactly **n** distinct n-gram types were
  observed exactly **r** times in the corpus."* So `hist(3, 1, 400000)` means
  "400,000 distinct trigram types were seen exactly once." Good-Turing
  discounting works entirely off the ratio of adjacent rows, **N_{r+1} / N_r**,
  to answer: *"of all the things seen r times, how much probability mass should
  we shave off and hand to things never seen at all?"* Intuition: if a huge
  number of types were seen exactly once (N large), the corpus is sparse --
  next time you're likely to see something new, so discounts are aggressive. If
  few singletons exist relative to higher counts, the corpus is dense and the
  discounts clamp to 1.0 -- *no* discount, seen counts pass through as-is. That
  clamp is exactly what happened on our 583 MB corpus (build log:
  `d_bi[1]=1.0000 d_tri[1]=1.0000`): the corpus is dense enough that Katz 
  plain relative frequency for seen n-grams, but the backoff machinery is still
  fully in place for unseen ones.

### 2. Score step -- bigram

**KN** interpolates every seen follower with the continuation probability:

```python
# KN score_bigram
lam = (discount * len(followers)) / total
scored = [(w, max(c - discount, 0) / total + lam * cont_p.get(w, 0.0))
          for w, c in followers.items()]
```

*"Every follower we actually saw gets `(count  0.75) / total` --
shave a flat 0.75 off each count, then normalize. Then, on top of that, add a
small bonus proportional to how 'continuable' the word is in general
(`cont_p`). The size of that reserved bonus pool is `lam`: contexts with many
distinct followers reserve more."* Two properties follow: (1) followers seen
exactly once get score ~0 from the first term and survive only on their
continuation bonus; (2) the blend happens for **every** entry, seen or not --
that's what makes this *interpolated* KN.

**Katz** computes Good-Turing discounts from the histogram, then applies a
straight discounted MLE -- no interpolation at the bigram tier (the backoff only
matters inside the trigram backoff distribution):

```python
# Katz katz_discounts + score_bigram
def katz_discounts(hist: dict[int, int], k: int = 5) -> dict[int, float]:
    """Good-Turing/Katz discounts d_r from a count-of-counts histogram."""
    n1 = hist.get(1, 0)
    nk1 = hist.get(k + 1, 0)
    if n1 == 0 or nk1 == 0:
        return {r: 1.0 for r in hist}
    ratio = (k + 1) * nk1 / n1
    d = {}
    for r in hist:
        if r > k:
            d[r] = 1.0
        else:
            nr, nr1 = hist.get(r, 0), hist.get(r + 1, 0)
            d[r] = 1.0 if (nr == 0 or nr1 == 0) else min(((r + 1) / r) * (nr1 / nr) / ratio, 1.0)
    return d

def score_bigram(followers: dict, d_bi: dict, max_f: int):
    scored = [(w, d_bi.get(c, 1.0) * c / total) for w, c in followers.items()]
```

*"`katz_discounts` turns the count-of-counts histogram into a
per-count multiplier `d_r` -- 'a thing seen r times keeps only d_r of its mass.'
Counts above k=5 keep everything (`d_r = 1`). Then `score_bigram` is just
`d_count  count / total` for each seen follower -- a discounted relative
frequency, with nothing blended in.*" Note the deliberate absence of a backoff
term here: in a Katz model the bigram tier only describes what was *seen* after
the context; the unigram floor (`uni_p`) only ever enters inside the **trigram**
backoff distribution (next section). And recall from the normalize-step
walkthrough that on this corpus all the `d_r` clamped to 1.0 -- so in practice
this is plain `count / total` for us, with the discount machinery dormant but
correctly in place.

### 3. Score step -- trigram

**KN** unions seen followers with the backoff distribution and interpolates all
of them:

```python
# KN score_trigram
lam = (discount * len(followers)) / total
scored = []
for w in set(followers) | set(backoff):
    c = followers.get(w, 0)
    scored.append((w, max(c - discount, 0) / total + lam * backoff.get(w, cont_p.get(w, 0.0))))
```

*"Same recipe as the bigram tier, but the bonus pool now draws from the bigram
backoff distribution instead of `cont_p`: every word in the union of 'seen
after this context' and 'in the backoff distribution' gets `(count  0.75)/total`
plus a slice of the reserved mass `lam` proportional to its backoff score.
Words never seen after this context get only the backoff slice -- that's how KN
fills all 10 slots even for sparse contexts."*

**Katz** scores seen followers with the discounted MLE, then adds unseen
backoff words scaled by the normalizing backoff weight  (so the distribution
still sums to 1):

```python
# Katz score_trigram
seen = [(w, d_tri.get(c, 1.0) * c / total) for w, c in followers.items()]
seen_mass = sum(p for _, p in seen)
seen_bo = sum(backoff.get(w, 0.0) for w in followers)
beta = (1 - seen_mass) / max(1 - seen_bo, 1e-12)
scored = seen + [(w, beta * p) for w, p in backoff.items() if w not in followers]
scored.sort(key=lambda p: (-p[1], p[0]))
top = scored[:max_f]
```

*"Seen followers get the discounted MLE `d_rc/total`. `seen_mass` is how much
probability those seen words consumed; `beta` rescales the bigram backoff so
the unseen words share exactly the leftover `1  seen_mass` -- the whole
distribution still sums to 1. Unseen words enter ranked by `p(w|w2)`, which
is why Katz also fills all 10 slots."*

**SwiftKey-WDP** takes the Katz trigram and prunes each follower by the
weighted-difference criterion -- keep a follower only if its trigram estimate
differs enough from what the bigram backoff would have said anyway, weighted by
how probable the whole trigram is:

```python
# SwiftKey score_trigram -- keep w iff:
#   p(w1 w2 w) * |log p(w|w1 w2) - log(beta * p(w|w2))| > delta
kept = []
for w, p in seen:
    bo_p = beta * backoff.get(w, 0.0)
    diff = float("inf") if bo_p <= 0 else abs(math.log(p) - math.log(bo_p))
    if ctx_joint * p * diff > delta:
        kept.append((w, p))
if not kept:
    return None                      # whole context pruned
kept.sort(key=lambda p: (-p[1], p[0]))
top = kept[:max_f]
```

*"Start from the Katz trigram scores, then ask of every follower: 'does knowing
the two-word context actually change this word's odds compared to the bigram
alone?' `diff` is the log-odds gap between the trigram estimate and the
backoff; `ctx_jointp` weights that gap by how likely the whole phrase is.
Only followers whose weighted surprise exceeds `delta` survive -- the rest
merely restate the bigram tier and are dropped. If nothing survives, the whole
context is pruned."*

`ctx_joint = p(w2|w1) * p(w1)` is the context part of the chained joint
probability, computed per context with a memoized `bigram_total(w1)`. Unseen
backoff words score exactly `p(w|w2)`, so their weighted difference is 0 and
they are *always* pruned -- they replicate the bigram tier and carry no trigram
information. This is why WDP only ever touches the trigram output: the bigram
and support files come out byte-identical to the other builds.

---

## Tests run

1. **Local benchmarks** (MacBook, 4 workers) on 50 MB and 250 MB corpus slices
   for the SwiftKey build, with follower-count sampling.
2. **Full-corpus AWS builds** (spot `t3.xlarge`, ap-south-1, self-terminating)
   for Katz and SwiftKey on the full 583 MB corpus (~11 min each).
3. **Pairwise comparison** (`compare_kn_katz.py`): follower-list identity and
   top-1 agreement, KN vs Katz, on the full builds.
4. **Pruning sweep** (`prune_compare.py`): KN vs Katz as the support threshold
   `thr` sweeps 10 -> 50 (the app prunes contexts by support at load time).
5. **Three-way comparison** (`compare_three.py`): KN vs Katz vs SwiftKey --
   sizes, top-1 agreement, follower-count stats, and sample disagreements.

## Results

### SwiftKey local benchmarks

| Corpus slice | trigrams.json | Contexts sampled | Avg followers | Katz equivalent |
|---|---|---|---|---|
| 50 MB | 33.4 MB | 200,000 | 5.38 | 49.0 MB (avg 10.0) |
| 250 MB | 127.5 MB | 500,000 | 5.53 | 184.0 MB (avg 10.0) |

WDP output runs ~31% smaller than Katz at the same corpus size.

### KN vs Katz, support-threshold sweep (full corpus)

| thr | ctx_kept | KN MB | Katz MB | top-1 agree |
|---|---|---|---|---|
| 10 | 607,751 | 122.7 | 118.9 | 81.4% |
| 15 | 424,471 | 85.2 | 84.2 | 83.9% |
| 20 | 328,214 | 65.8 | 65.5 | 85.3% |
| 25 | 269,397 | 54.0 | 53.9 | 86.2% |
| 30 | 229,250 | 46.0 | 45.9 | 86.8% |
| 40 | 177,373 | 35.7 | 35.5 | 87.7% |
| 50 | 145,278 | 29.2 | 29.1 | 88.3% |

Unpruned, only 5,933 of 1,940,183 contexts (0.3%) have identical follower
lists, and top-1 agreement is 64% -- the two smoothers genuinely rank
differently. Agreement *rises* with pruning because low-support contexts are
where the ranking diverges most. Sample top-1 disagreements at thr=25:

```
'cause i'm':  KN=not    Katz=a       (support=66)
'i am':       KN=not    Katz=going   (support=41)
'i just':     KN=want   Katz=don't   (support=27)
'if i':       KN=was    Katz=don't   (support=41)
'round the':  KN=world  Katz=clock   (support=34)
```

### Three-way comparison (full corpus)

| thr | KN MB | Katz MB | SK MB | KNvKZ top-1 | KNvSK top-1 | KZvSK top-1 |
|---|---|---|---|---|---|---|
| 10 | 122.7 | 118.9 | 111.0 | 81.4% | -- | -- |
| 25 | 54.0 | 53.9 | 53.5 | 86.2% | 85.7% | **99.2%** |
| 40 | 35.7 | 35.5 | -- | 87.7% | -- | 99.9% |
| 50 | 29.2 | 29.1 | 29.1 | 88.3% | -- | 99.9% |

Follower-count stats at thr=25: KN avg 10.0 and Katz avg 10.0 -- every context
is capped at `--max-followers 10`. SwiftKey avg 9.82 (min 1, max 10): WDP
removes the followers whose trigram score merely restates the backoff. It also
dropped 1,718 contexts entirely (1,938,465 vs 1,940,183) -- contexts where
*every* follower fell below the weighted-difference threshold.

The "avg" number is the mean number of candidate next-words stored per context
after pruning. KN and Katz always fill all 10 slots; SwiftKey keeps only the
informative ones. Since SwiftKey matches Katz's top-1 prediction 99.2% of the
time at our shipping threshold while being smaller at every threshold, the data
says: **ship the SwiftKey-WDP build.**

---

## References

- **Katz paper** -- S. M. Katz, "Estimation of probabilities from sparse data
  for the language model component of a speech recognizer," *IEEE Transactions
  on Acoustics, Speech, and Signal Processing*, 1987. The Good-Turing
  discounting + backoff-weight scheme implemented in `build_ngrams_katz.py`.
- **SwiftKey patent article** -- US8655647, "N-gram selection for
  practical-sized language models" (Moore & Quirk, Microsoft Research lineage,
  granted 2014). The weighted-difference pruning criterion implemented in
  `build_ngrams_swiftkey.py` -- an approximation to Stolcke's relative-entropy
  pruning (1998) that needs only the pruned model's own statistics.
- Moore & Quirk, "Less is More: Significance-Based N-gram Selection for
  Smaller, Better Language Models," EMNLP 2009 (D09-1078): significance
  selection + modified WDP  relative-entropy pruning at severe pruning
  levels; improves Katz-backoff perplexity ~8% at the same model size.
- Stolcke, "Entropy-based Pruning of Backoff Language Models," 1998 -- the
  relative-entropy pruning that WDP approximates.
- Chelba et al., 2010 (Gboard): why production keyboard LMs use Katz rather
  than KN -- KN's aggressive discounting interacts badly with hard pruning,
  which is exactly the regime a keyboard model ships in.
- Chen & Goodman, "An Empirical Study of Smoothing Techniques for Language
  Modeling," 1998 (cs/0108005) -- the smoothing survey behind the KN reference
  build.
