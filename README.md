# mc_cc-t
programiki do computercraft do minecraft

## Storage + crafting interface

`startup.lua` (main computer) and `remote.lua` (pocket computer) both show
two tabs at the top: **Search** and **Craft**. Cycle between them with the
**Left/Right** arrow keys, and use **C** instead of Escape to cancel out of
a screen — Minecraft's client eats Escape (closes the screen) and most
F-keys (F2 = screenshot, etc.) before a computer program ever sees them, so
this UI avoids both entirely.

- **Search** — unchanged: type to search your sophisticatedstorage chests,
  Up/Down to pick, Enter to withdraw an amount.
- **Craft** — type a name, Enter to search a recipe database over HTTP (see
  `db/`), Up/Down to pick a match, Enter to select, then type a quantity.
  It shows one summarized line per distinct ingredient — total needed vs.
  what you have — before you commit. If everything's in stock, **Enter**
  crafts it for real using a turtle and banks the crafted item into general
  storage (same as anything else you've crafted or deposited - use the
  Search tab to withdraw it same as always). Press **O** instead to send it
  straight to OUTPUT instead (same chest withdrawals go to), if you want it
  waiting for you to collect without a separate withdrawal. Any leftover
  ingredients (e.g. if a craft fails partway) always go back into general
  storage regardless of which key you used. Since a single item can have
  several different recipes (e.g. a vanilla chest vs. a modded variant),
  search results show each recipe separately, tagged with which mod it's
  from (`[minecraft]`, `[aether]`, etc.) so you can tell them apart.
- **Missing an ingredient?** If a short ingredient has its own craftable
  recipe *and* that recipe's own ingredients are fully in stock right now,
  it's marked with a `*` and pressing **S** instead of Enter/O crafts the
  missing ingredient(s) first (always banked into storage - they're
  intermediates, not what you asked for), then crafts the item you
  actually wanted into storage too. This only goes one level deep: if the
  missing ingredient's own recipe is *also* short something, it's shown as
  missing with no `*` and
  no auto-craft option, rather than chasing an arbitrarily deep tree of
  crafts you never approved.

No AE2/ME system involved — this is entirely self-contained, using your
existing sophisticatedstorage chests plus one crafting turtle plus a small
Postgres + PostgREST database on the same box (see `db/README.md` for the
full setup walkthrough - recipe search won't return anything without it).

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
   either works, since this is only used for "craft this" / "load this
   slot" requests, not item transfer. It can be equipped as an upgrade
   (wireless) or just needs to be in range/on the network (wired) -
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
not found" error, and if the database is unreachable, search just returns
nothing with a clear error instead of hanging or crashing.
