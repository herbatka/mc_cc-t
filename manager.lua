--[[  manager.lua  ------------------------------------------------------------
  Storage-manager computer for the CC:Tweaked storage system (see README.md).

  Runs on its OWN computer, wired into the SAME sophisticatedstorage network
  as startup.lua's chests and the INPUT barrel. Takes two jobs off the main
  computer entirely:

    1. Importing whatever's dropped in the INPUT barrel.
    2. Periodically rebalancing storage - not just consolidating each item's
       own scattered stacks together, but laying every item out across the
       chests (in a fixed order, earliest chest first) ranked by how much of
       it you have overall, most first. So with enough runs, the highest-
       total item ends up filling the first chest(s), the next-highest
       continues right after it, and so on - "chest 1 is all Ancient Stone,
       then Diamond, then Raw Copper, ..." rather than just tidier chaos.

  The main computer (startup.lua) never touches INPUT or does this
  consolidation itself anymore - it just gets told over rednet whenever this
  computer moves something, so its cached view of storage stays fresh.

  Save as this computer's "startup.lua" so it runs automatically.
--------------------------------------------------------------------------- ]]

-------------------------- CONFIG -------------------------------------------
local INPUT = "minecraft:barrel_2"
local IMPORT_INTERVAL   = 2     -- seconds: how often INPUT is checked
local REBALANCE_INTERVAL  = 900   -- seconds: how often to rebalance (15 min)
local HEARTBEAT_INTERVAL = 15   -- seconds: "I'm alive" ping even if nothing moved
-- An item only overtakes its neighbor in chest-priority order if it beats it
-- by more than this many items - without this, two items with close totals
-- would swap chest position back and forth on every run as their counts
-- naturally seesaw during normal play.
local RANK_SWAP_THRESHOLD = 64
local MANAGER_PROTO, MAIN_HOST = "cg_manager", "mainstore"
----------------------------------------------------------------------------

if not peripheral.isPresent(INPUT) then error("INPUT '"..INPUT.."' not found", 0) end

-- Sorted for a stable, deterministic chest order across reboots - "chest 1"
-- below means whichever chest sorts first alphabetically by peripheral
-- name, not necessarily whichever one you think of as first physically.
local storages = {}
for _, name in ipairs(peripheral.getNames()) do
  if name:find("^sophisticatedstorage:") then storages[#storages + 1] = name end
end
if #storages == 0 then error("No sophisticatedstorage chests found.", 0) end
table.sort(storages)

local opened = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then rednet.open(name); opened = true end
end
if not opened then error("No modem attached. Attach a Wired or Wireless Modem.", 0) end

local mainId = nil   -- resolved lazily; startup.lua might not be booted yet

local function keyOf(item) return item.name .. "|" .. (item.nbt or "") end

local function notifyMain(msg)
  if not mainId then mainId = rednet.lookup(MANAGER_PROTO, MAIN_HOST) end
  if mainId then rednet.send(mainId, msg, MANAGER_PROTO) end
end

-- Distributes whatever's in INPUT across the storages with room, merging
-- into existing compatible stacks first (pushItems' own behavior) before
-- using empty slots. Doesn't bother finding "the" existing stack for an
-- item across every chest - that's what rebalance() below is for; this just
-- needs to get things out of the barrel quickly.
local function importFromInput()
  local inv = peripheral.wrap(INPUT)
  local contents = inv.list()
  if next(contents) == nil then return 0 end
  local moved = 0
  for slot, item in pairs(contents) do
    local remaining = item.count
    for _, name in ipairs(storages) do
      if remaining <= 0 then break end
      local m = inv.pushItems(name, slot, remaining)
      remaining = remaining - m
      moved = moved + m
    end
  end
  return moved
end

-- One full scan of every chest, grouping every stack by item key with each
-- key's total count across all locations. Same idea as startup.lua's
-- buildIndex(), but this computer doesn't need a persistent searchable
-- index - just a fresh snapshot each time rebalance() runs.
local function scanByKey()
  local byKey = {}
  for _, name in ipairs(storages) do
    local inv = peripheral.wrap(name)
    for slot, item in pairs(inv.list()) do
      local k = keyOf(item)
      if not byKey[k] then byKey[k] = { total = 0, locations = {} } end
      byKey[k].total = byKey[k].total + item.count
      local locs = byKey[k].locations
      locs[#locs + 1] = { inv = name, slot = slot, count = item.count }
    end
  end
  return byKey
end

-- Every (inv, slot) pair across all storages, in the fixed chest order
-- above, slots 1..size within each - this is the priority order items get
-- ranked into ("chest 1" = the start of this list).
local function allSlotsOrdered()
  local slots = {}
  for _, name in ipairs(storages) do
    local inv = peripheral.wrap(name)
    for slot = 1, inv.size() do
      slots[#slots + 1] = { inv = name, slot = slot }
    end
  end
  return slots
end

-- Persists (in memory - resets on reboot, which is fine) between runs so
-- re-ranking has hysteresis instead of thrashing on small fluctuations.
local rankOrder = {}   -- ordered list of item keys, highest total-count first

-- Drops keys no longer in storage, appends any brand-new key at the bottom
-- (lowest priority to start), then does ONE bubble pass promoting an item
-- only if it beats its neighbor by more than RANK_SWAP_THRESHOLD - so a big
-- new haul climbs toward its real rank gradually over several runs instead
-- of one huge reshuffle, and two close totals don't swap every run.
local function updateRankOrder(byKey)
  local seen, newOrder = {}, {}
  for _, key in ipairs(rankOrder) do
    if byKey[key] then newOrder[#newOrder + 1] = key; seen[key] = true end
  end
  for key in pairs(byKey) do
    if not seen[key] then newOrder[#newOrder + 1] = key end
  end
  for i = 1, #newOrder - 1 do
    local a, b = newOrder[i], newOrder[i + 1]
    if byKey[b].total > byKey[a].total + RANK_SWAP_THRESHOLD then
      newOrder[i], newOrder[i + 1] = newOrder[i + 1], newOrder[i]
    end
  end
  rankOrder = newOrder
end

-- Walks rankOrder in priority order, handing each key the next
-- ceil(total/64) slots off the front of the flattened chest/slot list.
local function assignTargets(byKey, slots)
  local targets, ptr = {}, 1
  for _, key in ipairs(rankOrder) do
    local needed = math.max(1, math.ceil(byKey[key].total / 64))
    local range = {}
    for _ = 1, needed do
      if slots[ptr] then range[#range + 1] = slots[ptr]; ptr = ptr + 1 end
    end
    targets[key] = range
  end
  return targets
end

local function slotId(loc) return loc.inv .. "#" .. loc.slot end

-- Moves misplaced stacks toward their assigned target range, highest
-- priority first, into whichever target slot is already empty or already
-- holds the same item - never evicts a different item that hasn't been
-- relocated yet. A stack that can't be freed this run (every target slot
-- still occupied by something else) is simply left for a later run, once
-- whatever's in the way has moved on to its own target.
local function rebalance()
  local byKey = scanByKey()
  local slots = allSlotsOrdered()
  updateRankOrder(byKey)
  local targets = assignTargets(byKey, slots)

  -- slotId -> item key currently sitting there, and how many - the count
  -- matters here (not just in scanByKey's return) because a "same key
  -- already there" slot is only a usable merge target if it isn't already
  -- a maxed-out 64 stack; without checking that, this can get stuck
  -- repeatedly re-targeting a full stack while a genuinely empty slot in
  -- the same range sits unused (verified this deadlock in testing).
  local occupant, slotCount = {}, {}
  for key, info in pairs(byKey) do
    for _, loc in ipairs(info.locations) do
      occupant[slotId(loc)] = key
      slotCount[slotId(loc)] = loc.count
    end
  end

  local moved, unmovable = 0, 0
  for _, key in ipairs(rankOrder) do
    local range = targets[key] or {}
    local inRange = {}
    for _, loc in ipairs(range) do inRange[slotId(loc)] = true end

    for _, loc in ipairs(byKey[key].locations) do
      if not inRange[slotId(loc)] then
        local dest
        for _, t in ipairs(range) do
          local sid = slotId(t)
          if occupant[sid] == key and (slotCount[sid] or 0) < 64 then dest = t; break end
        end
        if not dest then
          for _, t in ipairs(range) do
            if not occupant[slotId(t)] then dest = t; break end
          end
        end
        if dest then
          -- toSlot must be explicit here: without it, pushItems auto-merges
          -- into WHATEVER compatible slot the destination chest happens to
          -- have, which can silently differ from the exact slot picked
          -- above and desync this whole function's bookkeeping from reality
          -- (verified this causes real non-convergent thrashing in testing).
          local m = peripheral.wrap(loc.inv).pushItems(dest.inv, loc.slot, loc.count, dest.slot)
          moved = moved + m
          if m > 0 then
            local destId = slotId(dest)
            occupant[destId] = key
            slotCount[destId] = (slotCount[destId] or 0) + m
            if m >= loc.count then
              occupant[slotId(loc)] = nil
              slotCount[slotId(loc)] = nil
            else
              slotCount[slotId(loc)] = loc.count - m
              unmovable = unmovable + 1
            end
          else
            unmovable = unmovable + 1
          end
        else
          unmovable = unmovable + 1
        end
      end
    end
  end
  return moved, unmovable
end

term.clear(); term.setCursorPos(1, 1)
print("Storage manager running.")
print(("Watching %d chest(s), importing from %s"):format(#storages, INPUT))

local importTimer   = os.startTimer(IMPORT_INTERVAL)
local rebalanceTimer  = os.startTimer(REBALANCE_INTERVAL)
local heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" then
    if ev[2] == importTimer then
      local ok, result = pcall(importFromInput)
      if ok and result > 0 then
        print(("imported %d item(s)"):format(result))
        notifyMain({ cmd = "storageChanged" })
      elseif not ok then
        print("import error: " .. tostring(result))
      end
      importTimer = os.startTimer(IMPORT_INTERVAL)

    elseif ev[2] == rebalanceTimer then
      local ok, moved, unmovable = pcall(rebalance)
      if ok then
        if moved > 0 then
          print(("rebalanced: moved %d item(s), %d stack(s) still waiting on room"):format(moved, unmovable))
          notifyMain({ cmd = "storageChanged" })
        end
      else
        print("rebalance error: " .. tostring(moved))
      end
      rebalanceTimer = os.startTimer(REBALANCE_INTERVAL)

    elseif ev[2] == heartbeatTimer then
      notifyMain({ cmd = "heartbeat" })
      heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
    end
  end
end
