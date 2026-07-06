# mc_cc-t
programiki do computercraft do minecraft

## Storage + crafting interface

`startup.lua` (main computer) and `remote.lua` (pocket computer) both show
two tabs at the top of the screen: **Search** and **Craft**. Switch between
them with the **Left/Right** arrow keys.

- **Search** — unchanged: type to search your sophisticatedstorage chests,
  Up/Down to pick, Enter to withdraw an amount.
- **Craft** — type the name of a known recipe, Up/Down to pick a match,
  Enter to set a quantity. It then shows the exact ingredient list — what's
  needed and what you're short on — before you commit. If everything's in
  stock, Enter crafts it for real using a turtle, and the crafted item is
  delivered to OUTPUT (same chest withdrawals go to) so it's waiting for
  you to collect. Any leftover ingredients (e.g. if a craft fails partway)
  go back into general storage instead.

No AE2/ME system involved — this is entirely self-contained, using your
existing sophisticatedstorage chests plus one crafting turtle.

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

That's it — the Craft tab now works with the ~24 built-in recipes (sticks,
torches, crafting table, chest, furnace, ladder, bucket, shears, flint and
steel, plus the full wood/stone/iron pickaxe/axe/shovel/hoe/sword set).

The only thing the main computer checks directly is the staging barrel
(it needs that on its own network to push ingredients/absorb output) - if
that's missing, the Craft tab says so and the Search tab keeps working
exactly as before. Turtle reachability itself is checked live, per
request, over rednet: if `turtle_craft.lua` isn't running or isn't
reachable, attempting to craft or teach shows a clear "turtle helper not
found" error instead of hanging.

### Teaching new recipes

For anything not in the built-in list (modded items, other tool tiers,
whatever), teach it directly:

1. In the Craft tab, press **F2** ("teach new").
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
planks", not "any planks"). If you want to correct a built-in recipe to use
a specific wood/material you have on hand, just teach it again with your
own ingredients — taught recipes override built-ins with the same output.

Note: teaching has to happen at the main computer, since it needs the
turtle physically in front of you. The pocket remote can search and craft
anything already known, but can't teach.
