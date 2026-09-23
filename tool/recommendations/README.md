# Which model should recommend films

The app can show a "More like this" row on a title, filled by a language
model. This is how we decide which model, and how the app decides whether
the one a viewer configured is any good.

Nothing here runs in CI or in the app build. It reaches the internet, it
costs money at some providers, and it is run by hand when the question
comes up again -- which it will, because the model catalogues move: in one
afternoon of measuring, `gemini-2.5-flash` and `gemini-2.5-flash-lite`
began answering *404, no longer available to new users*, `claude-sonnet-5`
began rejecting `temperature` as deprecated, and models appeared and
disappeared from the paid tier while we watched.

## The answer keys

`keys/gold_*.json` -- 568 titles across seven target titles, each rated on
two axes that are deliberately **not** averaged together:

* **`grade`** 3 essential / 2 strong / 1 defensible / 0 not a reasonable
  recommendation -- how relevant the connection is.
* **`tone`** 2 feels like it / 1 partly / 0 a different register -- what
  the film is like *to sit through*: pace, palette, humour, loudness, how
  much it explains.

The two come apart constantly, and that is the point. *eXistenZ* shares
Avalon's premise and none of its temperature; *Watchmen* makes the same
argument about comic books as *Glass* and feels nothing like it; Melville's
*Le Samouraï* has the thinnest possible connection to Avalon and is the
closest thing on the list to sitting through it. A key that graded
relevance alone would recommend the first two warmly and bury the third.

Four of the seven targets are obscure on purpose -- *Avalon*, *The American
Astronaut*, *Wave Twisters*, *The Call of Cthulhu*. The other three are
controls. Every model scores well on the controls; the obscure four are
where they separate, and where one of them turned out to be no better than
chance.

Each entry carries `what` (what the film is, for a reader who has not seen
it), `why` (the connection, and a clause stating the tension outright when
grade and tone disagree), `basis` (director, crew, influence, mode,
subject, form, lineage) and a source URL for every factual claim.

Entries marked `"pooled": true` came from a model rather than from the
research: see **Pooling** below.

## The tests

**`recommend_bench.py` asks what the app asks**, and it is on the reader
to keep it that way: the prompt is `askForSimilar` in
`lib/features/similar/similar_titles.dart`, word for word, and the system
instruction is `similarSystemInstruction`. Change the Dart, change the
script, re-measure, and say here what moved. Measuring one question while
shipping another is how a table of numbers quietly stops describing the
app, which is what happened between the first measurements and the day
the app learned to ask about series.

`ASK_FOR_ALSO_SERIES=0` asks the old film-only question instead, so the
cost of admitting series can be measured rather than argued about. The
app's *series* question is still unmeasured, and cannot be measured
against these keys: every one of the seven **targets** is a film. (Some
answers in the keys are series now -- pooling added them, and they are
rated like anything else. It is the target that is never a series.)

**`recommend_bench.py`** -- the honest one. Asks for ten films, scores the
answer against the key, and reports five things, because one number hides
the failures that matter: how good the films it found are, whether they
*feel* like the target, how many are films that exist at all, how much a
model's own repeated runs agree, and how many of the seven kinds of
connection its answers span. Every score is printed beside what drawing at
random from that key would have got, because the keys are not equally
kind -- 40 of the 60 films around *The Seventh Continent* share its
texture, against 7 of the 59 around *Wave Twisters*.

**`vibe_sort.py`** -- the fast one, about a second per target. Hands over a
list and asks which films *feel* most like the target. The lists are salted
with films the key rates highly relevant and tonally opposite, and films
rated barely relevant and tonally identical, so that **answering by
relatedness scores 0.41 where chance is 0.50**. It cannot be gamed by
knowing what is related, only by attending to what a film is like.

**`model_bench.py`** -- the older sort, kept because it ranks every model a
Google key can reach and reports why the rest failed (gone, not in tier,
too slow, other API).

`verify_gold.py` checks every film in a key exists with that year on TMDB.
`fold_pool.py` merges rated suggestions back into the keys.

## Pooling, and why it is not optional

A model suggests ten films; some are not in the key. Scoring those as
misses would punish a model for knowing something the researchers did not,
so they are collected, rated by the same rubric, and folded back in.

This is not a nicety. Before folding, `ministral-8b` scored +0.01 relevance
lift; after its own suggestions were rated and counted, **-0.22** -- below
chance. Its misses had simply been invisible. The same effect flatters any
model that has not been pooled yet, which is why a ranking must pool every
model *first* and only then compare.

It has a cost, stated plainly: the keys drift toward what models suggest,
since research never lists the wrong answers. Hence `"pooled": true` on
every such entry, so the research-only subset can always be recovered.

## What the app does with this

The keys ship with the app -- title, year, grade and tone is about 30 KB --
so a viewer who pastes an API key can be told whether the model behind it
is any good. Both tests are one call per target, so the check is seconds:

* the **sort** gives a clean, comparable number that no coverage effect can
  inflate, since every film in the question is already in the key;
* one **recommendation** call catches the failure the sort structurally
  cannot see -- invented films. A model can sort sensibly and still
  fabricate one title in six when asked to generate, which is what would
  actually appear on screen.

## What was measured, 2026-09-22

Six models, seven targets, on identical keys after pooling every one of
them. Lift is over that key's own chance line.

| model | relevance | tone | vibe sort | in key | real | slowest |
|---|---|---|---|---|---|---|
| `z-ai/glm-5.3-flash` | +0.27 | +0.33 | 0.74 | 0.75 | 0.97 | 153 s |
| `claude-sonnet-5` | +0.22 | +0.29 | 0.71 | 0.77 | 0.97 | 16 s |
| `gemini-3.5-flash-lite` | +0.20 | +0.23 | 0.64 | 0.74 | 0.83 | 2.4 s |
| `gemini-3.1-flash-lite` | +0.19 | +0.21 | 0.68 | 0.91 | 0.92 | 2.4 s |
| `claude-haiku-4.5` | +0.26 | +0.20 | 0.60 | 0.39 | 0.92 | 4.9 s |
| `ministral-8b` | -0.22 | -0.32 | 0.50 | 0.49 | 0.72 | 7.1 s |

Read with care:

* **The best recommender is unusable.** GLM leads both tests and takes two
  and a half minutes. A row nobody waits for is not a row.
* **A high score can rest on thin evidence.** Haiku's relevance lift is
  second best, and only 39% of its suggestions are in the keys at all --
  it is scored on two fifths of its answers. Its runs agree with each other
  a third of the time.
* **Mistral does not recommend films.** Below chance on both axes, 20
  invented titles in 71, and 73% of its suggestions begin with the word
  "The" -- including four consecutive "The Secret of..." titles for a
  wordless hip-hop cartoon. That is a decoding artefact wearing the shape
  of an answer.
* **Asking for feel is worth doing.** The same model asked for films that
  *feel* alike rather than films that are related scores 0.85 against 0.73
  on tone, and invents fewer films while it is at it.

On this evidence the app's default is `gemini-3.1-flash-lite`: within
0.06 of the best judgement available at any speed, the best coverage of
any model tested, the most self-consistent, and under three seconds.

## What admitting series cost, 2026-09-22 (later the same day)

The app's question changed to ask for films *and* series. `ASK_FOR_ALSO_SERIES`
makes that a switch, so the two questions can be put to the same model on
the same afternoon with the same key:

| `gemini-3.1-flash-lite` | series admitted | film-only |
|---|---|---|
| relevance lift | +0.18 | +0.16 |
| tone lift | +0.18 | +0.13 |
| in key | 0.95 | 0.94 |
| real | 0.90 | 1.00 |
| consistent | 0.59 | 0.50 |
| breadth | 0.53 | 0.56 |
| slowest | 2.9 s | 3.2 s |

A second round of pooling (12 more rated, one of them a 0) took the
series-admitted column to **+0.18 relevance, +0.14 tone, coverage 0.96,
real 1.00**, with 8 suggestions left unrated. The lift did not move; the
coverage did, which is the only thing a second round was ever going to
settle.

Taken *after* the 33 suggestions both columns turned up were rated and
folded in, and after the matching below was fixed. Coverage went from
0.87 to 0.95 between the provisional run and this one, so both columns
now rest on almost all of what the model said rather than seven eighths
of it.

**The two are indistinguishable**, and that is the finding. One run each is
nowhere near enough to call +0.17 better than +0.15 -- this benchmark's
leader changed on every run until it was given repeats and a paired sign
test, which is why the table above exists and this one is only a check
that nothing collapsed. Nothing collapsed.

Three cautions, none of them about series:

* **13 suggestions are still unrated** and left out of the scoring, which
  flatters a model that wanders. That is down from 27 and 20 before this
  round of pooling, and it never reaches zero: a new run turns up new
  titles. It is the *size* of the unrated remainder that decides how much
  a number can be trusted.
* **The film-only column is below this README's own row for the same
  model on the same question** (+0.15 against +0.19). Either run-to-run
  noise, or `gemini-3.1-flash-lite` has moved behind a stable name. The
  second is the reason the app treats the model as a preference and every
  failure as classified rather than fatal.
* **`The Call of Cthulhu` is below chance on tone** (0.36 against 0.41),
  and it was in every run all day. The model hears "Lovecraft" and misses
  "silent, 47 minutes, 1920s pastiche". The obscure targets are where this
  model fails, and admitting series changed that neither way.

Four bugs were found by running it, all of which had made earlier runs
worse than useless:

* `recommend_bench.py` and `vibe_sort.py` globbed `gold_*.json` beside
  themselves after the keys moved into `keys/`. The bench printed
  `0 answer keys` and then "answered nothing" per model -- which reads
  like a result. Zero keys is an error now.
* `exists_on_tmdb` searched `/search/movie` only. Correct while the
  question said "films only"; against the question as it is asked now it
  would have scored every correct series as an invented title and blamed
  the wording for it. It searches `/search/tv` as well.
* **`norm()` matched one spelling of a title and the keys hold several.**
  A model naming a film the key already rates was scored as naming
  something nobody had rated: dropped from the result and sent to the
  pool to be rated a second time. Three ways it happened, ~9% of the
  entries between them: accents were deleted rather than folded, so
  `Caché` and `Cache` were different films (10 entries); the `aka` the
  keys record was never read (17); and a subtitle had to match exactly, so
  `Tetsuo` missed `Tetsuo: The Iron Man` (22). Every spelling is indexed
  now -- title, `aka`, the part before a colon, and the part before a
  trailing `or (...)`.
* **`fold_pool.py` deduped on that same single spelling**, so a rated
  suggestion under a variant name was appended beside the entry it
  duplicated, rated twice and counted twice. It folds on every spelling
  now. One duplicate (`Birdman`) got in before the rule covered the
  `or (...)` form and was removed by hand.

## Still open

* The **series question** has never been measured. Every target is a film,
  and rating a key for a series target is the work that would fix it.
* The pool is empty as of the last fold; a new run will refill it.
* The table above is **one run per column**. A claim that one question or
  one model beats another needs the repeats and the paired sign test that
  `model_bench.py` does, not this.
