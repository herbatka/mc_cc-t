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
    3. Actively measuring each chest's real per-slot capacity (stack
       upgrades push this well past vanilla's 64) at startup and hourly:
       takes whichever item you have the most of and, one chest at a time,
       piles as much of it as exists into a single slot there to see what
       actually lands - much faster than waiting for rebalancing alone to
       reveal it by chance.

  The main computer (startup.lua) never touches INPUT or does this
  consolidation itself anymore - it just gets told over rednet whenever this
  computer moves something, so its cached view of storage stays fresh.

  Save as this computer's "startup.lua" so it runs automatically.
--------------------------------------------------------------------------- ]]

-------------------------- CONFIG -------------------------------------------
local INPUT = "minecraft:barrel_2"
local IMPORT_INTERVAL   = 2     -- seconds: how often INPUT is checked
local REBALANCE_INTERVAL  = 300   -- seconds: how often to rebalance (5 min)
local PROBE_INTERVAL = 3600   -- seconds: how often to actively re-measure
                              -- chest capacities (1 hour) - runs at startup too
local HEARTBEAT_INTERVAL = 15   -- seconds: "I'm alive" ping even if nothing moved
-- Default assumed stack capacity per slot before anything's been observed
-- (matches an un-upgraded vanilla stack) - see chestCapacity below for how
-- the real, possibly-upgraded capacity is actually determined.
local DEFAULT_STACK_CAP = 64
-- An item only overtakes its neighbor in chest-priority order if it beats it
-- by more than this many items - without this, two items with close totals
-- would swap chest position back and forth on every run as their counts
-- naturally seesaw during normal play.
local RANK_SWAP_THRESHOLD = 64
local MANAGER_PROTO, MAIN_HOST = "cg_manager", "mainstore"
local LOG_FILE = "manager.log"
local LOG_MAX_BYTES = 200000   -- trimmed back to the last half once exceeded,
                                -- so this never eats into the computer's
                                -- overall disk quota (computer_space_limit)
----------------------------------------------------------------------------

if not peripheral.isPresent(INPUT) then error("INPUT '"..INPUT.."' not found", 0) end

-- Sorted for a stable, deterministic chest order across reboots - "chest 1"
-- below means whichever chest sorts first alphabetically by peripheral
-- name, not necessarily whichever one you think of as first physically.
--
-- Re-scanned at the start of every timer firing (see refreshStorages
-- below) rather than only once at startup - a chest broken, moved, or
-- disconnected hours into a run used to leave a permanently stale entry
-- here, and every subsequent pushItems() call naming it hard-errors
-- ("Target '...' does not exist"), which used to spam that same error
-- forever since nothing ever re-checked the actual chest list again.
local storages = {}

local function refreshStorages()
  local fresh = {}
  for _, name in ipairs(peripheral.getNames()) do
    if name:find("^sophisticatedstorage:") then fresh[#fresh + 1] = name end
  end
  table.sort(fresh)
  storages = fresh
end

refreshStorages()
if #storages == 0 then error("No sophisticatedstorage chests found.", 0) end

local opened = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then rednet.open(name); opened = true end
end
if not opened then error("No modem attached. Attach a Wired or Wireless Modem.", 0) end

local mainId = nil   -- resolved lazily; startup.lua might not be booted yet

local function keyOf(item) return item.name .. "|" .. (item.nbt or "") end
local function keyItemName(key) return key:match("^([^|]*)") or key end
local function prettify(name)
  local short = name:gsub("^.-:", ""):gsub("_", " ")
  return (short:gsub("(%a)([%w']*)", function(f, r) return f:upper() .. r end))
end

local function notifyMain(msg)
  if not mainId then mainId = rednet.lookup(MANAGER_PROTO, MAIN_HOST) end
  if mainId then rednet.send(mainId, msg, MANAGER_PROTO) end
end

-- Optional: an attached monitor gets the full granular activity log (every
-- import, every move/eviction, every probe result) - this computer's own
-- terminal deliberately does NOT get this detail, it only shows coarse
-- batch-level summaries (see logDetail vs. the plain print() calls below).
-- Entirely optional; nothing needs a monitor to work.
local monitor = peripheral.find("monitor")
local monitorName = monitor and peripheral.getName(monitor)
local buttonBounds = nil   -- {x1, x2, y} of the on-screen "SORT NOW" button

-- The button lives pinned to row 1. Scrolling the monitor (see logDetail)
-- shifts the WHOLE screen including row 1, so this has to be re-drawn after
-- every scroll, not just once at startup, or the button would scroll away
-- after the first screenful of log lines.
local function drawSortButton()
  if not monitor then return end
  local w = monitor.getSize()
  local label = " SORT NOW "
  monitor.setCursorPos(1, 1)
  monitor.setBackgroundColor(colors.gray)
  monitor.setTextColor(colors.white)
  monitor.write(label)
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
  buttonBounds = { x1 = 1, x2 = math.min(w, #label), y = 1 }
end

if monitor then
  monitor.setTextScale(0.5)
  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
  monitor.clear()
  drawSortButton()
  monitor.setCursorPos(1, 1)   -- log lines start filling from row 2 onward
end

-- Keeps LOG_FILE from growing without bound (and eventually running the
-- computer out of disk space) by dropping the older half once it crosses
-- LOG_MAX_BYTES, rather than deleting/rotating it outright - so there's
-- always recent history in it, just not literally everything ever logged.
local function trimLogFileIfNeeded()
  if not (fs.exists(LOG_FILE) and fs.getSize(LOG_FILE) > LOG_MAX_BYTES) then return end
  local f = io.open(LOG_FILE, "r")
  if not f then return end
  local lines = {}
  for l in f:lines() do lines[#lines + 1] = l end
  f:close()
  local out = io.open(LOG_FILE, "w")
  if out then
    for i = math.floor(#lines / 2) + 1, #lines do out:write(lines[i], "\n") end
    out:close()
  end
end

-- Granular, per-action detail (every import transfer, every move/eviction
-- with exact source/destination chest and slot, every probe result) - goes
-- ONLY to the monitor (if attached) and LOG_FILE, never to this computer's
-- own terminal, which stays limited to coarse batch-level summaries printed
-- directly with plain print() at the call sites below. Appends to LOG_FILE
-- so the whole session's activity can be pulled off the computer later
-- (e.g. `pastebin put manager.log` run directly on this computer gets a
-- shareable link, no copy-pasting needed). Timestamped with in-game time of
-- day so it's obvious how recent an entry is during a long-running session.
local logLineCount = 0
local function logDetail(msg)
  local line = ("[%s] %s"):format(textutils.formatTime(os.time(), true), msg)
  if monitor then
    local w, h = monitor.getSize()
    local _, y = monitor.getCursorPos()
    if y >= h then
      monitor.scroll(1)
      drawSortButton()   -- scrolling wiped row 1 (the button) - redraw it
      monitor.setCursorPos(1, h)
    else
      monitor.setCursorPos(1, y + 1)
    end
    monitor.write(line:sub(1, w))
  end
  local f = io.open(LOG_FILE, "a")
  if f then f:write(line, "\n"); f:close() end
  logLineCount = logLineCount + 1
  if logLineCount % 50 == 0 then trimLogFileIfNeeded() end
end

-- pushItems() throws a hard error if its target has vanished since it was
-- last seen (a chest broken/moved/disconnected in the moment between
-- refreshStorages() and actually using it - a narrow window, but the
-- source of the very error that motivated refreshStorages() in the first
-- place). Treating that the same as "0 moved" keeps one missing chest
-- from crashing an entire import/rebalance/probe pass instead of just
-- skipping that one move and continuing.
local function safePush(fromInv, fromSlot, toName, limit, toSlot)
  local inv = peripheral.wrap(fromInv)
  if not inv then return 0 end
  local ok, moved = pcall(inv.pushItems, toName, fromSlot, limit, toSlot)
  return ok and moved or 0
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
    local label = prettify(item.name)
    for _, name in ipairs(storages) do
      if remaining <= 0 then break end
      local m = safePush(INPUT, slot, name, remaining)
      if m > 0 then logDetail(("Import: %dx %s -> %s"):format(m, label, name)) end
      remaining = remaining - m
      moved = moved + m
    end
    if remaining > 0 then
      logDetail(("Import: %dx %s left in %s - no chest had room"):format(remaining, label, INPUT))
    end
  end
  return moved
end

-- Persists (in memory - resets on reboot, which is fine) across runs.
-- CC:Tweaked's generic inventory peripheral has no "get this slot's real
-- capacity" query, and sophisticatedstorage's stack upgrades raise that
-- capacity per chest (not per item) well past vanilla's 64 - so this is
-- discovered empirically instead: whatever the biggest stack actually
-- observed in a chest is, that chest can hold at least that much. Starts
-- at DEFAULT_STACK_CAP and only ever grows, so a stack upgrade added later
-- gets picked up automatically once anything actually fills past the old
-- high-water mark (pushItems itself is never capped at our assumption -
-- only slot-count PLANNING is - so a push can still land above what we'd
-- assumed, revealing more real capacity on the next scan).
local chestCapacity = {}   -- chest peripheral name -> largest count ever seen there

-- One full scan of every chest, grouping every stack by item key with each
-- key's total count across all locations, and updating chestCapacity from
-- whatever's actually observed. Same idea as startup.lua's buildIndex(),
-- but this computer doesn't need a persistent searchable index - just a
-- fresh snapshot each time rebalance() runs.
local function scanByKey()
  local byKey = {}
  for _, name in ipairs(storages) do
    local inv = peripheral.wrap(name)
    if inv then   -- skip a chest that vanished since refreshStorages() ran
      chestCapacity[name] = chestCapacity[name] or DEFAULT_STACK_CAP
      for slot, item in pairs(inv.list()) do
        local k = keyOf(item)
        if not byKey[k] then byKey[k] = { total = 0, locations = {} } end
        byKey[k].total = byKey[k].total + item.count
        local locs = byKey[k].locations
        locs[#locs + 1] = { inv = name, slot = slot, count = item.count }
        if item.count > chestCapacity[name] then chestCapacity[name] = item.count end
      end
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
    if inv then   -- skip a chest that vanished since refreshStorages() ran
      for slot = 1, inv.size() do
        slots[#slots + 1] = { inv = name, slot = slot }
      end
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

-- Walks rankOrder in priority order, handing each key just enough slots off
-- the front of the flattened chest/slot list to cover its total - using
-- each slot's OWN chest's discovered capacity rather than a flat 64, since
-- different chests can have different stack upgrades installed.
local function assignTargets(byKey, slots)
  local targets, ptr = {}, 1
  for _, key in ipairs(rankOrder) do
    local remaining = byKey[key].total
    local range = {}
    while remaining > 0 and slots[ptr] do
      range[#range + 1] = slots[ptr]
      remaining = remaining - (chestCapacity[slots[ptr].inv] or DEFAULT_STACK_CAP)
      ptr = ptr + 1
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
  -- maxed out (per that CHEST's discovered capacity, not a flat 64);
  -- without checking that, this can get stuck repeatedly re-targeting a
  -- full stack while a genuinely empty slot in the same range sits unused
  -- (verified this deadlock in testing).
  local occupant, slotCount = {}, {}
  for key, info in pairs(byKey) do
    for _, loc in ipairs(info.locations) do
      occupant[slotId(loc)] = key
      slotCount[slotId(loc)] = loc.count
    end
  end

  -- Global pool of every slot that's genuinely empty right now, anywhere -
  -- not scoped to any one item's target range. Once storage gets fairly
  -- full, a target slot being occupied by something that hasn't had its
  -- own turn yet is the common case, not the exception - without a way to
  -- displace it somewhere, that slot (and the item that actually belongs
  -- there) would just sit blocked forever, which is exactly what "N
  -- stack(s) still waiting on room" staying high run after run means.
  -- Using any free slot in the whole network as scratch space to evict
  -- into (rather than requiring the free slot to be within that specific
  -- range) turns most of those into real, if temporary, progress - the
  -- displaced item lands somewhere for now and gets its own shot at
  -- reaching its real target on its own turn (later this run, or next).
  local freeSlots = {}
  for _, loc in ipairs(slots) do
    if not occupant[slotId(loc)] then freeSlots[#freeSlots + 1] = loc end
  end

  local itemCount = 0
  for _ in pairs(byKey) do itemCount = itemCount + 1 end
  logDetail(("Rebalance: %d distinct item(s) across %d chest(s), rank order: %s")
    :format(itemCount, #storages, table.concat((function()
      local names = {}
      for _, k in ipairs(rankOrder) do names[#names + 1] = prettify(keyItemName(k)) end
      return names
    end)(), " > ")))

  local moved, unmovable = 0, 0
  for _, key in ipairs(rankOrder) do
    local range = targets[key] or {}
    local inRange = {}
    for _, loc in ipairs(range) do inRange[slotId(loc)] = true end
    local itemLabel = prettify(keyItemName(key))

    for _, loc in ipairs(byKey[key].locations) do
      if not inRange[slotId(loc)] then
        local dest
        for _, t in ipairs(range) do
          local sid = slotId(t)
          local cap = chestCapacity[t.inv] or DEFAULT_STACK_CAP
          if occupant[sid] == key and (slotCount[sid] or 0) < cap then dest = t; break end
        end
        if not dest then
          for _, t in ipairs(range) do
            if not occupant[slotId(t)] then dest = t; break end
          end
        end
        if not dest then
          for _, t in ipairs(range) do
            local sid = slotId(t)
            local blocker = occupant[sid]
            if blocker and blocker ~= key then
              local scratch = table.remove(freeSlots)
              if scratch then
                local blockerCount = slotCount[sid]
                local m = safePush(t.inv, t.slot, scratch.inv, blockerCount, scratch.slot)
                if m >= blockerCount then
                  occupant[sid] = nil; slotCount[sid] = nil
                  local scratchId = slotId(scratch)
                  occupant[scratchId] = blocker; slotCount[scratchId] = m
                  -- The blocker's own bookkeeping has to follow it to its
                  -- new spot, or its own turn later in this same run (if
                  -- it hasn't had one yet) would try to move a stack that
                  -- isn't there anymore.
                  local blockerInfo = byKey[blocker]
                  if blockerInfo then
                    for _, bl in ipairs(blockerInfo.locations) do
                      if bl.inv == t.inv and bl.slot == t.slot then
                        bl.inv, bl.slot = scratch.inv, scratch.slot
                        break
                      end
                    end
                  end
                  logDetail(("Evict: %dx %s  %s:%d -> %s:%d (clearing space for %s)")
                    :format(m, prettify(keyItemName(blocker)), t.inv, t.slot, scratch.inv, scratch.slot, itemLabel))
                  dest = t
                else
                  -- partial/failed push (blocker's chest may have vanished,
                  -- see safePush) - give the scratch slot back, try the
                  -- next occupied slot in range instead
                  freeSlots[#freeSlots + 1] = scratch
                end
              end
              if dest then break end
            end
          end
        end
        if dest then
          -- toSlot must be explicit here: without it, pushItems auto-merges
          -- into WHATEVER compatible slot the destination chest happens to
          -- have, which can silently differ from the exact slot picked
          -- above and desync this whole function's bookkeeping from reality
          -- (verified this causes real non-convergent thrashing in testing).
          local m = safePush(loc.inv, loc.slot, dest.inv, loc.count, dest.slot)
          moved = moved + m
          if m > 0 then
            local destId = slotId(dest)
            occupant[destId] = key
            slotCount[destId] = (slotCount[destId] or 0) + m
            logDetail(("Move: %dx %s  %s:%d -> %s:%d"):format(m, itemLabel, loc.inv, loc.slot, dest.inv, dest.slot))
            if m >= loc.count then
              occupant[slotId(loc)] = nil
              slotCount[slotId(loc)] = nil
              freeSlots[#freeSlots + 1] = loc
            else
              slotCount[slotId(loc)] = loc.count - m
              unmovable = unmovable + 1
              logDetail(("Stuck (partial): %s at %s:%d - only %d of %d moved, rest waits for next run")
                :format(itemLabel, loc.inv, loc.slot, m, loc.count))
            end
          else
            unmovable = unmovable + 1
            logDetail(("Stuck (push failed): %s at %s:%d -> %s:%d didn't take"):format(itemLabel, loc.inv, loc.slot, dest.inv, dest.slot))
          end
        else
          unmovable = unmovable + 1
          logDetail(("Stuck (no room): %s at %s:%d - target slots all occupied, no free slot anywhere to evict into")
            :format(itemLabel, loc.inv, loc.slot))
        end
      end
    end
  end
  return moved, unmovable
end

-- Actively measures every chest's real capacity instead of waiting to
-- passively observe one during normal rebalancing: takes whichever item
-- has the highest total count right now (the one most likely to actually
-- be enough to hit a chest's true ceiling) and, one chest at a time, drags
-- as much of it as exists anywhere into a single slot there, then reads
-- back whatever actually landed. Chests get tested in turn using the same
-- pooled stock, so nothing is lost - it just ends up wherever the last
-- chest tested could hold it, and rebalance() puts it back where it
-- actually belongs afterward.
local function probeCapacities()
  local seed = scanByKey()
  local bestKey, bestTotal
  for key, info in pairs(seed) do
    if not bestTotal or info.total > bestTotal then bestKey, bestTotal = key, info.total end
  end
  if not bestKey then return 0 end   -- nothing in storage yet

  local itemLabel = prettify(keyItemName(bestKey))
  logDetail(("Probe: using %s (%d total) to test capacity of %d chest(s)"):format(itemLabel, bestTotal, #storages))

  local probed = 0
  for _, name in ipairs(storages) do
    local inv = peripheral.wrap(name)   -- nil if this chest vanished mid-run
    local info = scanByKey()[bestKey]
    if not info then break end

    if inv then
      local targetSlot
      for _, loc in ipairs(info.locations) do
        if loc.inv == name then targetSlot = loc.slot; break end
      end
      if not targetSlot then
        local contents = inv.list()
        for slot = 1, inv.size() do
          if not contents[slot] then targetSlot = slot; break end
        end
      end

      if targetSlot then
        for _, loc in ipairs(info.locations) do
          if not (loc.inv == name and loc.slot == targetSlot) then
            safePush(loc.inv, loc.slot, name, loc.count, targetSlot)
          end
        end
        local landed = inv.list()[targetSlot]
        local observed = landed and landed.count or 0
        local prevCap = chestCapacity[name] or DEFAULT_STACK_CAP
        if observed > prevCap then
          chestCapacity[name] = observed
          logDetail(("Probe: %s:%d holds %d %s - capacity raised from %d to %d"):format(name, targetSlot, observed, itemLabel, prevCap, observed))
        else
          logDetail(("Probe: %s:%d holds %d %s - capacity still %d (not enough %s to test further)"):format(name, targetSlot, observed, itemLabel, prevCap, itemLabel))
        end
        probed = probed + 1
      else
        logDetail(("Probe: %s has no slot free or already holding %s - skipped"):format(name, itemLabel))
      end
    end
  end
  return probed
end

-- Probing deliberately piles the test item into whichever chest it's
-- currently testing, which isn't where that item belongs by rank - so
-- always follow it with a rebalance() to put things back where they
-- actually belong, rather than leaving it there until the next scheduled
-- rebalance (up to REBALANCE_INTERVAL later).
local function probeThenRebalance()
  local ok, probed = pcall(probeCapacities)
  if not ok then
    print("capacity probe error: " .. tostring(probed))
    return
  end
  if probed > 0 then
    print(("Probe complete: measured %d chest(s)"):format(probed))
  end
  local rok, moved, unmovable = pcall(rebalance)
  if rok then
    if moved > 0 then
      print(("Rebalance complete: moved %d item(s), %d stack(s) still waiting on room"):format(moved, unmovable))
    end
  else
    print("rebalance error: " .. tostring(moved))
  end
  if probed > 0 or (rok and moved > 0) then notifyMain({ cmd = "storageChanged" }) end
end

-- Manually-triggered convergence loop for the monitor's "SORT NOW" button:
-- keeps calling rebalance() back to back (each pass builds on where the
-- last one left off) until a pass moves nothing, rather than waiting for
-- REBALANCE_INTERVAL to tick several times on its own. A safety cap keeps
-- a storage network that's genuinely too full to ever fully settle (see
-- rebalance's own "no free slot anywhere" case) from looping forever.
local SORT_MAX_PASSES = 50

local function sortUntilDone()
  print("Sort: running until storage is fully settled (SORT NOW pressed)...")
  local totalMoved = 0
  for pass = 1, SORT_MAX_PASSES do
    refreshStorages()
    local ok, moved, unmovable = pcall(rebalance)
    if not ok then
      print("Sort: rebalance error: " .. tostring(moved))
      return
    end
    totalMoved = totalMoved + moved
    if moved > 0 then notifyMain({ cmd = "storageChanged" }) end
    print(("Sort: pass %d - moved %d item(s), %d stack(s) still waiting on room"):format(pass, moved, unmovable))
    if moved == 0 then
      if unmovable > 0 then
        print(("Sort: stopped after %d pass(es) - %d stack(s) stuck with no free space anywhere to evict into (storage is essentially full)"):format(pass, unmovable))
      else
        print(("Sort: fully settled after %d pass(es), %d item(s) moved total"):format(pass, totalMoved))
      end
      return
    end
  end
  print(("Sort: stopped after hitting the %d-pass safety cap, %d item(s) moved total (still making progress - press SORT NOW again to continue)"):format(SORT_MAX_PASSES, totalMoved))
end

term.clear(); term.setCursorPos(1, 1)
print("Storage manager running.")
print(("Watching %d chest(s), importing from %s"):format(#storages, INPUT))

probeThenRebalance()   -- measure real chest capacities right away at startup

local importTimer    = os.startTimer(IMPORT_INTERVAL)
local rebalanceTimer  = os.startTimer(REBALANCE_INTERVAL)
local probeTimer      = os.startTimer(PROBE_INTERVAL)
local heartbeatTimer  = os.startTimer(HEARTBEAT_INTERVAL)

while true do
  local ev = { os.pullEvent() }
  if ev[1] == "timer" then
    if ev[2] == importTimer then
      refreshStorages()
      local ok, result = pcall(importFromInput)
      if ok and result > 0 then
        notifyMain({ cmd = "storageChanged" })
      elseif not ok then
        print("import error: " .. tostring(result))
      end
      importTimer = os.startTimer(IMPORT_INTERVAL)

    elseif ev[2] == rebalanceTimer then
      refreshStorages()
      local ok, moved, unmovable = pcall(rebalance)
      if ok then
        if moved > 0 then
          print(("Rebalance complete: moved %d item(s), %d stack(s) still waiting on room"):format(moved, unmovable))
          notifyMain({ cmd = "storageChanged" })
        end
      else
        print("rebalance error: " .. tostring(moved))
      end
      rebalanceTimer = os.startTimer(REBALANCE_INTERVAL)

    elseif ev[2] == probeTimer then
      refreshStorages()
      probeThenRebalance()
      probeTimer = os.startTimer(PROBE_INTERVAL)

    elseif ev[2] == heartbeatTimer then
      notifyMain({ cmd = "heartbeat" })
      heartbeatTimer = os.startTimer(HEARTBEAT_INTERVAL)
    end

  elseif ev[1] == "monitor_touch" and monitorName and ev[2] == monitorName then
    local x, y = ev[3], ev[4]
    if buttonBounds and y == buttonBounds.y and x >= buttonBounds.x1 and x <= buttonBounds.x2 then
      sortUntilDone()
    end
  end
end
