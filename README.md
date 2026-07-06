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

A turtle wrapped as a peripheral by another computer only exposes remote
power control (on/off/reboot) — it can't be told to craft or have its
inventory read that way. So the turtle needs **its own small helper
program** (`turtle_craft.lua`, included in this repo) plus a modem, and the
main computer talks to it over rednet.

1. Craft a turtle (any kind — a plain turtle is fine, no mining/fuel
   upgrades needed for this).
2. Equip it with a **Crafting Table**: craft the turtle together with a
   Crafting Table item in a vanilla crafting grid to fuse them into a
   "Turtle (Crafting)".
3. Attach a **Wired Modem** to the turtle and connect it into the *same*
   wired network your sophisticatedstorage chests are already on
   (Networking Cable, or place it directly touching another wired modem
   that's part of that network). A wireless modem is fine too (or in
   addition) for the rednet messaging part, but the *wired* connection is
   what actually matters here: it's what lets the main computer push
   ingredients into the turtle's inventory by name. Wireless modems only
   carry rednet messages - they don't join the shared peripheral network
   that `pushItems` needs.

   Important: a wired modem is **not** a turtle upgrade you craft/equip
   like the Crafting Table. Just right-click the Wired Modem item onto an
   outer face of the turtle, the same way you'd attach one to a chest - it
   doesn't use up an upgrade slot. Being merely adjacent to the computer
   isn't enough either - a bare side name like "bottom" isn't a
   network-addressable name other peripherals can target, which is the
   "Target 'bottom' does not exist" error you'd get without this step.
4. Copy `turtle_craft.lua` onto the turtle and save it as the turtle's own
   **`startup.lua`**, then reboot the turtle so it runs automatically. It
   just sits there listening for requests — you don't interact with it
   directly.
5. Reboot the main computer so it picks up the turtle fresh.

That's it — the Craft tab now works with the ~24 built-in recipes (sticks,
torches, crafting table, chest, furnace, ladder, bucket, shears, flint and
steel, plus the full wood/stone/iron pickaxe/axe/shovel/hoe/sword set).

If no turtle is found, the Craft tab just says so and the Search tab keeps
working exactly as before. If the turtle is found but its helper program
isn't running/reachable, attempting to craft or teach will show a clear
"turtle helper not found" error instead of hanging.

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
