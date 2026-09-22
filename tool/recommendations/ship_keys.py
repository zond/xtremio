"""Cut the answer keys down to what ships in the app.

`keys/gold_*.json` carries, for every one of the 528 films, what it is,
why it is on the list, which of the seven kinds of connection it rests on
and a source URL for the claim. None of that is any use on a television:
the check the app runs -- "is the model you configured any good" --
needs a title, a year, the `grade` and the `tone`, and nothing else.

So the shipped asset is those four fields plus each key's target, which
is about 30 KB against 900. The reasoning, the citations and the `what`
lines stay here, where the benchmark reads them.

Run after `fold_pool.py` has changed a key, and commit the asset:

    python3 tool/recommendations/ship_keys.py
"""
import glob
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
ASSET = os.path.join(REPO, "assets", "recommendations", "answer_keys.json")

keys = []
for path in sorted(glob.glob(os.path.join(HERE, "keys", "gold_*.json"))):
    data = json.load(open(path))
    keys.append({
        "target": data["target"],
        "films": [
            {
                "title": entry["title"],
                "year": entry["year"],
                "grade": entry["grade"],
                "tone": entry["tone"],
            }
            for entry in data["entries"]
        ],
    })

os.makedirs(os.path.dirname(ASSET), exist_ok=True)
with open(ASSET, "w") as out:
    json.dump({"keys": keys}, out, ensure_ascii=False, separators=(",", ":"))
    out.write("\n")

films = sum(len(key["films"]) for key in keys)
print(f"{len(keys)} keys, {films} films, {os.path.getsize(ASSET) / 1024:.0f} KB")
