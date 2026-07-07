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
