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
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))

def norm(text):
    return re.sub(r"[^a-z0-9]", "", re.sub(r"^(the|a|an)\b", "", str(text).strip().lower()))

rated = json.load(open(os.path.join(HERE, "pool_rated.json")))
files = {json.load(open(os.path.join(HERE, f)))["target"]: os.path.join(HERE, f)
         for f in os.listdir(HERE) if f.startswith("gold_") and f.endswith(".json")}

added = skipped = 0
for target, entries in rated.items():
    path = files.get(target)
    if not path:
        print(f"  no key for {target}"); continue
    data = json.load(open(path))
    have = {(norm(e["title"]), str(e["year"])) for e in data["entries"]}
    for entry in entries:
        signature = (norm(entry["title"]), str(entry["year"]))
        if signature in have:
            skipped += 1
            continue
        entry["pooled"] = True      # it came from a model, not from the research
        data["entries"].append(entry)
        have.add(signature)
        added += 1
    json.dump(data, open(path, "w"), indent=1, ensure_ascii=False)
    print(f"  {target}: {len(data['entries'])} entries")
print(f"\n{added} folded in, {skipped} already present")
