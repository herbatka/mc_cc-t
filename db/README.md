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
- `recipe_ingredients_resolved(recipe_id)` - a SQL function; given a recipe
  id, returns each grid position with the count needed and the full list of
  concrete item ids that would satisfy it (a tag's entire membership, if
  that slot is tag-based). This is what the CC:Tweaked side actually calls -
  it never needs to know whether a slot was an item or a tag.

## API (PostgREST)

The CC:Tweaked computer only speaks HTTP, not SQL, so [PostgREST](https://postgrest.org)
sits in front of Postgres and turns the schema above into a REST API with
**no custom application code** - verified running at ~17MB RSS idle, which
matters given the Minecraft server is competing for the same box's RAM.

1. Download the Linux static x64/arm64 build from
   https://github.com/PostgREST/postgrest/releases/latest (it's a single
   self-contained binary, no runtime dependencies - `tar xJf postgrest-*.tar.xz`).
2. Apply the roles/grants at the bottom of `schema.sql` (already included if
   you ran `import_recipes.py`, which re-applies `schema.sql` every time) -
   **change the `authenticator` role's password** from the placeholder.
3. Copy `postgrest.conf`, fill in the real `db-uri` (matching that password
   and your database name), and place it next to the binary.
4. Copy `postgrest.service` to `/etc/systemd/system/`, fix the two paths in
   `ExecStart`, then `systemctl enable --now postgrest`.

`postgrest.conf` binds to `127.0.0.1` only (not exposed on the LAN) since
the API and the Minecraft server run on the same box - the CC:Tweaked side
calls `http://127.0.0.1:3001/...`, which is the Java process itself making an
outbound loopback request, not a real network hop. You'll still need to add
`127.0.0.1` to CC:Tweaked's `http.rules` allowlist in
`computercraft-server.toml`, since it blocks private/loopback addresses by
default as an anti-SSRF measure.

Example calls (what the Lua side will use):
```
GET  /recipes?craftable=eq.true&output_item=ilike.*chest*&select=id,output_item,output_count
POST /rpc/recipe_ingredients_resolved   {"p_recipe_id": "minecraft:chest"}
```

## Notes

- Display names aren't in the recipe data at all - only item/tag ids. Search
  will need to either fall back to prettifying the id (like `prettify()` in
  `startup.lua`) or the API layer does the same thing server-side.
- A single recipe can output items whose exact NBT/data-component variant
  differs from what's in `output_item` - `output_item`/`output_count` are
  just `result.id`/`result.count` from the recipe JSON, good enough for our
  turtle-craftable subset.
- **Multiple recipes can produce the same output item.** E.g. `minecraft:chest`
  has 5 different craftable recipes in this modpack (vanilla, Aether's
  skyroot variant, a Modern Industrialization batch recipe, etc.). The Craft
  tab needs to treat search results as a list of *recipes*, not items - more
  than one row can share the same output/display name, and the player picks
  the specific recipe variant they want, same as picking between storage
  entries today.
