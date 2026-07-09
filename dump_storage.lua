--[[  dump_storage.lua  --------------------------------------------------------
  One-off diagnostic tool, NOT part of the normal running system - copy this
  onto any computer that's on the same wired network as your sophisticated-
  storage chests (the manager computer is the obvious place, since it's
  already there) and run it directly (type `dump_storage` at that computer's
  shell). It writes a full snapshot of exactly what's in every chest, in
  every slot, to storage_dump.txt on that computer's own disk.

  Meant for sharing: run `pastebin put storage_dump.txt` afterward to get a
  shareable link, same as manager.log - handy for figuring out the best way
  to lay storage out, or diagnosing why rebalancing is doing what it's
  doing, from the actual real data instead of guessing.
--------------------------------------------------------------------------- ]]

local OUT_FILE = "storage_dump.txt"

-- Numeric-aware sort so chest_2 sorts before chest_10 (matches manager.lua's
-- own chest ordering, which is what "priority order" below refers to).
local function naturalLess(a, b)
  local abase, anum = a:match("^(.-)(%d+)$")
  local bbase, bnum = b:match("^(.-)(%d+)$")
  if abase and bbase and abase == bbase then
    return tonumber(anum) < tonumber(bnum)
  end
  return a < b
end

local storages = {}
for _, name in ipairs(peripheral.getNames()) do
  if name:find("^sophisticatedstorage:") then storages[#storages + 1] = name end
end
table.sort(storages, naturalLess)

if #storages == 0 then error("No sophisticatedstorage chests found on this network.", 0) end

local function keyOf(item) return item.name .. "|" .. (item.nbt or "") end

local byKey = {}   -- key -> { name = display name, total = n, locations = {...} }
local perChest = {}   -- chest name -> { size = n, slots = { [slot] = {name=,count=} } }

for _, name in ipairs(storages) do
  local inv = peripheral.wrap(name)
  local size = inv.size()
  perChest[name] = { size = size, slots = {} }
  for slot, item in pairs(inv.list()) do
    local k = keyOf(item)
    if not byKey[k] then byKey[k] = { name = item.name, total = 0, count = 0 } end
    byKey[k].total = byKey[k].total + item.count
    byKey[k].count = byKey[k].count + 1
    perChest[name].slots[slot] = { name = item.name, count = item.count }
  end
end

local totals = {}
for key, info in pairs(byKey) do totals[#totals + 1] = { key = key, name = info.name, total = info.total, slots = info.count } end
table.sort(totals, function(a, b) return a.total > b.total end)

local f = io.open(OUT_FILE, "w")

local grandTotal, occupiedSlots, totalSlots = 0, 0, 0
for _, t in ipairs(totals) do grandTotal = grandTotal + t.total; occupiedSlots = occupiedSlots + t.slots end
for _, c in pairs(perChest) do totalSlots = totalSlots + c.size end

f:write(("=== Storage dump (%s) ===\n"):format(textutils.formatTime(os.time(), true)))
f:write(("Chests: %d   Distinct items: %d   Occupied slots: %d / %d   Total item count: %d\n\n")
  :format(#storages, #totals, occupiedSlots, totalSlots, grandTotal))

f:write("-- Totals (highest first) --\n")
for i, t in ipairs(totals) do
  f:write(("%4d. %8d  %-40s (%d slot%s)\n"):format(i, t.total, t.name, t.slots, t.slots == 1 and "" or "s"))
end
f:write("\n")

f:write("-- Per-slot detail (chest order = rebalance's priority order) --\n")
for _, name in ipairs(storages) do
  local c = perChest[name]
  f:write(("%s (%d slots)\n"):format(name, c.size))
  for slot = 1, c.size do
    local it = c.slots[slot]
    if it then
      f:write(("  %2d: %6d x %s\n"):format(slot, it.count, it.name))
    else
      f:write(("  %2d: (empty)\n"):format(slot))
    end
  end
end
f:close()

print(("Wrote %s (%d chest(s), %d distinct item(s), %d item(s) total)."):format(OUT_FILE, #storages, #totals, grandTotal))
print("Run `pastebin put " .. OUT_FILE .. "` to get a shareable link.")
