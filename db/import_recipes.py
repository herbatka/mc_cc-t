#!/usr/bin/env python3
"""Imports a KubeJS recipe + tag dump into Postgres (see schema.sql).

Usage:
    python3 import_recipes.py recipes.jsonl tags.jsonl \
        --host localhost --port 5432 --dbname mc_recipes \
        --user postgres --password secret

recipes.jsonl: one JSON object per line, {"id":..., "type":..., "json": {...}}
tags.jsonl:    one JSON object per line, {"tag":..., "items": [...]}

Both are produced by parsing the raw KubeJS console dumps - see
dump_recipes.js / dump_tags.js and the parsing steps in the project chat
history. This script truncates and fully reloads all three tables each run,
so it's safe to re-run whenever you re-export fresh data from the modpack.
"""

import argparse
import json
import sys

import psycopg2
import psycopg2.extras

SHAPED_TYPES = {"minecraft:crafting_shaped", "crafting_shaped"}
SHAPELESS_TYPES = {"minecraft:crafting_shapeless", "crafting_shapeless"}
CRAFTABLE_TYPES = SHAPED_TYPES | SHAPELESS_TYPES


def normalize_ingredient(value):
    """A key/ingredient value is either a single {"item"|"tag": id} object,
    or a list of such objects meaning "any of these are acceptable"."""
    options = value if isinstance(value, list) else [value]
    out = []
    for opt in options:
        if not isinstance(opt, dict):
            continue
        if "item" in opt:
            out.append(("item", opt["item"]))
        elif "tag" in opt:
            out.append(("tag", opt["tag"]))
    return out


def parse_shaped(j):
    pattern = j.get("pattern") or []
    key = j.get("key") or {}
    rows = []
    for r_idx, row in enumerate(pattern[:3]):
        for c_idx, ch in enumerate(row[:3]):
            if ch == " " or ch not in key:
                continue
            grid_pos = r_idx * 3 + c_idx + 1
            for kind, ref in normalize_ingredient(key[ch]):
                rows.append((grid_pos, kind, ref, 1))
    return rows


def parse_shapeless(j):
    ingredients = j.get("ingredients") or []
    rows = []
    for idx, ing in enumerate(ingredients[:9]):
        grid_pos = idx + 1
        for kind, ref in normalize_ingredient(ing):
            rows.append((grid_pos, kind, ref, 1))
    return rows


def parse_output(j):
    res = j.get("result")
    if isinstance(res, dict) and "id" in res:
        return res["id"], res.get("count", 1)
    if isinstance(res, str):
        return res, 1
    return None, None


def load_recipes(path):
    recipe_rows = []
    ingredient_rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            r = json.loads(line)
            rid, rtype, j = r["id"], r["type"], r["json"]
            craftable = rtype in CRAFTABLE_TYPES
            output_item, output_count = parse_output(j)

            recipe_rows.append((rid, rtype, craftable, output_item, output_count, json.dumps(j)))

            if rtype in SHAPED_TYPES:
                parsed = parse_shaped(j)
            elif rtype in SHAPELESS_TYPES:
                parsed = parse_shapeless(j)
            else:
                parsed = []
            for grid_pos, kind, ref, count in parsed:
                ingredient_rows.append((rid, grid_pos, kind, ref, count))
    return recipe_rows, ingredient_rows


def load_tags(path):
    tag_rows = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            t = json.loads(line)
            for item in t["items"]:
                tag_rows.append((t["tag"], item))
    return tag_rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("recipes_jsonl")
    ap.add_argument("tags_jsonl")
    ap.add_argument("--host", default="localhost")
    ap.add_argument("--port", default=5432, type=int)
    ap.add_argument("--dbname", required=True)
    ap.add_argument("--user", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--schema", default=None, help="path to schema.sql (default: alongside this script)")
    args = ap.parse_args()

    schema_path = args.schema
    if schema_path is None:
        import os
        schema_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "schema.sql")

    print("Parsing recipes...")
    recipe_rows, ingredient_rows = load_recipes(args.recipes_jsonl)
    print(f"  {len(recipe_rows)} recipes, {len(ingredient_rows)} normalized ingredient rows")

    print("Parsing tags...")
    tag_rows = load_tags(args.tags_jsonl)
    print(f"  {len(tag_rows)} tag/item membership rows")

    print(f"Connecting to postgres://{args.user}@{args.host}:{args.port}/{args.dbname} ...")
    conn = psycopg2.connect(host=args.host, port=args.port, dbname=args.dbname,
                             user=args.user, password=args.password)
    try:
        with conn.cursor() as cur:
            print("Applying schema...")
            with open(schema_path, "r", encoding="utf-8") as f:
                cur.execute(f.read())

            print("Clearing existing data...")
            cur.execute("TRUNCATE recipe_ingredients, tags, recipes CASCADE;")

            print("Loading recipes...")
            psycopg2.extras.execute_values(
                cur,
                "INSERT INTO recipes (id, type, craftable, output_item, output_count, raw) VALUES %s",
                recipe_rows,
                template="(%s, %s, %s, %s, %s, %s::jsonb)",
                page_size=2000,
            )

            print("Loading recipe ingredients...")
            psycopg2.extras.execute_values(
                cur,
                "INSERT INTO recipe_ingredients (recipe_id, grid_pos, kind, ref, count) VALUES %s",
                ingredient_rows,
                page_size=5000,
            )

            print("Loading tags...")
            psycopg2.extras.execute_values(
                cur,
                "INSERT INTO tags (tag, item) VALUES %s ON CONFLICT DO NOTHING",
                tag_rows,
                page_size=5000,
            )

        conn.commit()
        print("Done.")

        with conn.cursor() as cur:
            cur.execute("SELECT count(*) FROM recipes;")
            print(f"recipes: {cur.fetchone()[0]}")
            cur.execute("SELECT count(*) FROM recipes WHERE craftable;")
            print(f"  craftable: {cur.fetchone()[0]}")
            cur.execute("SELECT count(*) FROM recipe_ingredients;")
            print(f"recipe_ingredients: {cur.fetchone()[0]}")
            cur.execute("SELECT count(*) FROM tags;")
            print(f"tags (tag/item pairs): {cur.fetchone()[0]}")
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
