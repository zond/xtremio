"""Score a model on the thing we actually want: open recommendation.

The sort benchmark next door hands a model a list and asks it to order
them. This asks the real question -- "ten films like this one" -- and
scores the answer against a researched key of 45-60 graded films per
target.

Five numbers, because one number would hide the failures that matter:

  relevance   how good the films it found are (the key's grade, 1-3)
  tone        whether they *feel* like the target (the key's tone, 0-2),
              which is a different question and, I expect, a harder one
  real        how many of its ten are films that exist at all, checked
              against TMDB -- the only failure that would embarrass the app
  consistent  how much a model's own repeated runs agree, which decides
              whether the row changes every time you open a title
  breadth     how many of the seven kinds of connection its answers span,
              so that reciting one director's filmography does not read as
              knowledge

Anything it suggests that is real but not in the key is written to a pool
file for rating and folding back in. Without that step the benchmark
quietly rewards models that agree with our researchers.

  G_KEY=... TMDB=... python3 recommend_bench.py [model ...]
"""
import glob, json, os, re, statistics, sys, time, urllib.error, urllib.parse, urllib.request

TMDB = os.environ["TMDB"]
KEYS = {"google": os.environ.get("G_KEY"), "anthropic": os.environ.get("A_KEY"),
        "mistral": os.environ.get("M_KEY"), "openrouter": os.environ.get("OR_KEY")}
RUNS = int(os.environ.get("RUNS", "3"))
WANTED = int(os.environ.get("WANTED", "10"))
HERE = os.path.dirname(os.path.abspath(__file__))
POOL = os.path.join(HERE, "pool_unrated.json")
# What the app would ask for. Stated here rather than buried in the call,
# because the wording is a thing we are measuring, not a detail.
ASK_FOR_FEEL = os.environ.get("ASK_FOR_FEEL", "1") == "1"

def norm(text):
    years = re.findall(r"(1[89]\d\d|20\d\d)", text)
    year = years[-1] if years else None
    title = re.sub(r"\(?\b(1[89]\d\d|20\d\d)\b\)?", "", text) if year else text
    title = re.sub(r"^(the|a|an)\b", "", title.strip().lower())
    return re.sub(r"[^a-z0-9]", "", title), year

def load_keys():
    """Each key, plus what drawing from it at random would score.

    The keys are not equally kind. Forty of the sixty films around The
    Seventh Continent share its texture, because Haneke sits at the centre
    of a tradition defined by texture; seven of the fifty-nine around Wave
    Twisters do. A tone score of 0.85 is therefore an easy mark on one and
    a remarkable one on the other, and averaging them straight would
    flatter a model for the company its targets keep. So every score is
    reported beside what chance would have got, and what is compared
    across targets is the distance between them.
    """
    keys = {}
    for path in sorted(glob.glob(os.path.join(HERE, "gold_*.json"))):
        data = json.load(open(path))
        index = {}
        for e in data["entries"]:
            title, year = norm(f"{e['title']} ({e['year']})")
            index[(title, year)] = e
        entries = list(index.values())
        keys[data["target"]] = {
            "index": index,
            "chance_relevance": statistics.fmean(e["grade"] for e in entries) / 3,
            "chance_tone": statistics.fmean(e.get("tone", 0) for e in entries) / 2,
        }
    return keys

def prompt_for(target):
    feel = (" Prefer films that *feel* like it -- the same register, pace and "
            "texture -- over films that merely share its premise."
            if ASK_FOR_FEEL else "")
    return (f"Name {WANTED} films to watch next for someone who loved {target}.{feel} "
            'Answer JSON only: {"films":[{"title":"","year":0,"why":"under 12 words"}]}. '
            "Real, released films only; do not include the film itself.")

def post(url, payload, headers, timeout=180):
    req = urllib.request.Request(url, json.dumps(payload).encode(),
                                 {"Content-Type": "application/json", **headers})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)

def ask(spec, target):
    """One provider per prefix; the answer shape is the same everywhere.

    Every provider is asked exactly the same question, in JSON mode where
    it has one, and the reply is parsed by finding the outermost braces --
    which is what survives a model that wraps its JSON in prose.
    """
    provider, _, model = spec.partition(":")
    prompt = prompt_for(target)
    start = time.monotonic()
    if provider == "google":
        d = post(f"https://generativelanguage.googleapis.com/v1beta/models/"
                 f"{model}:generateContent?key={KEYS['google']}",
                 {"contents": [{"parts": [{"text": prompt}]}],
                  "generationConfig": {"temperature": 0.7,
                                       "responseMimeType": "application/json"}}, {})
        text = "".join(p.get("text", "")
                       for p in d["candidates"][0]["content"]["parts"])
    elif provider == "anthropic":
        payload = {"model": model, "max_tokens": 2048,
                   "system": "You recommend films. Real, released titles only. JSON only.",
                   "messages": [{"role": "user", "content": prompt}]}
        if "-5" not in model:                 # newer models retired the parameter
            payload["temperature"] = 0.7
        d = post("https://api.anthropic.com/v1/messages", payload,
                 {"x-api-key": KEYS["anthropic"], "anthropic-version": "2023-06-01"})
        text = "".join(b.get("text", "") for b in d["content"] if b["type"] == "text")
    elif provider in ("mistral", "openrouter"):
        host = ("https://api.mistral.ai/v1/chat/completions" if provider == "mistral"
                else "https://openrouter.ai/api/v1/chat/completions")
        d = post(host, {"model": model, "temperature": 0.7,
                        "response_format": {"type": "json_object"},
                        "messages": [
                            {"role": "system",
                             "content": "You recommend films. Real, released titles only. JSON only."},
                            {"role": "user", "content": prompt}]},
                 {"Authorization": f"Bearer {KEYS[provider]}"})
        text = d["choices"][0]["message"]["content"]
    else:
        raise ValueError(f"unknown provider in {spec!r}")
    films = json.loads(text[text.find("{"):text.rfind("}") + 1])["films"]
    return films, time.monotonic() - start

def exists_on_tmdb(title, year):
    url = "https://api.themoviedb.org/3/search/movie?" + urllib.parse.urlencode(
        {"query": title, "year": year} if year else {"query": title})
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TMDB}"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            results = json.load(r).get("results", [])
    except Exception:
        return True          # the benefit of the doubt: our lookup failed, not the model
    for m in results[:5]:
        got = (m.get("release_date") or "")[:4]
        if not year or (got.isdigit() and abs(int(got) - int(year)) <= 1):
            return True
    return False

def judge(spec, target, key):
    runs, pool, times = [], [], []
    for _ in range(RUNS):
        try:
            films, elapsed = ask(spec, target)
        except Exception as e:
            print(f"    {target}: {str(e)[:70]}")
            continue
        times.append(elapsed)
        seen = []
        for f in films:
            title, year = norm(f"{f.get('title','')} ({f.get('year','')})")
            entry = key.get((title, year))
            if entry is None and year:       # tolerate a year a season out
                entry = next((v for (t, y), v in key.items()
                              if t == title and y and abs(int(y) - int(year)) <= 1), None)
            if entry is None and year and len(title) >= 8:
                # A film the world shortens: nobody types "Jeanne Dielman, 23,
                # quai du Commerce, 1080 Bruxelles". Accept a prefix, but only
                # within the same year, so this cannot quietly merge two films.
                entry = next((v for (t, y), v in key.items()
                              if y and abs(int(y) - int(year)) <= 1
                              and (t.startswith(title) or title.startswith(t))), None)
            seen.append((f.get("title"), f.get("year"), entry))
            if entry is None:
                # Which model said it, so a failure mode can be attributed
                # rather than blamed on whoever was tested first.
                pool.append({"target": target, "title": f.get("title"),
                             "year": f.get("year"), "why": f.get("why", ""),
                             "model": spec})
        runs.append(seen)
        time.sleep(1)
    return runs, pool, times

def report(model, keys):
    all_pool, lift_rel, lift_ton, cov, cons, breadth, slowest = [], [], [], [], [], [], 0.0
    per_target = []
    for target, key_data in keys.items():
        key = key_data["index"]
        runs, pool, times = judge(model, target, key)
        if not runs:
            continue
        slowest = max([slowest] + times)
        all_pool += pool
        target_rel, target_ton = [], []
        for seen in runs:
            found = [e for _t, _y, e in seen if e]
            cov.append(len(found) / max(1, len(seen)))
            if found:
                target_rel.append(statistics.fmean(e["grade"] for e in found) / 3)
                target_ton.append(statistics.fmean(e.get("tone", 0) for e in found) / 2)
                breadth.append(len({e["basis"] for e in found}) / 7)
        if target_rel:
            got_rel, got_ton = statistics.fmean(target_rel), statistics.fmean(target_ton)
            lift_rel.append(got_rel - key_data["chance_relevance"])
            lift_ton.append(got_ton - key_data["chance_tone"])
            per_target.append((target, got_rel, key_data["chance_relevance"],
                               got_ton, key_data["chance_tone"]))
        # Two runs agree on how much? Titles only; the key is not involved.
        if len(runs) > 1:
            sets = [{norm(f"{t} ({y})") for t, y, _e in r} for r in runs]
            pairs = [(a, b) for i, a in enumerate(sets) for b in sets[i + 1:]]
            cons += [len(a & b) / max(1, len(a | b)) for a, b in pairs]
    # Only the suggestions nobody has rated need a TMDB lookup.
    checked, unreal = {}, 0
    for item in all_pool:
        signature = (item["title"], item["year"])
        if signature not in checked:
            checked[signature] = exists_on_tmdb(item["title"], item["year"])
            time.sleep(0.12)
        if not checked[signature]:
            unreal += 1
    print(f"\n{model}")
    if not per_target:
        print("  answered nothing -- see the errors above")
        return all_pool
    print(f"  {'target':30} {'relevance':>18}   {'tone':>18}")
    for target, got_r, chance_r, got_t, chance_t in per_target:
        print(f"  {target:30} {got_r:.2f} vs {chance_r:.2f} chance   "
              f"{got_t:.2f} vs {chance_t:.2f} chance")
    print(f"  {'':30} {'':>7}{statistics.fmean(lift_rel):+.2f} lift   "
          f"{'':>7}{statistics.fmean(lift_ton):+.2f} lift")
    print(f"  in the key  {statistics.fmean(cov):.2f}   the rest are pooled for rating")
    print(f"  real        {1 - unreal / max(1, len(all_pool)):.2f}   of the unrated ones, "
          f"{unreal} of {len(all_pool)} are not films")
    print(f"  consistent  {statistics.fmean(cons):.2f}   agreement between its own runs"
          if cons else "  consistent  --")
    print(f"  breadth     {statistics.fmean(breadth):.2f}   of the seven kinds of connection")
    print(f"  slowest     {slowest:.1f}s")
    return all_pool

keys = load_keys()
print(f"{len(keys)} answer keys: " + ", ".join(keys))
print(f"{RUNS} runs of {WANTED} films each; asking for feel: {ASK_FOR_FEEL}")
pool = []
for model in (sys.argv[1:] or ["gemini-3.1-flash-lite"]):
    pool += report(model, keys)
if pool:
    json.dump(pool, open(POOL, "w"), indent=1)
    print(f"\n{len(pool)} suggestions not in any key, written to {os.path.basename(POOL)} "
          f"for rating")
