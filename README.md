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
  stock, Enter crafts it for real using a turtle, and the result is banked
  straight back into storage.

No AE2/ME system involved — this is entirely self-contained, using your
existing sophisticatedstorage chests plus one crafting turtle.

### Setting up the Craft tab

1. Craft a turtle (any kind — a plain turtle is fine, you don't need mining
   or fuel-related upgrades for this).
2. Equip it with a **Crafting Table**: craft the turtle together with a
   Crafting Table item in a vanilla crafting grid to fuse them into a
   "Turtle (Crafting)".
3. Place that turtle so this computer can see it as a peripheral — directly
   touching the computer, or on the same Wired Modem network the computer's
   modem is on (same rule as the sophisticatedstorage chests). No script
   config needed; it's auto-detected via `peripheral.find("turtle")`.

That's it — the Craft tab now works with the ~24 built-in recipes (sticks,
torches, crafting table, chest, furnace, ladder, bucket, shears, flint and
steel, plus the full wood/stone/iron pickaxe/axe/shovel/hoe/sword set).

If no turtle is found, the Craft tab just says so and the Search tab keeps
working exactly as before.

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
