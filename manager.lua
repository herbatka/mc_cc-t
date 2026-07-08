--[[  manager.lua  ------------------------------------------------------------
  Storage-manager computer for the CC:Tweaked storage system (see README.md).

  Runs on its OWN computer, wired into the SAME sophisticatedstorage network
  as startup.lua's chests and the INPUT barrel. Takes two jobs off the main
  computer entirely:

    1. Importing whatever's dropped in the INPUT barrel.
    2. Periodically compacting storage - consolidating scattered stacks of
       the same item into as few slots as possible, so items actually stack
       up together instead of ending up as odd partial stacks spread across
       whichever chest happened to have room at import time.

  The main computer (startup.lua) never touches INPUT or does this
  consolidation itself anymore - it just gets told over rednet whenever this
  computer moves something, so its cached view of storage stays fresh.

  Save as this computer's "startup.lua" so it runs automatically.
--------------------------------------------------------------------------- ]]

-------------------------- CONFIG -------------------------------------------
local INPUT = "minecraft:barrel_2"
local IMPORT_INTERVAL   = 2     -- seconds: how often INPUT is checked
local COMPACT_INTERVAL  = 900   -- seconds: how often to consolidate (15 min)
local HEARTBEAT_INTERVAL = 15   -- seconds: "I'm alive" ping even if nothing moved
local MANAGER_PROTO, MAIN_HOST = "cg_manager", "mainstore"
----------------------------------------------------------------------------

if not peripheral.isPresent(INPUT) then error("INPUT '"..INPUT.."' not found", 0) end

local storages = {}
for _, name in ipairs(peripheral.getNames()) do
  if name:find("^sophisticatedstorage:") then storages[#storages + 1] = name end
end
if #storages == 0 then error("No sophisticatedstorage chests found.", 0) end

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
-- item across every chest - that's what compact() below is for; this just
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

-- One full scan of every chest, grouping every stack by item key. Same idea
-- as startup.lua's buildIndex(), but this computer doesn't need a persistent
-- searchable index - just a fresh snapshot each time compact() runs.
local function scanByKey()
  local byKey = {}
  for _, name in ipairs(storages) do
    local inv = peripheral.wrap(name)
    for slot, item in pairs(inv.list()) do
      local k = keyOf(item)
      if not byKey[k] then byKey[k] = {} end
      byKey[k][#byKey[k] + 1] = { inv = name, slot = slot, count = item.count }
    end
  end
  return byKey
end

-- For each item with more than one stack, pushes every other stack toward
-- whichever chest currently holds the most of it (pushItems auto-merges
-- into any existing compatible stack in that chest, filling it up before
-- landing in a new slot - same behavior startup.lua's absorb() already
-- relies on). Doesn't assign items a fixed "home" chest or slot - just
-- keeps repeating this over time converges toward fewer, fuller stacks
-- regardless of exactly where they end up.
local function compact()
  local byKey = scanByKey()
  local moved, freed = 0, 0
  for _, locs in pairs(byKey) do
    if #locs > 1 then
      table.sort(locs, function(a, b) return a.count > b.count end)
      local target = locs[1]
      for i = 2, #locs do
        local src = locs[i]
        local m = peripheral.wrap(src.inv).pushItems(target.inv, src.slot, src.count)
        moved = moved + m
        if m >= src.count then freed = freed + 1 end
      end
    end
  end
  return moved, freed
end

term.clear(); term.setCursorPos(1, 1)
print("Storage manager running.")
print(("Watching %d chest(s), importing from %s"):format(#storages, INPUT))

local importTimer   = os.startTimer(IMPORT_INTERVAL)
local compactTimer  = os.startTimer(COMPACT_INTERVAL)
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

    elseif ev[2] == compactTimer then
      local ok, moved, freed = pcall(compact)
      if ok then
        if moved > 0 then
          print(("compacted: moved %d item(s), freed %d slot(s)"):format(moved, freed))
          notifyMain({ cmd = "storageChanged" })
        end
      else
        print("compact error: " .. tostring(moved))
      end
      compactTimer = os.startTimer(COMPACT_INTERVAL)

    elseif ev[2] == heartbeatTimer then
      notifyMain({ cmd = "heartbeat" })
      heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
    end
  end
end
