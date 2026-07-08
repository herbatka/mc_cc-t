#!/usr/bin/env python3
"""Parses grepped TAGDUMP log lines into clean tags.jsonl.

Usage:
    python3 parse_tag_log.py tags_raw.txt tags.jsonl

tags_raw.txt is produced by:
    grep "TAGDUMP " logs/latest.log > tags_raw.txt
after running kubejs/dump_all_tags.js. Each tag can appear multiple times
in the log (ServerEvents.tags fires repeatedly during startup, and only a
later firing has fully-resolved data) - this keeps the LAST occurrence of
each tag, which is what has real data.
"""

import json
import sys

MARKER = "TAGDUMP "


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        return 1
    src_path, out_path = sys.argv[1], sys.argv[2]

    last_seen = {}  # tag_id -> raw json text, last occurrence wins
    with open(src_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            idx = line.find(MARKER)
            if idx == -1:
                continue
            rest = line[idx + len(MARKER):].rstrip("\n")
            sp = rest.find(" ")
            if sp == -1:
                continue
            tag_id, jtext = rest[:sp], rest[sp + 1:]
            last_seen[tag_id] = jtext

    ok = empty = bad = 0
    bad_samples = []
    with open(out_path, "w", encoding="utf-8") as out:
        for tag_id, jtext in last_seen.items():
            try:
                items = json.loads(jtext)
                if not isinstance(items, list):
                    raise ValueError("not a list")
            except Exception:
                bad += 1
                if len(bad_samples) < 5:
                    bad_samples.append((tag_id, jtext[:150]))
                continue
            ok += 1
            if len(items) == 0:
                empty += 1
            out.write(json.dumps({"tag": tag_id, "items": items}) + "\n")

    print(f"distinct tags: {len(last_seen)}")
    print(f"parsed ok: {ok} (of which {empty} empty)")
    print(f"failed to parse: {bad}")
    if bad_samples:
        print()
        print("sample failures:")
        for tid, sample in bad_samples:
            print(f"  {tid}: {sample}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
