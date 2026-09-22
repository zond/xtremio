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

`keys/gold_*.json` -- 528 films across seven target titles, each rated on
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

**The app no longer asks what these scripts ask.** `recommend_bench.py`
still carries the film-only prompt every number below was measured with,
while the app (`lib/features/similar/`) now asks for films *and* series,
asks which each one is, and asks a different question again when the viewer
is standing on a series -- a question nothing here has measured, since all
528 researched titles are films. Make the two match before measuring again.

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
