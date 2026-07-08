--[[  turtle_craft.lua  -------------------------------------------------------
  Runs ON the crafting turtle itself (save this as the turtle's "startup.lua").

  A turtle can't join a wired peripheral network at all, and a turtle
  wrapped as a peripheral by another computer only exposes remote power
  control (on/off/reboot) - not craft() or inventory access. Only a program
  running locally on the turtle can call turtle.craft() or move items in/out
  of its own inventory (turtle.suck()/turtle.drop() and friends). So this
  tiny helper sits on the turtle, listens for requests from the main storage
  computer over rednet, and does that work locally.

  Items move in/out of the turtle through a barrel placed directly BELOW it
  (TURTLE_STAGING in startup.lua on the main computer) - the main computer
  pushes ingredients into that barrel normally, this program sucks them up
  into the right grid slot, and after crafting it drops everything back down
  into the barrel for the main computer to absorb into storage.

  Needs a modem (wired or wireless, either works) for rednet messaging to
  the main computer - that's just for "craft this" / "load this slot"
  requests, unrelated to the barrel-based item transfer above.
--------------------------------------------------------------------------- ]]

local PROTO, HOST = "cg_turtle", "craftbot"

local opened = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then
    rednet.open(name)
    opened = true
  end
end
if not opened then
  error("No modem attached. Attach a Wired or Wireless Modem to this turtle.", 0)
end
rednet.host(PROTO, HOST)

term.clear(); term.setCursorPos(1, 1)
print("Craft-turtle helper running.")
print("Listening for requests from the storage computer...")

while true do
  local sender, msg = rednet.receive(PROTO)
  if type(msg) == "table" then
    if msg.cmd == "craft" then
      local ok, err = turtle.craft(msg.cycles or 64)
      rednet.send(sender, { ok = ok, err = err }, PROTO)

    elseif msg.cmd == "loadSlot" then
      -- Suck `count` of whatever's currently in the staging barrel below
      -- into grid slot `slot`. The main computer only stages one distinct
      -- item at a time, so there's no ambiguity about what gets picked up.
      --
      -- suckDown()'s return value only means "moved at least one item", NOT
      -- "moved exactly `count`" - if the slot's own max stack (a plain
      -- vanilla ~64, regardless of any storage-side stack upgrades) is
      -- smaller than what a multi-cycle craft needs, it silently stops
      -- there and still reports success. Checking the actual count moved
      -- catches that (and an under-stocked barrel) instead of the caller
      -- wrongly believing every ingredient loaded in full.
      turtle.select(msg.slot)
      local before = turtle.getItemCount(msg.slot)
      turtle.suckDown(msg.count)
      local gotten = turtle.getItemCount(msg.slot) - before
      local ok = gotten >= msg.count
      local err = nil
      if not ok then
        err = ("only got %d of %d requested (slot maxed out or barrel short)"):format(gotten, msg.count)
      end
      rednet.send(sender, { ok = ok, err = err }, PROTO)

    elseif msg.cmd == "dump" then
      -- Drop everything (crafted output + any leftovers) into the barrel
      -- below so the main computer can absorb it back into storage.
      for i = 1, 16 do
        turtle.select(i)
        turtle.dropDown()
      end
      rednet.send(sender, { ok = true }, PROTO)
    end
  end
end
