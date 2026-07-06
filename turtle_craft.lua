--[[  turtle_craft.lua  -------------------------------------------------------
  Runs ON the crafting turtle itself (save this as the turtle's "startup.lua").

  CC:Tweaked only lets another computer remotely power-cycle a turtle
  (on/off/reboot) - it can't remotely call turtle.craft() or read the
  turtle's inventory. Only a program running locally on the turtle can do
  that, using the turtle's own `turtle` API. So this tiny helper sits on the
  turtle, listens for requests from the main storage computer over rednet,
  and does the actual crafting/inventory-reading locally.

  Needs a modem (wired or wireless) attached to the turtle, on the same
  network as the main storage computer (wired is simplest - just connect it
  into the same Networking Cable run as your storage chests).
--------------------------------------------------------------------------- ]]

local PROTO, HOST = "cg_turtle", "craftbot"

local modem = peripheral.find("modem")
if not modem then
  error("No modem attached. Attach a Wired or Wireless Modem to this turtle.", 0)
end
rednet.open(peripheral.getName(modem))
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

    elseif msg.cmd == "snapshot" then
      local slots = {}
      for i = 1, 16 do slots[i] = turtle.getItemDetail(i) end
      rednet.send(sender, { ok = true, slots = slots }, PROTO)

    elseif msg.cmd == "ping" then
      rednet.send(sender, { ok = true }, PROTO)
    end
  end
end
