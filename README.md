# mc_cc-t
programiki do computercraft do minecraft

## Storage + crafting interface

`startup.lua` (main computer) and `remote.lua` (pocket computer) both show
two tabs at the top: **Search** and **Craft**. Cycle between them with the
**Left/Right** arrow keys, and use **C** instead of Escape to cancel out of
a screen — Minecraft's client eats Escape (closes the screen) and most
F-keys (F2 = screenshot, etc.) before a computer program ever sees them, so
this UI avoids both entirely.

- **Search** — type to search your sophisticatedstorage chests, Up/Down to
  pick, Enter to withdraw an amount. Matches both the item's name (as
  before) and its tags - e.g. typing "food" finds items literally named
  "food" as well as anything tagged `c:foods`/`c:crops`/etc. Tag data comes
  straight from the game itself (`getItemDetail`'s detailed item info),
  not the recipe database, so it's always exactly right and needs no
  network call - this only covers items you actually have in storage,
  which is exactly what Search needs. Same behavior on the pocket remote's
  Search tab, since it's the same filtering logic on the main computer
  either way.
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
  Typing a quantity bigger than one `turtle.craft()` call can physically
  handle (its own hard limit is 64, and a recipe with a heavy per-craft
  ingredient can cap out well under that - it's whatever fits in a single
  turtle slot) just runs multiple batches back to back automatically until
  the full amount's done, or until it runs out of an ingredient partway -
  in which case the status screen says exactly how many it actually got
  before that happened, rather than claiming success for the full amount.
- **Missing an ingredient?** If a short ingredient has its own craftable
  recipe *and* that recipe's own ingredients are fully in stock right now,
  it's marked with a `*` and pressing **S** crafts the missing
  ingredient(s) first (always banked into storage - they're intermediates,
  not what you asked for), then crafts the item you actually wanted into
  storage too. Press **O** instead for the same missing-ingredients-first
  flow but delivering the final item to OUTPUT, same choice as a normal
  craft. This only goes one level deep: if the missing ingredient's own
  recipe is *also* short something, it's shown as missing with no `*` and
  no auto-craft option, rather than chasing an arbitrarily deep tree of
  crafts you never approved.

No AE2/ME system involved — this is entirely self-contained, using your
existing sophisticatedstorage chests plus one crafting turtle plus a small
Postgres + PostgREST database on the same box (see `db/README.md` for the
full setup walkthrough - recipe search won't return anything without it).

Importing from INPUT and keeping storage tidy is a separate computer's job
entirely (`manager.lua`, see below) — the main computer never touches INPUT
itself, and just refreshes its view of storage when told something changed.

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

### Setting up the storage manager

`manager.lua` runs on its **own separate computer** whose only job is
keeping storage stocked and tidy, so the main computer only has to deal
with search/withdraw/craft. It needs its own **Wired Modem** on the same
network as your storage chests and the INPUT barrel (the same network the
main computer is already on) - unlike the crafting turtle, this is a normal
computer, not anything special.

1. Place a second computer anywhere on the same wired network as your
   sophisticatedstorage chests and INPUT barrel, and attach a Wired Modem
   to it.
2. Copy `manager.lua` onto it and save it as that computer's own
   **`startup.lua`**, then reboot so it runs automatically.
3. Reboot the main computer too, so it picks up rednet hosting for the new
   `cg_manager` protocol this computer listens on.

From then on, `manager.lua`:
- **Imports INPUT** every couple seconds, same as the main computer used to
  - distributing dropped items into whichever chests have room, merging
  into existing compatible stacks first.
- **Rebalances storage periodically** (every 5 minutes by default,
  `REBALANCE_INTERVAL` in `manager.lua`): ranks every item by how much of it
  you have in total, then lays them out across the chests in a fixed order
  (whichever chest sorts first alphabetically by peripheral name = "chest
  1") - the highest-total item fills as many slots as it needs starting
  from the very first one, the next-highest continues right after it
  (spilling into the next chest if it doesn't fit), and so on. So with
  enough items and enough runs you get "chest 1 is all Ancient Stone, then
  Diamond, then Raw Copper, ..." rather than just tidier chaos.
  - This doesn't try to achieve the exact target order in one pass -
    displacing a lower-priority item can itself require displacing whatever
    was already sitting where it needs to go, so it moves what it safely
    can each run (into an empty slot, or one already holding the same item)
    and leaves the rest for the next run, converging gradually. A big
    inventory change can take a few cycles to fully settle.
  - Rankings have a deadzone (`RANK_SWAP_THRESHOLD`, 64 by default): an item
    only overtakes its neighbor once it beats it by more than that many
    items, so two items with close totals don't swap chest position back
    and forth every run as their counts naturally seesaw during play.
  - **Stack sizes are discovered per chest, not assumed.** CC:Tweaked has no
    "what's this slot's real capacity" query, and sophisticatedstorage's
    stack upgrades raise that capacity per chest well past vanilla's 64 -
    so instead of hardcoding 64 anywhere, each chest's capacity is tracked
    starting at a default of 64 and only ever growing as more is learned
    about it (see the active measurement below, and passively any bigger
    stack rebalancing itself happens to create along the way also counts).
- **Actively measures real chest capacity** at startup and then every hour
  (`PROBE_INTERVAL` in `manager.lua`): rather than waiting for a big enough
  stack to occur naturally, it takes whichever item you currently have the
  most of and, one chest at a time, piles as much of it as exists anywhere
  into a single slot there, then reads back what actually landed - directly
  revealing that chest's true capacity even if it's never held that item
  before. Nothing is lost in the process (it's the same pushItems moves
  rebalancing already does), and rebalance() runs right after to put
  everything back where it actually belongs by rank, since probing
  deliberately piles things up in a way that ignores rank order.
- **Tells the main computer** whenever it actually moved something, so the
  main computer's cached view of storage refreshes right away instead of
  waiting for its own periodic resync. The Search tab shows how long ago it
  last heard from the manager (`manager: Ns ago` / `manager: not seen`), so
  it's obvious if the manager computer is off or unreachable.
- **Re-checks which chests actually exist before every import/rebalance/
  probe cycle.** Breaking, moving, or disconnecting a chest while the
  manager's mid-run used to leave it stuck referencing a chest that no
  longer exists, erroring on every single cycle from then on (visible as
  a repeating `Target '...' does not exist` error) - it now just drops
  that chest from the list on the next cycle and carries on with the rest,
  and picks up any newly-added chest the same way.

If the manager computer is off, INPUT just queues up untouched until it's
back - the main computer has no fallback import path of its own anymore, by
design (this is the whole point of moving that work off of it). Search,
withdraw, and crafting all keep working normally in the meantime; they just
won't see anything still sitting in INPUT. Withdrawals also verify a slot's
actual contents right before taking from it (not just trusting the last
cached scan), since the manager can now rearrange chests independently at
any time - so a stale search result can't accidentally hand you the wrong
item if something got moved out from under it.
