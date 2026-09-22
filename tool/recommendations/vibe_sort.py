"""Sort by feel, not by relatedness — the fast test, built from the keys.

The recommendation benchmark is the honest one and takes minutes. This is
its cheap relative: one call per target, a list handed over, and a score in
a couple of seconds. It exists because the application needs a check it can
run when you paste an API key, and because a fast test that predicts the
slow one is worth having.

What makes it hard is the salting. Each list carries films the key rates as
*highly relevant and tonally opposite* (Watchmen for Glass: the same
argument about comic books, none of the quiet) and films rated *barely
relevant and tonally identical* (Bug for Glass: one room, no spectacle, an
escalation you cannot look away from). A model that sorts by how related
the films are will put the first group top and score below chance. Only
attention to what a film is like to sit through scores well.

Scored by pairwise tone accuracy: over every pair from different tone
tiers, how often the model put the one that feels nearer first. The score
a relevance-sorted answer would get is printed beside it, so the trap is
visible rather than asserted.

  G_KEY=... python3 vibe_sort.py [model ...]
"""
import glob, json, os, random, re, statistics, sys, time, urllib.error, urllib.request

KEYS = {"google": os.environ.get("G_KEY"), "anthropic": os.environ.get("A_KEY"),
        "mistral": os.environ.get("M_KEY"), "openrouter": os.environ.get("OR_KEY")}
HERE = os.path.dirname(os.path.abspath(__file__))
PER_TIER = int(os.environ.get("PER_TIER", "4"))

def split_title(text):
    years = re.findall(r"(1[89]\d\d|20\d\d)", str(text))
    year = years[-1] if years else None
    title = re.sub(r"\(?\b(1[89]\d\d|20\d\d)\b\)?", "", str(text)) if year else str(text)
    return re.sub(r"[^a-z0-9]", "", title.lower()), year

def questions():
    """One list per target: four films per tone tier, the divergent ones first.

    Sorting each tier by how far it pulls against tone means the hardest
    available films are chosen -- the relevant-but-cold and the
    thin-but-warm -- rather than whatever the key happens to list first.
    """
    out = []
    for path in sorted(glob.glob(os.path.join(HERE, "keys", "gold_*.json"))):
        data = json.load(open(path))
        tiers = []
        for tone in (2, 1, 0):
            pool = [e for e in data["entries"] if e.get("tone") == tone]
            # For tone 2 the awkward ones are the least relevant; for tone 0,
            # the most. Tone 1 is ordered arbitrarily but stably.
            pool.sort(key=lambda e: e["grade"] if tone == 2 else -e["grade"])
            tiers.append(pool[:PER_TIER])
        if all(tiers):
            out.append({"target": data["target"], "tiers": tiers})
    return out

def ask(spec, question, seed):
    films = [f"{e['title']} ({e['year']})" for tier in question["tiers"] for e in tier]
    shuffled = films[:]
    random.Random(seed).shuffle(shuffled)
    prompt = (f"Order these films by how much each one *feels* like "
              f"{question['target']} -- the same register, pace, palette and texture, "
              f"what it is like to sit through -- rather than by how related they are "
              f"in subject, director or genre. Most alike in feel first: "
              f"{'; '.join(shuffled)}. "
              'Answer JSON only: {"order":["Title (Year)", ...]} with every film once.')
    provider, _, model = spec.partition(":")
    start = time.monotonic()
    def post(url, payload, headers):
        req = urllib.request.Request(url, json.dumps(payload).encode(),
                                     {"Content-Type": "application/json", **headers})
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)
    if provider == "google":
        d = post(f"https://generativelanguage.googleapis.com/v1beta/models/"
                 f"{model}:generateContent?key={KEYS['google']}",
                 {"contents": [{"parts": [{"text": prompt}]}],
                  "generationConfig": {"temperature": 0.3,
                                       "responseMimeType": "application/json"}}, {})
        text = "".join(p.get("text", "") for p in d["candidates"][0]["content"]["parts"])
    elif provider == "anthropic":
        payload = {"model": model, "max_tokens": 2048, "system": "JSON only.",
                   "messages": [{"role": "user", "content": prompt}]}
        if "-5" not in model:
            payload["temperature"] = 0.3
        d = post("https://api.anthropic.com/v1/messages", payload,
                 {"x-api-key": KEYS["anthropic"], "anthropic-version": "2023-06-01"})
        text = "".join(b.get("text", "") for b in d["content"] if b["type"] == "text")
    else:
        host = ("https://api.mistral.ai/v1/chat/completions" if provider == "mistral"
                else "https://openrouter.ai/api/v1/chat/completions")
        d = post(host, {"model": model, "temperature": 0.3,
                        "response_format": {"type": "json_object"},
                        "messages": [{"role": "system", "content": "JSON only."},
                                     {"role": "user", "content": prompt}]},
                 {"Authorization": f"Bearer {KEYS[provider]}"})
        text = d["choices"][0]["message"]["content"]
    order = json.loads(text[text.find("{"):text.rfind("}") + 1])["order"]
    return order, time.monotonic() - start

def score(question, order):
    """Pairwise tone accuracy, weighted by how much of the list came back."""
    want, place = {}, {}
    for tone_rank, tier in enumerate(question["tiers"]):     # 0 = feels most alike
        for e in tier:
            want[split_title(f"{e['title']} ({e['year']})")] = tone_rank
    for i, answer in enumerate(order):
        key = split_title(answer)
        hit = key if key in want else next(
            (k for k in want if k[1] == key[1] and len(key[0]) >= 6
             and (k[0].startswith(key[0]) or key[0].startswith(k[0]))), None)
        if hit and hit not in place:
            place[hit] = i
    right = total = 0
    for a, ra in want.items():
        for b, rb in want.items():
            if ra < rb and a in place and b in place:
                total += 1
                right += place[a] < place[b]
    return (right / total if total else 0.0) * (len(place) / len(want))

def relevance_sorted_score(question):
    """What answering by relatedness alone would score -- the trap, measured."""
    ranked = sorted(((e, rank) for rank, tier in enumerate(question["tiers"]) for e in tier),
                    key=lambda pair: -pair[0]["grade"])
    order = [f"{e['title']} ({e['year']})" for e, _rank in ranked]
    return score(question, order)

QUESTIONS = questions()
print(f"{len(QUESTIONS)} targets, {PER_TIER} films per tone tier")
trap = statistics.fmean(relevance_sorted_score(q) for q in QUESTIONS)
print(f"answering by relatedness alone would score {trap:.2f}; chance is 0.50\n")
for spec in (sys.argv[1:] or ["google:gemini-3.1-flash-lite"]):
    scores, slowest = [], 0.0
    for q in QUESTIONS:
        try:
            order, elapsed = ask(spec, q, 0)
        except Exception as e:
            print(f"  {spec}: {q['target']}: {str(e)[:60]}")
            continue
        scores.append(score(q, order))
        slowest = max(slowest, elapsed)
    if scores:
        print(f"  {statistics.fmean(scores):.2f}  {spec:44} slowest {slowest:5.1f}s")
