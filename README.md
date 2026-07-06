# mc_cc-t
programiki do computercraft do minecraft

## Storage + crafting interface

`startup.lua` (main computer) and `remote.lua` (pocket computer) both show
two tabs at the top of the screen: **Search** and **Craft**. Switch between
them with the **Left/Right** arrow keys.

- **Search** — unchanged: type to search your sophisticatedstorage chests,
  Up/Down to pick, Enter to withdraw an amount.
- **Craft** — type the name of an item, Up/Down to pick a match, Enter to
  set an amount, Enter again to queue the craft. The system reports whether
  the job was accepted and then polls until it finishes.

### Setting up the Craft tab

The Craft tab is powered by an **AE2 ME Bridge** (from the Advanced
Peripherals mod), not by the sophisticatedstorage chests — those are two
separate inventories. To enable it:

1. Build an AE2 (Applied Energistics 2) ME system as normal, with at least
   one **Crafting CPU** (crafting storage + optionally co-processors).
2. Place an **ME Bridge** block and connect it into that ME network (e.g.
   via ME cable/interface), then place it directly adjacent to the main
   computer, or reachable over a wired modem network the computer is part
   of. No extra config in the script is needed — it's auto-detected via
   `peripheral.find("meBridge")`.
3. For each item you want craftable, encode a crafting pattern for it in
   your ME system (Pattern Encoding Terminal -> Pattern Provider), same as
   you would for any AE2 autocrafting setup.
4. That's it — `listCraftableItems()` picks up anything with a pattern, so
   the Craft tab's search list is always just "whatever your ME network
   currently knows how to make."

If no ME Bridge is found, the Craft tab just says so and the Search tab
keeps working exactly as before.

Note: this script doesn't show you a raw ingredient list ("2 planks + 1
stick") — AE2 already resolves the full ingredient tree itself when you
queue a craft, including sub-crafting missing components. The Craft tab
just tells you whether the item is craftable, how many you currently have,
lets you queue a job, and reports success/failure and completion.
