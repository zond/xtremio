"""Rank the models a Google AI Studio key can reach, by judgement and speed.

The question is a *sort*, not a recall: the model is handed a shuffled list
of films and asked to order them by similarity to a target. Scoring a sort
needs no ground truth about taste -- only tiers nobody would argue with (a
film by the same director, on the same preoccupations, is nearer than an
unrelated musical). Score is pairwise tier accuracy over every pair drawn
from different tiers: 1.0 perfect, 0.5 a coin toss. Order within a tier is
opinion and is not scored.

Two of the five targets are deliberately obscure, because that is where a
model either knows the film or guesses from its title -- and the bottom
tier of each question holds a film with almost the same name, to catch the
guessing. The mainstream targets are controls: a model that fails those is
not being asked something unfair, it is simply bad.

A model that cannot answer within the budget is no use to a screen that is
waiting, so the budget is enforced here the way the app will enforce it.
How far past the budget a model went is still reported, because "six
seconds" and "a minute" are different kinds of no.

  G_KEY=... python3 model_bench.py [model ...]
  BUDGET_S=5 CEILING_S=25 WORKERS=5 THINKING=0 G_KEY=... python3 model_bench.py
"""
import json, os, random, re, statistics, sys, time, urllib.error, urllib.request
from concurrent.futures import ThreadPoolExecutor

KEY = os.environ["G_KEY"]
BUDGET_S = float(os.environ.get("BUDGET_S", "5"))
CEILING_S = float(os.environ.get("CEILING_S", "25"))
WORKERS = int(os.environ.get("WORKERS", "5"))
THINKING = int(os.environ.get("THINKING", "0"))
# Each question is asked in this many different presentation orders. One
# order scores one sample of a model's judgement *and* of where the list
# happened to put things: models are not immune to what came first. The
# orders are seeded, so every model is asked the same ones.
REPEATS = int(os.environ.get("REPEATS", "3"))

# Seven tiers, one template for all four obscure targets, each boundary
# resting on something checkable rather than on taste:
#   0 same director   1 shared named crew   2 influence the maker declared
#   3 same production mode   4 same subject, no connection
#   5 subject decoy   6 name decoy
# The research behind these is cited in docs; three things it corrected are
# worth remembering, because all three are what a plausible guess gets
# wrong: McAbee rejects the Eraserhead comparison outright, Dark Star is in
# colour so it is no black-and-white peer, and TMDB dates Wave Twisters to
# 1998, which is wrong.
QUESTIONS = [
    {
        "target": "Avalon (2001)",
        "tiers": [
            # Oshii's own live-action features, all of them before Avalon.
            ["The Red Spectacles (1987)", "Stray Dog: Kerberos Panzer Cops (1991)",
             "Talking Head (1992)"],
            # His anime sharing Avalon's composer Kenji Kawai or writer Kazunori Ito.
            ["Patlabor 2: The Movie (1993)", "Ghost in the Shell (1995)",
             "Ghost in the Shell 2: Innocence (2004)"],
            # One named Avalon department head each, three other directors:
            # Kawai scored Ring; Foremniak (Ash) is in Quo Vadis; Kedzierski
            # shot With Fire and Sword.
            ["Ring (1998)", "Quo Vadis (2001)", "With Fire and Sword (1999)"],
            # Polish directors Oshii names in his own words (Filmweb, 2001).
            ["Ashes and Diamonds (1958)", "Eroica (1958)", "Possession (1981)"],
            # Jack-into-the-game films of the same moment, no connection.
            # The Matrix is left out on purpose: every model ranks it high
            # for the wrong reason, which costs discrimination.
            ["Nirvana (1997)", "eXistenZ (1999)", "The Thirteenth Floor (1999)"],
            ["Excalibur (1981)", "King Arthur (2004)", "The Green Knight (2021)"],
            ["Avalon (1990)", "Avalon (2011)", "Avalon High (2010)"],
        ],
    },
    {
        "target": "The American Astronaut (2001)",
        "tiers": [
            ["Stingray Sam (2009)", "Crazy and Thief (2012)",
             "Deep Astronomy and the Romantic Sciences (2022)"],
            # Shot by the same cinematographer, W. Mott Hupfel III.
            ["The Notorious Bettie Page (2005)", "The Savages (2007)",
             "Jack Goes Boating (2010)"],
            # Films McAbee names himself; Potter wrote Pennies from Heaven.
            ["Superman and the Mole Men (1951)", "It's Always Fair Weather (1955)",
             "Pennies from Heaven (1981)"],
            # US independent, black and white, premiered at Sundance.
            ["Clerks (1994)", "Pi (1998)", "Computer Chess (2013)"],
            ["Dark Star (1974)", "Outland (1981)", "Moon (2009)"],
            ["The Astronaut's Wife (1999)", "Space Cowboys (2000)",
             "The Astronaut Farmer (2006)"],
            ["The American President (1995)", "The American (2010)",
             "American Made (2017)"],
        ],
    },
    {
        "target": "Wave Twisters (2001)",
        "tiers": [
            # A Wave Twisters principal in a lead creative role.
            ["N.A.S.A.: The Spirit of Apollo (2010)", "Jodorowsky's Dune (2013)",
             "Room 237 (2012)"],
            ["Scratch (2001)", "Hang the DJ (1998)", "Battle Sounds (1997)"],
            # Named as influences in the Filmmaker Magazine production report.
            ["Shaft (1971)", "Bullitt (1968)", "Star Wars (1977)"],
            # Album as film: animation carried by a pre-existing musical work,
            # no spoken narrative dialogue.
            ["Interstella 5555: The 5tory of the 5ecret 5tar 5ystem (2003)",
             "Fantasia (1940)", "Allegro non troppo (1976)"],
            ["Wild Style (1982)", "Style Wars (1983)", "Beat Street (1984)"],
            ["The Endless Summer (1966)", "Step into Liquid (2003)",
             "Riding Giants (2004)"],
            ["Twisters (2024)", "Twister (1996)", "Wavelength (1967)"],
        ],
    },
    {
        "target": "The Call of Cthulhu (2005)",
        "tiers": [
            ["The Whisperer in Darkness (2011)",
             "A Shoggoth on the Roof: A Documentary (2000)",
             "The Testimony of Randolph Carter (1988)"],
            # A Call of Cthulhu creditee on somebody else's film.
            ["Caligula: The Ultimate Cut (2023)", "Demonic Toys (1992)", "Ticks (1993)"],
            ["Re-Animator (1985)", "Dagon (2001)", "Color Out of Space (2019)"],
            # The period and mode the film imitates. Defined on the attribute,
            # not on influence: nobody involved ever named a silent film.
            ["The Cabinet of Dr. Caligari (1920)", "Nosferatu (1922)", "Metropolis (1927)"],
            ["The Artist (2011)", "Blancanieves (2012)", "Juha (1999)"],
            # Cthulhu (2007) is left out: it adapts Innsmouth, so it is a real
            # adaptation wearing a decoy title.
            ["Cthulhu (2000)", "Cthulhu Mansion (1992)"],
            ["The Call of the Wild (2020)", "The Call (2013)", "The Call (2020)"],
        ],
    },
    # The mainstream controls, so obscurity can be told from incompetence.
    {
        "target": "Glass (2019)",
        "tiers": [
            ["Split (2016)", "Unbreakable (2000)"],
            ["Brightburn (2019)", "Chronicle (2012)", "Super (2010)"],
            ["Shutter Island (2010)", "Fight Club (1999)", "Joker (2019)"],
            ["Glass Onion: A Knives Out Mystery (2022)", "The Glass Castle (2017)",
             "Paddington 2 (2017)"],
        ],
    },
    {
        "target": "The Seventh Continent (1989)",
        "tiers": [
            ["Benny's Video (1992)", "Cache (2005)", "Funny Games (1997)"],
            ["Dog Days (2001)", "Dogtooth (2009)", "Import Export (2007)"],
            ["American Beauty (1999)", "Magnolia (1999)", "Happiness (1998)"],
            ["Seven (1995)", "Ice Age: Continental Drift (2012)", "Mamma Mia! (2008)"],
        ],
    },
    {
        "target": "Heat (1995)",
        "tiers": [
            ["Thief (1981)", "Collateral (2004)", "Miami Vice (2006)"],
            ["The Town (2010)", "Sicario (2015)", "Den of Thieves (2018)"],
            ["Ronin (1998)", "Drive (2011)", "No Country for Old Men (2007)"],
            ["The Heat (2013)", "Body Heat (1981)", "Shrek (2001)"],
        ],
    },
]

def split_title(text):
    """A film as (title, year). The year is not decoration: three of the
    films in these questions are called Avalon and two are called The Call,
    so a match on the title alone assigns them at random."""
    years = re.findall(r"(1[89]\d\d|20\d\d)", text)
    year = years[-1] if years else None
    title = re.sub(r"\(?\b(1[89]\d\d|20\d\d)\b\)?", "", text) if year else text
    return re.sub(r"[^a-z0-9]", "", title.lower()), year

def normalise(text):
    return split_title(text)[0]

def ask(model, question, seed):
    films = [f for tier in question["tiers"] for f in tier]
    shuffled = films[:]
    random.Random(seed).shuffle(shuffled)
    prompt = (f"Order these films by how similar they are to {question['target']}, "
              f"most similar first: {'; '.join(shuffled)}. "
              'Answer JSON: {"order":["Title (Year)", ...]} with every film, no extras.')
    cfg = {"responseMimeType": "application/json",
           "responseSchema": {"type": "OBJECT",
                              "properties": {"order": {"type": "ARRAY", "items": {"type": "STRING"}}},
                              "required": ["order"]}}
    if THINKING:
        cfg["thinkingConfig"] = {"thinkingBudget": THINKING}
    payload = {"contents": [{"parts": [{"text": prompt}]}], "generationConfig": cfg}
    req = urllib.request.Request(
        f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent?key={KEY}",
        json.dumps(payload).encode(), {"Content-Type": "application/json"})
    start = time.monotonic()
    with urllib.request.urlopen(req, timeout=CEILING_S) as r:
        d = json.load(r)
    elapsed = time.monotonic() - start
    text = "".join(p.get("text", "") for p in d["candidates"][0]["content"]["parts"])
    order = json.loads(text[text.find("{"):text.rfind("}") + 1])["order"]
    return order, elapsed

def score(question, order):
    """Pairwise tier accuracy, weighted by how much of the list came back.

    Returns the score and the number of pairs it was drawn from, because a
    number without its sample size cannot be argued with.
    """
    tier_of, place = {}, {}
    for t, tier in enumerate(question["tiers"]):
        for film in tier:
            title, year = split_title(film)
            tier_of[title] = (t, year)
    for i, answer in enumerate(order):
        key, year = split_title(answer)
        # Exact title and year first; then a prefix, but only within the
        # same year, so "Ghost in the Shell" cannot swallow its own sequel
        # and Levinson's Avalon cannot stand in for Oshii's.
        hit = next((k for k in tier_of if (k, year) == (key, tier_of[k][1])), None)
        if hit is None:
            same_year = [k for k in tier_of if tier_of[k][1] == year]
            hit = next((k for k in same_year
                        if k.startswith(key[:12]) or key.startswith(k[:12])), None)
        if hit is None and year is None:
            # An answer that gave no year is usable only if its title is
            # unambiguous among the candidates.
            named = [k for k in tier_of if k == key]
            hit = named[0] if len(named) == 1 else None
        if hit is not None and hit not in place:
            place[hit] = i
    right = total = 0
    for a, (ta, _ya) in tier_of.items():
        for b, (tb, _yb) in tier_of.items():
            if ta < tb and a in place and b in place:
                total += 1
                right += place[a] < place[b]
    return (right / total if total else 0.0) * (len(place) / len(tier_of)), total

def classify(err):
    if isinstance(err, urllib.error.HTTPError):
        try: message = json.load(err)["error"]["message"]
        except Exception: message = ""
        if err.code == 404: return "gone"
        if err.code in (402, 403): return "not in tier"
        if err.code == 429: return "quota"
        if err.code == 503: return "busy"
        if "Interactions API" in message: return "other API"
        return str(err.code)
    if isinstance(err, TimeoutError) or "timed out" in str(err):
        return f"no answer in {CEILING_S:.0f}s"
    return f"error: {str(err)[:40]}"

def measure(model):
    """Every question in every order, or an early exit when too slow."""
    cells, slowest, pairs = {}, 0.0, 0
    for q, question in enumerate(QUESTIONS):
        for seed in range(REPEATS):
            try:
                order, elapsed = ask(model, question, seed)
            except Exception as e:
                return model, None, slowest, classify(e), cells, pairs
            slowest = max(slowest, elapsed)
            if elapsed > BUDGET_S:
                # Over budget is over: the app would have abandoned this
                # request, so the remaining questions teach nothing.
                return model, None, slowest, f"too slow ({elapsed:.1f}s)", cells, pairs
            got, total = score(question, order)
            cells[(q, seed)] = got
            pairs += total
    return model, statistics.fmean(cells.values()), slowest, None, cells, pairs

with urllib.request.urlopen(f"https://generativelanguage.googleapis.com/v1beta/models?key={KEY}",
                            timeout=40) as r:
    listed = json.load(r)["models"]
SKIP = ("tts", "image", "embedding", "aqa", "learnlm", "veo", "imagen", "lyria",
        "transcribe", "robotics", "banana", "computer-use", "antigravity", "deep-research")
names = sys.argv[1:] or [m["name"].split("/")[-1] for m in listed
                         if "generateContent" in m.get("supportedGenerationMethods", [])
                         and not any(s in m["name"] for s in SKIP)]

print(f"{len(names)} candidates, {WORKERS} at a time, budget {BUDGET_S:.0f}s, "
      f"thinking {THINKING or 'off'}\n")
with ThreadPoolExecutor(max_workers=WORKERS) as pool:
    results = list(pool.map(measure, names))

# A quota or a busy answer can be this run's own doing: five workers on one
# key look like a burst. Anything that failed that way is asked again on its
# own before the verdict is believed.
again = [r[0] for r in results if r[3] in ("quota", "busy")]
if again:
    print(f"re-checking {len(again)} one at a time (a burst of our own can read as a quota)\n")
    retried = {}
    for model in again:
        retried[model] = measure(model)
        time.sleep(2)
    results = [retried.get(r[0], r) for r in results]

ok = [r for r in results if r[1] is not None]
for model, verdict, slowest, failure, cells, pairs in sorted(
        results, key=lambda r: (r[1] is None, -(r[1] or 0))):
    if verdict is None:
        print(f"  --    {model:34} {failure}")
    else:
        print(f"  {verdict:.2f}  {model:34} slowest {slowest:5.1f}s")

print(f"\nusable within {BUDGET_S:.0f}s: {len(ok)} of {len(names)}")
print(f"{len(QUESTIONS)} questions x {REPEATS} orders each; "
      f"{ok[0][5] if ok else 0} scored pairs per model\n")
for model, verdict, slowest, _f, cells, _p in sorted(ok, key=lambda r: (-r[1], r[2])):
    lo, hi = min(cells.values()), max(cells.values())
    print(f"  {verdict:.2f}  [{lo:.2f}-{hi:.2f}]  {slowest:5.1f}s  {model}")
if ok:
    ranked = sorted(ok, key=lambda r: (-r[1], r[2]))
    best = ranked[0]
    print(f"\nfirst choice: {best[0]} (judgement {best[1]:.2f}, slowest {best[2]:.1f}s)")
    # Paired against the leader on identical questions and identical orders.
    # A pooled spread mostly measures how hard the questions are; this
    # measures the models, which is the only comparison worth making. A
    # lead is called only when it survives a sign test (a model that is no
    # better than a coin toss against the leader is not behind it).
    print("\nhead to head against the leader, cell by cell:")
    leader = best[4]
    for model, verdict, _s, _f, cells, _p in ranked[1:]:
        shared = [k for k in leader if k in cells]
        wins = sum(cells[k] > leader[k] for k in shared)
        losses = sum(cells[k] < leader[k] for k in shared)
        drawn = len(shared) - wins - losses
        gap = statistics.fmean([leader[k] - cells[k] for k in shared]) if shared else 0.0
        # Two-sided sign test over the decided cells.
        decided = wins + losses
        verdict_text = "behind" if decided and min(wins, losses) / decided < 0.2 else "not separated"
        print(f"  {model:34} leader wins {losses:2}, loses {wins:2}, draws {drawn:2}"
              f"   mean gap {gap:+.3f}   {verdict_text}")
    print("\nfallback order: " + " -> ".join(m for m, *_ in ranked))
