"""Fold rated suggestions into the answer keys.

The keys started as research. Anything a model suggested that the research
had not listed went to a pool, was rated by the same rubric, and comes back
here. Without this step the benchmark scores agreement with our
researchers rather than knowledge of films.

Two things this changes, and both are intended:

  * a suggestion nobody had listed stops counting as a miss, so a model
    that knows something we did not is no longer punished for it;
  * the keys gain entries graded 0 -- films that were suggested and do not
    belong -- which the research would never have produced, since nobody
    lists what does not fit. A model that suggests one now scores zero for
    it rather than nothing at all.

The second has a cost worth stating: the keys drift towards what models
suggest, and the chance baseline moves with them. That is the standard
price of pooling, and it is why the baseline is recomputed from the key
after folding rather than remembered from before.
"""
import json, os, re, sys, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))

def norm(text):
    """As `recommend_bench.norm`, minus the year: accents folded, not dropped."""
    text = unicodedata.normalize("NFKD", str(text))
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]", "", re.sub(r"^(the|a|an)\b", "", text.strip().lower()))

def names_of(entry):
    """Every spelling an entry answers to: its title, its `aka`, and the
    part before a colon. A pooled rating that arrives under one of them is
    the film the key already holds, not a new one -- without this the key
    gains `The Golem` beside `The Golem: How He Came into the World` and
    `Cache` beside `Cach\u00e9`, each rated twice and counted twice."""
    names = [entry["title"], *([entry["aka"]] if entry.get("aka") else [])]
    for name in list(names):
        head = str(name).split(":")[0].strip()
        if head and head != name:
            names.append(head)
    for name in list(names):
        # `Birdman or (The Unexpected Virtue of Ignorance)` -- a trailing
        # alternative title, which is the other way a film carries two
        # names and has no colon in it.
        head = re.sub(r"\s+or\s+\(.*\)\s*$", "", str(name)).strip()
        if head and head != name:
            names.append(head)
    return names

rated = json.load(open(os.path.join(HERE, "pool_rated.json")))
KEYS = os.path.join(HERE, "keys")
files = {json.load(open(os.path.join(KEYS, f)))["target"]: os.path.join(KEYS, f)
         for f in os.listdir(KEYS) if f.startswith("gold_") and f.endswith(".json")}
if not files:
    sys.exit(f"no answer keys found in {KEYS}")

added = skipped = 0
for target, entries in rated.items():
    path = files.get(target)
    if not path:
        print(f"  no key for {target}"); continue
    data = json.load(open(path))
    have = {(norm(n), str(e["year"])) for e in data["entries"] for n in names_of(e)}
    for entry in entries:
        if any((norm(n), str(entry["year"])) in have for n in names_of(entry)):
            skipped += 1
            continue
        entry["pooled"] = True      # it came from a model, not from the research
        data["entries"].append(entry)
        have.update((norm(n), str(entry["year"])) for n in names_of(entry))
        added += 1
    json.dump(data, open(path, "w"), indent=1, ensure_ascii=False)
    print(f"  {target}: {len(data['entries'])} entries")
print(f"\n{added} folded in, {skipped} already present")
