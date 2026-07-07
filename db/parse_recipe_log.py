#!/usr/bin/env python3
"""Parses grepped RECIPEDUMP log lines into clean recipes.jsonl.

Usage:
    python3 parse_recipe_log.py recipes_raw.txt recipes.jsonl

recipes_raw.txt is produced by:
    grep "RECIPEDUMP " logs/latest.log > recipes_raw.txt
after running kubejs/dump_recipes.js. Each output line in recipes.jsonl is
{"id": ..., "type": ..., "json": {...}} - the format import_recipes.py expects.
"""

import json
import sys
from collections import Counter

MARKER = "RECIPEDUMP "


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src_path, out_path = sys.argv[1], sys.argv[2]

    total = ok = bad = 0
    bad_samples = []
    type_counter = Counter()

    with open(src_path, "r", encoding="utf-8", errors="replace") as src, \
         open(out_path, "w", encoding="utf-8") as out:
        for line in src:
            idx = line.find(MARKER)
            if idx == -1:
                continue
            total += 1
            rest = line[idx + len(MARKER):].rstrip("\n")
            sp = rest.find(" ")
            if sp == -1:
                bad += 1
                if len(bad_samples) < 5:
                    bad_samples.append(rest[:200])
                continue
            rid, jtext = rest[:sp], rest[sp + 1:]
            if jtext == "<no-json>":
                bad += 1
                continue
            try:
                j = json.loads(jtext)
            except json.JSONDecodeError as e:
                bad += 1
                if len(bad_samples) < 5:
                    bad_samples.append(f"{rid}: {e}")
                continue
            ok += 1
            rtype = j.get("type") if isinstance(j, dict) else None
            type_counter[rtype] += 1
            out.write(json.dumps({"id": rid, "type": rtype, "json": j}) + "\n")

    print(f"total lines matched: {total}")
    print(f"parsed ok: {ok}")
    print(f"failed to parse: {bad}")
    print(f"distinct recipe types: {len(type_counter)}")
    print()
    print("Top 10 recipe types:")
    for t, c in type_counter.most_common(10):
        print(f"  {c:6d}  {t}")
    if bad_samples:
        print()
        print("sample failures:")
        for s in bad_samples:
            print(" ", s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
