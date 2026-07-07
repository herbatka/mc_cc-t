# Recipe database

Populates a Postgres database with the modpack's full recipe catalog, sourced
from a KubeJS dump (see `dump_recipes.js` / `dump_tags.js` used to produce
`recipes.jsonl` / `tags.jsonl` - ask in chat history if you need those
regenerated). This is a big reference catalog the CC:Tweaked Craft tab will
query over HTTP; it's separate from the turtle's local `recipes.db` (recipes
taught by physically crafting them), which still exists as a fallback for
anything not in the database.

`recipes.craftable` marks the subset the turtle can actually execute (shaped/
shapeless crafting-table recipes, ~43.6k of the ~88.9k total) - the rest are
kept for reference (smelting, machine recipes, etc. from other mods) even
though nothing here can auto-craft them yet.

## Setup

```
pip install psycopg2-binary
createdb mc_recipes   # or whatever database name you want
python3 import_recipes.py recipes.jsonl tags.jsonl \
  --host localhost --dbname mc_recipes --user postgres --password <your password>
```

This applies `schema.sql` automatically, then **fully truncates and reloads**
all three tables - safe to re-run whenever you re-export fresh data from the
modpack (e.g. after an update changes recipes).

## Schema

- `recipes` - one row per recipe: `id`, `type`, `craftable` (bool), `output_item`,
  `output_count`, and `raw` (the full original recipe JSON as `jsonb`, for
  anything not covered by the normalized columns).
- `recipe_ingredients` - only populated for `craftable` recipes: `recipe_id`,
  `grid_pos` (1-9, row-major - matches `GRID_SLOTS` in `startup.lua`), `kind`
  (`item` or `tag`), `ref`, `count`. Multiple rows for the same
  `(recipe_id, grid_pos)` mean any of them is an acceptable ingredient there.
- `tags` - `(tag, item)` membership pairs, only for tags actually referenced
  by the recipe dump (not every tag in the game).

## Notes

- Display names aren't in the recipe data at all - only item/tag ids. Search
  will need to either fall back to prettifying the id (like `prettify()` in
  `startup.lua`) or the API layer does the same thing server-side.
- A single recipe can output items whose exact NBT/data-component variant
  differs from what's in `output_item` - `output_item`/`output_count` are
  just `result.id`/`result.count` from the recipe JSON, good enough for our
  turtle-craftable subset.
