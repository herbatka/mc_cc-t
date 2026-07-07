# mc_cc-t
programiki do computercraft do minecraft

## Storage + crafting interface

`startup.lua` (main computer) shows three tabs at the top: **Search**,
**Craft**, and **Teach**. `remote.lua` (pocket computer) shows Search and
Craft (teaching needs you physically at the turtle, so it's main-computer
only). Cycle between tabs with the **Left/Right** arrow keys, and use **C**
instead of Escape to cancel out of a screen — Minecraft's client eats
Escape (closes the screen) and most F-keys (F2 = screenshot, etc.) before a
computer program ever sees them, so this UI avoids both entirely.

- **Search** — unchanged: type to search your sophisticatedstorage chests,
  Up/Down to pick, Enter to withdraw an amount.
- **Craft** — type a name, Enter to search (a full recipe database over
  HTTP - see `db/`, plus anything you've taught locally), Up/Down to pick a
  match, Enter to select, then type a quantity. It shows the exact
  ingredient list — what's needed and what you're short on — before you
  commit. If everything's in stock, Enter crafts it for real using a
  turtle, and the crafted item is delivered to OUTPUT (same chest
  withdrawals go to) so it's waiting for you to collect. Any leftover
  ingredients (e.g. if a craft fails partway) go back into general storage
  instead. Since a single item can have several different recipes (e.g. a
  vanilla chest vs. a modded variant), search results show each recipe
  separately, tagged with which mod it's from (`[minecraft]`, `[aether]`,
  etc.) so you can tell them apart.
- **Teach** — arrange ingredients in the turtle's crafting grid yourself,
  then Enter to learn the recipe for real (see below). Useful for anything
  not in the database (custom NBT variants, a mod added after the last
  database export).

No AE2/ME system involved — this is entirely self-contained, using your
existing sophisticatedstorage chests plus one crafting turtle plus a small
Postgres + PostgREST database on the same box (see `db/README.md` for the
full setup walkthrough - recipe search won't return anything without it,
though locally-taught recipes still work fine either way).

### Setting up the Craft tab

The crafting turtle is effectively **its own separate computer** — it
doesn't need to be anywhere near the main computer, isn't detected as a
peripheral by it, and can't join a wired network at all (that's just not
a thing turtles can do). So the turtle runs **its own small helper
program** (`turtle_craft.lua`, included in this repo), and everything
between it and the main computer happens over rednet plus a shared barrel:

1. Craft a turtle (any kind — a plain turtle is fine, no mining/fuel
   upgrades needed for this).
2. Equip it with a **Crafting Table**: craft the turtle together with a
   Crafting Table item in a vanilla crafting grid to fuse them into a
   "Turtle (Crafting)".
3. Attach a modem to the turtle for rednet messaging — wired or wireless,
   either works, since this is only used for "craft this" / "give me your
   inventory" requests, not item transfer. It can be equipped as an
   upgrade (wireless) or just needs to be in range/on the network (wired) -
   whichever's easier.
4. Place a **barrel directly below the turtle** (this is the only
   positioning requirement - it's relative to the turtle, not the main
   computer), and connect that barrel to your existing sophisticatedstorage
   network with its own Wired Modem, same as your other storage chests.
   Set `TURTLE_STAGING` in `startup.lua` to that barrel's peripheral name
   (default: `"minecraft:barrel_3"` — check yours with the
   `peripheral.getNames()` trick if it's named differently). The main
   computer pushes ingredients into this barrel normally; the turtle sucks
   them up into the right grid slot, then drops everything back down into
   it after crafting so the main computer can absorb it into storage.
5. Copy `turtle_craft.lua` onto the turtle and save it as the turtle's own
   **`startup.lua`**, then reboot the turtle so it runs automatically. It
   just sits there listening for requests — you don't interact with it
   directly.
6. Reboot the main computer so it picks up the barrel fresh.

That, plus the recipe database from `db/README.md` reachable at `API_BASE`
in `startup.lua` (default `http://127.0.0.1:3001`), is the whole Craft tab.

The only thing the main computer checks directly at boot is the staging
barrel (it needs that on its own network to push ingredients/absorb
output) - if that's missing, the Craft tab says so and the Search tab
keeps working exactly as before. Turtle reachability and database
reachability are both checked live, per request, instead: if
`turtle_craft.lua` isn't running/reachable you get a clear "turtle helper
not found" error, and if the database is unreachable, search just falls
back to whatever you've taught locally instead of hanging or crashing.

### Teaching new recipes

For anything not in the database (modded items added after the last
export, custom NBT variants, etc.), teach it directly:

1. Switch to the **Teach** tab (Left/Right).
2. Physically place the ingredients into the turtle's crafting grid — the
   top-left 3x3 of its inventory (slots 1-3, 5-7, 9-11).
3. Press Enter. The turtle actually crafts it for real, using the genuine
   Minecraft recipe system (not guesswork) — it fails cleanly with an error
   if the arrangement doesn't match any known recipe, without consuming
   anything.
4. On success, the script reads back exactly what was consumed from each
   grid slot and what came out, saves that as a recipe (persisted to
   `recipes.db` so it survives reboots), and banks the crafted item (plus
   any leftover ingredients) straight into storage.

Taught recipes only remember the exact item names you used (e.g. "spruce
planks", not "any planks" or a tag). They show up in Craft tab search
results alongside whatever the database finds, not instead of it - both
sources are searched every time, so you'll see your own taught version and
any database recipes for the same item side by side.

Note: teaching has to happen at the main computer, since it needs the
turtle physically in front of you. The pocket remote can search and craft
anything already known (locally taught or in the database), but can't teach.
