"""Check an answer key against TMDB: does every film exist, with that year?"""
import json, os, sys, time, urllib.parse, urllib.request

TOKEN = os.environ["TMDB"]

def tmdb(path, **params):
    url = f"https://api.themoviedb.org/3/{path}?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=25) as r:
        return json.load(r)

def check(title, year):
    """Exact-ish title match within a year either side, searching both the
    stated year and none: TMDB dates some films by festival, some by release."""
    seen = []
    for params in ({"query": title, "year": year}, {"query": title}):
        try:
            results = tmdb("search/movie", **params).get("results", [])
        except Exception as e:
            return None, f"search failed: {str(e)[:40]}"
        for m in results[:8]:
            got = (m.get("release_date") or "")[:4]
            seen.append(f"{m['title']} ({got or '?'})")
            if abs(int(got) - year) <= 1 if got.isdigit() else False:
                return m, None
    return None, "no match; TMDB offers " + (", ".join(seen[:4]) or "nothing")

path = sys.argv[1]
data = json.load(open(path))
entries = data["entries"]
print(f"{data['target']}: {len(entries)} entries\n")
missing = fields = 0
for e in entries:
    for required in ("title", "year", "grade", "why", "basis", "what"):
        if required not in e or not str(e.get(required)).strip():
            print(f"  FIELD  {e.get('title','?')}: no {required}")
            fields += 1
    hit, problem = check(e["title"], int(e["year"]))
    if problem:
        missing += 1
        print(f"  CHECK  {e['title']} ({e['year']}) - {problem}")
    time.sleep(0.15)
grades = {}
for e in entries:
    grades[e["grade"]] = grades.get(e["grade"], 0) + 1
print(f"\n{len(entries) - missing}/{len(entries)} verified on TMDB; "
      f"{fields} missing fields; grades {dict(sorted(grades.items(), reverse=True))}")
