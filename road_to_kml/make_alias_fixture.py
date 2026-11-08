#!/usr/bin/env python3
"""
Recompute the alias-parity fixture with the current road_aliases.py.

The inputs (about 27,000 road names with a state and county, 5,000 name pairs, a few
state spellings and describe() calls) come from an existing fixture, normally the
zipped copy in RoadKit/Tests/RoadKitTests/Fixtures/aliases.zip. Every expected
answer is worked out again here, so the Swift tests always compare against the
Python as it is now.

    python make_alias_fixture.py IN.(json|zip) OUT.json
"""
import json
import os
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import road_aliases as ra  # noqa: E402


def load(path):
    if path.endswith(".zip"):
        with zipfile.ZipFile(path) as z:
            return json.loads(z.read("aliases.json").decode("utf-8"))
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def case(name, state, county):
    ctx, cty = ra._ctx(state), ra._county(county)
    elems = ra.parse(name, ctx, cty)
    return {
        "name": name, "state": state, "county": county,
        "regex": ra.overpass_tag_regex(name, state, county),
        "kinds": [e.kind for e in elems],
        "alts": [list(e.alts) for e in elems],
        "variants": ra.expand_variants(name, state, limit=30, county=county),
        "count": ra.count_variants(name, state, county),
        "hint": ra.rename_hint(name, state, county),
    }


def pair(q, state, county, cand):
    m = ra.RoadMatcher(q, state, county)
    return {"q": q, "state": state, "county": county, "cand": cand,
            "contains": m.matches(cand), "exact": m.matches(cand, contains=False)}


def main(src, dst):
    old = load(src)
    new = {
        "cases": [case(c["name"], c["state"], c["county"]) for c in old["cases"]],
        "pairs": [pair(p["q"], p["state"], p["county"], p["cand"]) for p in old["pairs"]],
        "states": {k: ra.resolve_state(k) for k in old["states"]},
        "describe": {},
    }
    for k in old["describe"]:
        name, st = k.split("|", 1)
        new["describe"][k] = ra.describe(name, None if st in ("", "None") else st)
    with open(dst, "w", encoding="utf-8") as fh:
        json.dump(new, fh, ensure_ascii=False)
    changed = sum(a != b for a, b in zip(old["cases"], new["cases"]))
    print(f"{len(new['cases'])} cases, {len(new['pairs'])} pairs written to {dst}"
          + (f" ({changed} case(s) differ from the input fixture)" if changed else ""))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
