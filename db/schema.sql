-- Recipe/tag catalog for the crafting interface, populated from a KubeJS
-- recipe + tag dump (see db/import_recipes.py). This is entirely separate
-- from the turtle's local recipes.db (taught recipes) - it's a big reference
-- catalog the CC:Tweaked side queries over HTTP; recipe.craftable marks the
-- subset the turtle can actually execute (shaped/shapeless crafting-table
-- recipes), everything else is kept for reference only.

CREATE TABLE IF NOT EXISTS recipes (
  id            TEXT PRIMARY KEY,        -- e.g. "minecraft:chest"
  type          TEXT NOT NULL,           -- e.g. "minecraft:crafting_shaped"
  craftable     BOOLEAN NOT NULL DEFAULT FALSE,  -- true for shaped/shapeless
  output_item   TEXT,                    -- concrete output item id
  output_count  INTEGER,
  raw           JSONB NOT NULL           -- full original recipe json
);

CREATE INDEX IF NOT EXISTS recipes_type_idx ON recipes (type);
CREATE INDEX IF NOT EXISTS recipes_output_item_idx ON recipes (output_item);
CREATE INDEX IF NOT EXISTS recipes_craftable_idx ON recipes (craftable) WHERE craftable;

-- Normalized ingredients for the craftable subset only, in the turtle's
-- 3x3 grid position numbering (1-9, row-major - matches GRID_SLOTS in
-- startup.lua). Multiple rows for the same (recipe_id, grid_pos) mean
-- alternatives are acceptable there (e.g. a tag, or a list of options).
CREATE TABLE IF NOT EXISTS recipe_ingredients (
  id          BIGSERIAL PRIMARY KEY,
  recipe_id   TEXT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  grid_pos    SMALLINT NOT NULL CHECK (grid_pos BETWEEN 1 AND 9),
  kind        TEXT NOT NULL CHECK (kind IN ('item', 'tag')),
  ref         TEXT NOT NULL,             -- item id or tag id
  count       INTEGER NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS recipe_ingredients_recipe_idx ON recipe_ingredients (recipe_id);

-- Tag -> concrete item membership (from dump_tags.js). Only covers tags
-- actually referenced by the recipe dump, not every tag in the game.
CREATE TABLE IF NOT EXISTS tags (
  tag   TEXT NOT NULL,
  item  TEXT NOT NULL,
  PRIMARY KEY (tag, item)
);

CREATE INDEX IF NOT EXISTS tags_tag_idx ON tags (tag);

-- What the CC:Tweaked side actually searches against. Plain SELECT ...
-- LIMIT with no ORDER BY is not deterministic in Postgres - with hundreds
-- of matches for a common word like "chest", repeating the exact same
-- search could return a different arbitrary subset each time, sometimes
-- missing the obvious/canonical recipe entirely. output_len lets shorter,
-- more-canonical item ids (e.g. "minecraft:chest") sort before verbose
-- modded variants, and gives PostgREST's ?order= param a real column to
-- sort by (it only orders by columns, not arbitrary expressions).
CREATE OR REPLACE VIEW recipes_search AS
  SELECT id, type, craftable, output_item, output_count, length(output_item) AS output_len
  FROM recipes
  WHERE craftable;

-- Given a recipe id, returns each grid position's needed count plus the raw
-- item-or-tag ingredient rows, unresolved. The Lua side expands tags itself
-- via a single batched /tags?tag=in.(...) lookup covering every distinct tag
-- in the recipe - resolving tags here instead would mean re-sending a
-- shared tag's whole membership list once per grid position that uses it
-- (e.g. 8x over for a chest recipe, ~200KB instead of ~50KB fetched once).
CREATE OR REPLACE FUNCTION recipe_ingredients_raw(p_recipe_id text)
RETURNS TABLE(grid_pos smallint, needed_count integer, kind text, ref text) AS $$
  SELECT ri.grid_pos, ri.count AS needed_count, ri.kind, ri.ref
  FROM recipe_ingredients ri
  WHERE ri.recipe_id = p_recipe_id
  ORDER BY ri.grid_pos;
$$ LANGUAGE sql STABLE;

-- PostgREST connects as `authenticator` and switches to `web_anon` for
-- unauthenticated requests (there's no auth here - the API only ever
-- exposes read-only recipe data, nothing sensitive or writable).
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'web_anon') THEN
    CREATE ROLE web_anon NOLOGIN;
  END IF;
END $$;

DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    -- CHANGE THIS PASSWORD before deploying anywhere reachable off-box.
    CREATE ROLE authenticator NOINHERIT LOGIN PASSWORD 'change-me';
  END IF;
END $$;

GRANT web_anon TO authenticator;
GRANT USAGE ON SCHEMA public TO web_anon;
GRANT SELECT ON recipes, recipe_ingredients, tags, recipes_search TO web_anon;
GRANT EXECUTE ON FUNCTION recipe_ingredients_raw(text) TO web_anon;
