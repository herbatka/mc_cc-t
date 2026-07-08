# Recipe database

Populates a Postgres database with the modpack's full recipe catalog (every
recipe of every type, from every mod), which [PostgREST](https://postgrest.org)
then exposes as a read-only HTTP API for the CC:Tweaked Craft tab to query.
This is a big reference catalog separate from the turtle's local
`recipes.db` (recipes taught by physically crafting them), which still
exists as a fallback for anything not in the database.

`recipes.craftable` marks the subset the turtle can actually execute (shaped/
shapeless crafting-table recipes, ~43.6k of ~88.9k total in this modpack) -
the rest are kept for reference (smelting, machine recipes, etc.) even
though nothing here can auto-craft them yet.

Everything below runs on the same box as the Minecraft server. Total idle
footprint is Postgres (however you've already sized it) + PostgREST at
~17MB RSS - the Python scripts are one-off tools, not long-running services.

## Part 1 - Extract recipe + tag data from the modpack

This only needs to be redone after a modpack update changes recipes; the
resulting `recipes.jsonl`/`tags.jsonl` files aren't tied to any particular
server session.

1. **Dump every recipe.** Copy `kubejs/dump_recipes.js` (in this repo) into
   your modpack's `kubejs/server_scripts/` folder, then restart the server
   (or `/reload`) so it runs. It logs one `RECIPEDUMP <id> <json>` line per
   recipe plus a final `RECIPEDUMP_TOTAL <count>`.
2. **Pull those lines out of the log**, from the server's root directory:
   ```
   grep "RECIPEDUMP " logs/latest.log > recipes_raw.txt
   ```
   (If KubeJS routes its own console output elsewhere in your setup, check
   for something like `kubejs/logs/console.log` instead.)
3. **Parse it into clean JSON Lines:**
   ```
   python3 db/parse_recipe_log.py recipes_raw.txt recipes.jsonl
   ```
   This prints a summary (total parsed, failures, recipe type breakdown) so
   you can eyeball that it looks sane before moving on.
4. **Dump every item tag.** Copy `kubejs/dump_all_tags.js` (in this repo)
   into `kubejs/server_scripts/` the same way as step 1, restart/reload,
   then:
   ```
   grep "TAGDUMP " logs/latest.log > tags_raw.txt
   ```
   This walks every tag the item registry itself knows about (vanilla +
   every mod), not just tags used as a recipe ingredient - so classification
   tags like `c:crops` on a farming mod's produce are covered too, which
   matters for the Search tab's tag matching (see top-level README.md).
   Note: `ServerEvents.tags` fires several times during startup, and only a
   later firing (thread name `Worker-ResourceReload-*`) has fully-resolved
   data - seeing each tag logged more than once is expected, not a bug. If
   the log instead shows a single `ENUMERATE_TAGS_ERROR ...` line, the
   registry-enumeration call in that script needs adjusting for your
   Minecraft/KubeJS version - open an issue/ask with that exact error text.
5. **Parse the tag dump**, keeping the last (fully-resolved) entry per tag:
   ```
   python3 db/parse_tag_log.py tags_raw.txt tags.jsonl
   ```

You should now have `recipes.jsonl` and `tags.jsonl` sitting next to each
other, ready for Part 2.

## Part 2 - Install Postgres and load the data

Commands below assume a Debian/Ubuntu-family server; substitute your
distro's package manager if it's different.

1. **Install Postgres** (skip if you already have it running for something
   else - this can share that instance):
   ```
   sudo apt-get update
   sudo apt-get install -y postgresql
   sudo systemctl enable --now postgresql
   ```
2. **Create a database and a password for the import user:**
   ```
   sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'pick-a-password';"
   sudo -u postgres createdb mc_recipes
   ```
3. **Install the Python driver and run the import:**
   ```
   sudo apt install python3-psycopg2
   python3 db/import_recipes.py recipes.jsonl tags.jsonl \
     --host localhost --dbname mc_recipes --user postgres --password pick-a-password
   ```
   (Debian/Ubuntu's system Python refuses a plain `pip install` with an
   "externally-managed-environment" error - the apt package is the simplest
   fix since it's already built against the system's `libpq`. If it's not
   available on your distro, `pip install psycopg2-binary --break-system-packages`
   works too - safe here since this is just a one-off import script, not
   something that shares dependencies with other tools.)
   This applies `db/schema.sql` automatically (tables, indexes, the
   `recipe_ingredients_raw()` function, and the `web_anon`/
   `authenticator` roles PostgREST needs), then **fully truncates and
   reloads** all three tables - safe to re-run any time you redo Part 1
   with fresh data.
4. It prints row counts at the end - sanity check that `craftable` count is
   roughly half of `recipes` and `recipe_ingredients`/`tags` are both
   populated, not zero.

## Part 3 - Install and run PostgREST

PostgREST turns the schema straight into a REST API - no application code
to write or maintain. It's a single statically-linked binary.

1. **Download it** from
   https://github.com/PostgREST/postgrest/releases/latest - grab the
   `linux-static-x64` (or `arm64`, if that's your box) `.tar.xz` asset.
2. **Extract and place it** somewhere permanent, e.g.:
   ```
   sudo mkdir -p /opt/postgrest
   tar xJf postgrest-*.tar.xz -C /opt/postgrest
   ```
3. **Set a real password for the `authenticator` role** (a placeholder
   `'change-me'` password was created by `schema.sql` in Part 2 step 3):
   ```
   sudo -u postgres psql -d mc_recipes -c "ALTER ROLE authenticator PASSWORD 'pick-another-password';"
   ```
4. **Copy and edit the config:**
   ```
   sudo cp db/postgrest.conf /opt/postgrest/postgrest.conf
   ```
   Edit `db-uri` in that file to use the password from step 3 and your
   actual database name if it's not `mc_recipes`.
5. **Install the systemd service:**
   ```
   sudo cp db/postgrest.service /etc/systemd/system/
   ```
   Edit the two paths in `ExecStart` if you placed the binary/config
   somewhere other than `/opt/postgrest/`, then:
   ```
   sudo systemctl daemon-reload
   sudo systemctl enable --now postgrest
   ```
6. **Verify it's actually serving data:**
   ```
   curl "http://127.0.0.1:3001/recipes?craftable=eq.true&output_item=eq.minecraft:chest"
   ```
   You should get back JSON for several chest recipes (see the note on
   multiple-recipes-per-item below - that's expected).

`postgrest.conf` binds to `127.0.0.1` only (not exposed on the LAN), since
the API and Minecraft server run on the same box - the CC:Tweaked side
calling `http://127.0.0.1:3001/...` is the Java process making an outbound
loopback request, not a real network hop.

## Part 4 - Allow CC:Tweaked to reach it

CC:Tweaked's HTTP API blocks private/loopback addresses by default (an
anti-SSRF safeguard) via a built-in `$private` rule in
`computercraft-server.toml` (in your server's `config/` or `serverconfig/`
folder, depending on loader) that denies `127.0.0.1` and the rest of the
private ranges. Rules are a flat list of `[[http.rules]]` entries evaluated
top-to-bottom, stopping at the first match - so `127.0.0.1` needs its own
`[[http.rules]]` entry placed **before** the existing `$private` one, not
nested inside another rule (there's no such thing as a nested
`[[http.rules.allow]]` sub-table - that's not real CC:Tweaked syntax):

```toml
[http]
	[[http.rules]]
		host = "127.0.0.1"
		action = "allow"
	[[http.rules]]
		host = "$private"
		action = "deny"
	[[http.rules]]
		host = "*"
		action = "allow"
		...
```

Restart the server after editing it - there's no in-game reload for this
config, it's only read at startup.

At this point the whole pipeline is live: `curl http://127.0.0.1:3001/...`
works from the server's own shell, and a CC:Tweaked computer's `http.get()`
to that same URL should now succeed too.

## Schema

- `recipes` - one row per recipe: `id`, `type`, `craftable` (bool), `output_item`,
  `output_count`, and `raw` (the full original recipe JSON as `jsonb`, for
  anything not covered by the normalized columns).
- `recipe_ingredients` - only populated for `craftable` recipes: `recipe_id`,
  `grid_pos` (1-9, row-major - matches `GRID_SLOTS` in `startup.lua`), `kind`
  (`item` or `tag`), `ref`, `count`. Multiple rows for the same
  `(recipe_id, grid_pos)` mean any of them is an acceptable ingredient there.
- `tags` - `(tag, item)` membership pairs for every item tag the game knows
  about (vanilla + every mod), from `kubejs/dump_all_tags.js` - not limited
  to tags used as recipe ingredients, since the Search tab's tag matching
  needs classification tags too (e.g. `c:crops`), not just crafting ones.
- `recipe_ingredients_raw(recipe_id)` - a SQL function; given a recipe id,
  returns each grid position's needed count plus the raw item-or-tag
  ingredient rows, unresolved. The Lua side resolves tags itself with a
  single batched `/tags?tag=in.(...)` lookup covering every distinct tag
  used anywhere in the recipe, rather than asking Postgres to expand each
  tag inline. That split matters once a tag is reused across several grid
  positions (e.g. a chest recipe uses a planks tag in all 8 border slots):
  resolving it in SQL would repeat that tag's entire item list once per
  position it appears in, while resolving it in Lua fetches it exactly
  once regardless of how many positions reference it (measured ~200KB vs
  ~50KB fetched once, for the chest recipe).

Example API calls (what the Lua side actually uses):
```
GET  /recipes?craftable=eq.true&output_item=ilike.*chest*&select=id,output_item,output_count
POST /rpc/recipe_ingredients_raw   {"p_recipe_id": "minecraft:chest"}
GET  /tags?tag=in.(minecraft:planks,c:dyes/magenta)&select=tag,item
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
- Re-running Part 1 + `import_recipes.py` after a modpack update is the
  whole update story - no migrations to write, since it's a full
  truncate-and-reload each time.
