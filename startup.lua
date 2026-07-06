--[[  storage.lua  -----------------------------------------------------------
  Compact-storage system for CC: Tweaked (ATM10 / MC 1.21.1).

  INTERACTION  ->  keyboard, at the computer (right-click it):
      type to search  |  Up/Down to pick  |  Enter to withdraw
      then type amount, Enter to confirm  (Esc cancels, Backspace edits)

  MONITOR  ->  passive stats dashboard, auto-refreshes every 15s:
      total items, item types, slots used, and the top items in storage.
      Full resync every 10 min, or tap the REFRESH button any time.

  Auto-imports anything dropped in the INPUT barrel, packed densely.
  Save as "startup.lua" so it auto-runs. Config is baked in below.
--------------------------------------------------------------------------- ]]

-------------------------- CONFIG -------------------------------------------
local INPUT  = "minecraft:barrel_2"
local OUTPUT = "enderstorage:ender_chest_0"
-- Where POCKET-COMPUTER withdrawals go. Set this to an EnderStorage ender
-- chest so items land in your matching Ender Pouch anywhere. Leave nil to
-- just use OUTPUT. Find its name with the peripheral-listing trick; it's
-- likely something like "enderstorage:ender_chest_0".
local REMOTE_OUTPUT = nil
local IMPORT_INTERVAL = 2     -- seconds: how often loot is pulled from INPUT
local STATS_INTERVAL  = 600   -- seconds: full resync + repaint (600 = 10 min)
----------------------------------------------------------------------------

local monitor = peripheral.find("monitor")
if not monitor then error("No monitor found. Attach an Advanced Monitor.", 0) end
monitor.setTextScale(0.5)

if not peripheral.isPresent(INPUT)  then error("INPUT '"..INPUT.."' not found",  0) end
if not peripheral.isPresent(OUTPUT) then error("OUTPUT '"..OUTPUT.."' not found", 0) end

local storages = {}
for _, name in ipairs(peripheral.getNames()) do
  if name:find("^sophisticatedstorage:") then storages[#storages + 1] = name end
end
if #storages == 0 then error("No sophisticatedstorage chests found.", 0) end

-- Optional: wireless/ender modem enables the pocket-computer remote.
-- Everything still works locally if no wireless modem is attached.
local REMOTE_PROTO, REMOTE_HOST = "cg_storage", "mainstore"
local remoteOn = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
    rednet.open(name)
    rednet.host(REMOTE_PROTO, REMOTE_HOST)
    remoteOn = true
    break
  end
end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local index, filtered = {}, {}
local nameCache, freeSlots = {}, {}
local usedSlots, totalSlots = 0, 0
local query = ""

-- terminal (keyboard) UI state
local tMode, tSel, tScroll, tSelected, tAmount = "browse", 1, 1, nil, ""
local pollCount, barrelSeen, lastErr = 0, 0, nil   -- import heartbeat / diagnostics
local refreshBtn = nil        -- clickable area for the monitor REFRESH button

local function keyOf(item) return item.name .. "|" .. (item.nbt or "") end

---------------------------------------------------------------------------
-- INDEX + MOVEMENT
---------------------------------------------------------------------------
local function buildIndex()
  local agg = {}
  usedSlots, totalSlots = 0, 0
  for _, name in ipairs(storages) do
    local inv, used = peripheral.wrap(name), 0
    for slot, item in pairs(inv.list()) do
      used = used + 1
      local k = keyOf(item)
      local e = agg[k]
      if not e then
        if not nameCache[k] then
          local d = inv.getItemDetail(slot)
          nameCache[k] = (d and d.displayName) or item.name
        end
        e = { key = k, displayName = nameCache[k], count = 0, locations = {} }
        agg[k] = e
      end
      e.count = e.count + item.count
      e.locations[#e.locations + 1] = { inv = name, slot = slot }
    end
    local size = inv.size()
    freeSlots[name] = size - used
    usedSlots  = usedSlots + used
    totalSlots = totalSlots + size
  end
  index = {}
  for _, e in pairs(agg) do index[#index + 1] = e end
  table.sort(index, function(a, b) return a.displayName:lower() < b.displayName:lower() end)
end

local function findEntry(key)
  for _, e in ipairs(index) do if e.key == key then return e end end
end

local function filterBy(q)
  if q == "" then return index end
  local out, ql = {}, q:lower()
  for _, e in ipairs(index) do
    if e.displayName:lower():find(ql, 1, true) then out[#out + 1] = e end
  end
  return out
end

local function applyFilter() filtered = filterBy(query) end

-- Pull everything out of `source` and pack it densely into storage.
-- Returns the number of items moved. One cheap list() call if source is empty.
local function absorb(source)
  local inv = peripheral.wrap(source)
  local contents = inv.list()
  if next(contents) == nil then return 0 end

  local movedTotal = 0
  for slot, item in pairs(contents) do
    local remaining, k = item.count, keyOf(item)
    local e = findEntry(k)
    if e then
      local seen = {}
      for _, loc in ipairs(e.locations) do
        if remaining <= 0 then break end
        if not seen[loc.inv] then
          seen[loc.inv] = true
          local moved = inv.pushItems(loc.inv, slot, remaining)
          remaining = remaining - moved
          movedTotal = movedTotal + moved
        end
      end
    end
    if remaining > 0 then
      for _, name in ipairs(storages) do
        if remaining <= 0 then break end
        if (freeSlots[name] or 0) > 0 then
          local moved = inv.pushItems(name, slot, remaining)
          remaining = remaining - moved
          movedTotal = movedTotal + moved
          if moved > 0 then freeSlots[name] = math.max(0, freeSlots[name] - 1) end
        end
      end
    end
  end
  return movedTotal
end

-- Fast-tick auto-import from the INPUT barrel. Returns true if it moved stuff.
local function importInput() return absorb(INPUT) > 0 end

local function withdraw(entry, amount, dest)
  dest = dest or OUTPUT
  local got = 0
  for _, loc in ipairs(entry.locations) do
    if got >= amount then break end
    got = got + peripheral.wrap(loc.inv).pushItems(dest, loc.slot, amount - got)
  end
  return got
end

---------------------------------------------------------------------------
-- MONITOR: STATS DASHBOARD (passive)
---------------------------------------------------------------------------
local function comma(n)
  local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (s:gsub("^,", ""))
end

local function drawStats()
  local w, h = monitor.getSize()
  monitor.setBackgroundColor(colors.black); monitor.setTextColor(colors.white)
  monitor.clear()
  local function line(y, txt, col)
    if y < 1 or y > h then return end
    monitor.setCursorPos(1, y); monitor.setTextColor(col or colors.white)
    monitor.write(tostring(txt):sub(1, w))
  end

  local total = 0
  for _, e in ipairs(index) do total = total + e.count end
  local pct = totalSlots > 0 and math.floor((usedSlots / totalSlots) * 100) or 0

  line(1, "===  STORAGE STATUS  ===", colors.cyan)
  line(3, "Total items : " .. comma(total),  colors.white)
  line(4, "Item types  : " .. comma(#index), colors.white)
  line(5, ("Slots used  : %s / %s  (%d%%)"):format(comma(usedSlots), comma(totalSlots), pct),
        pct >= 90 and colors.red or colors.white)
  line(6, "Chests      : " .. #storages, colors.white)

  line(8, "Top items:", colors.yellow)
  local sorted = {}
  for _, e in ipairs(index) do sorted[#sorted + 1] = e end
  table.sort(sorted, function(a, b) return a.count > b.count end)
  local rows = math.min(15, h - 10)     -- as many as fit; leave row h for footer
  for i = 1, rows do
    local e = sorted[i]; if not e then break end
    line(9 + i, ("%2d. %8sx  %s"):format(i, comma(e.count), e.displayName), colors.lightGray)
  end

  local ok, ts = pcall(os.date, "%H:%M:%S")
  line(h, ok and ("Updated " .. ts) or "", colors.gray)

  -- manual REFRESH button, bottom-right
  local label = " REFRESH "
  local bx = math.max(1, w - #label + 1)
  monitor.setCursorPos(bx, h)
  monitor.setBackgroundColor(colors.green); monitor.setTextColor(colors.white)
  monitor.write(label)
  monitor.setBackgroundColor(colors.black)
  refreshBtn = { x1 = bx, x2 = bx + #label - 1, y = h }
end

---------------------------------------------------------------------------
-- TERMINAL: KEYBOARD UI (all interaction happens here)
---------------------------------------------------------------------------
local function drawTerminal()
  local tw, th = term.getSize()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()

  if tMode == "browse" then
    if tSel < 1 then tSel = 1 end
    if tSel > #filtered then tSel = math.max(1, #filtered) end
    term.setCursorPos(1, 1); term.setTextColor(colors.yellow)
    term.write("Search: " .. query)
    term.setCursorPos(1, 2); term.setTextColor(colors.lightGray)
    term.write(("%d matches  "):format(#filtered) .. "Up/Down + Enter = withdraw")
    term.setCursorPos(1, 3)
    if lastErr then
      term.setTextColor(colors.red); term.write(("ERR: " .. lastErr):sub(1, tw))
    else
      term.setTextColor(colors.gray)
      term.write(("poll #%d   in-barrel: %d"):format(pollCount, barrelSeen):sub(1, tw))
    end

    local top = 4
    local rows = th - top + 1
    if tSel < tScroll then tScroll = tSel end
    if tSel > tScroll + rows - 1 then tScroll = tSel - rows + 1 end
    if tScroll < 1 then tScroll = 1 end
    for i = 0, rows - 1 do
      local e = filtered[tScroll + i]; if not e then break end
      local y, sel = top + i, (tScroll + i == tSel)
      term.setCursorPos(1, y)
      term.setBackgroundColor(sel and colors.gray or colors.black)
      term.setTextColor(sel and colors.white or colors.lightGray)
      local ln = ("%6dx %s"):format(e.count, e.displayName):sub(1, tw)
      term.write(ln .. string.rep(" ", tw - #ln))
    end
    term.setBackgroundColor(colors.black); term.setTextColor(colors.yellow)
    term.setCursorPos(9 + #query, 1); term.setCursorBlink(true)

  elseif tMode == "amount" then
    term.setCursorBlink(true)
    term.setCursorPos(1, 1); term.setTextColor(colors.cyan)
    term.write("Withdraw: " .. tSelected.displayName)
    term.setCursorPos(1, 2); term.setTextColor(colors.lightGray)
    term.write(("Available: %d"):format(tSelected.count))
    term.setCursorPos(1, 4); term.setTextColor(colors.yellow)
    term.write("Amount: " .. tAmount)
    term.setCursorPos(1, 6); term.setTextColor(colors.lightGray)
    term.write("[Enter] confirm   [Esc] cancel   [Bksp] delete")
    term.setCursorPos(9 + #tAmount, 4); term.setTextColor(colors.yellow)
  end
end

---------------------------------------------------------------------------
-- REMOTE (pocket computer) REQUEST HANDLER
---------------------------------------------------------------------------
local function handleRemote(sender, msg)
  if type(msg) ~= "table" then return end
  if msg.cmd == "list" then
    local matches = filterBy(msg.query or "")
    local out = {}
    for i = 1, math.min(#matches, msg.limit or 60) do
      out[i] = { key = matches[i].key, name = matches[i].displayName, count = matches[i].count }
    end
    rednet.send(sender, { ok = true, items = out, total = #matches }, REMOTE_PROTO)

  elseif msg.cmd == "withdraw" then
    local e = findEntry(msg.key)
    if not e then rednet.send(sender, { ok = false, err = "gone" }, REMOTE_PROTO); return end
    local n = math.min(tonumber(msg.amount) or 0, e.count)
    local dest = REMOTE_OUTPUT or OUTPUT
    local moved = (n > 0) and withdraw(e, n, dest) or 0
    buildIndex(); applyFilter(); drawStats()
    rednet.send(sender, { ok = true, moved = moved, name = e.displayName }, REMOTE_PROTO)

  elseif msg.cmd == "deposit" then
    -- Suck the OUTPUT / ender chest back into storage (remote input).
    local moved = absorb(REMOTE_OUTPUT or OUTPUT)
    if moved > 0 then buildIndex(); applyFilter(); drawStats() end
    rednet.send(sender, { ok = true, moved = moved }, REMOTE_PROTO)

  elseif msg.cmd == "stats" then
    local total = 0
    for _, e in ipairs(index) do total = total + e.count end
    rednet.send(sender, { ok = true, total = total, types = #index,
      used = usedSlots, slots = totalSlots }, REMOTE_PROTO)
  end
end

---------------------------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------------------------
local function reselect()
  if tMode == "amount" then
    tSelected = tSelected and findEntry(tSelected.key)
    if not tSelected then tMode = "browse" end
  end
end

buildIndex(); importInput(); buildIndex(); applyFilter()
drawStats(); drawTerminal()

local impTimer  = os.startTimer(IMPORT_INTERVAL)
local statTimer = os.startTimer(STATS_INTERVAL)

while true do
  local ev = { os.pullEvent() }
  local e1 = ev[1]

  if e1 == "timer" then
    if ev[2] == impTimer then
      -- Peek the barrel, import if anything is there. Wrapped in pcall so a
      -- transient error can never silently kill the loop; it shows instead.
      pollCount = pollCount + 1
      local ok, err = pcall(function()
        local bar = peripheral.wrap(INPUT)
        local contents = bar and bar.list() or {}
        barrelSeen = 0
        for _, it in pairs(contents) do barrelSeen = barrelSeen + it.count end
        if barrelSeen > 0 then
          absorb(INPUT)
          buildIndex(); applyFilter(); reselect()
        end
      end)
      if ok then lastErr = nil else lastErr = tostring(err) end
      drawTerminal()
      impTimer = os.startTimer(IMPORT_INTERVAL)
    elseif ev[2] == statTimer then
      -- Periodic full resync: also catches items removed from chests by hand.
      buildIndex(); applyFilter(); reselect()
      drawStats(); drawTerminal()
      statTimer = os.startTimer(STATS_INTERVAL)
    end

  elseif e1 == "char" then
    local c = ev[2]
    if tMode == "browse" then
      query = query .. c; applyFilter(); tSel = 1; tScroll = 1
    elseif tMode == "amount" then
      if c:match("%d") and #tAmount < 6 then tAmount = tAmount .. c end
    end
    drawTerminal()

  elseif e1 == "key" then
    local code = ev[2]
    if tMode == "browse" then
      if code == keys.backspace then query = query:sub(1, -2); applyFilter(); tSel = 1
      elseif code == keys.up then tSel = math.max(1, tSel - 1)
      elseif code == keys.down then tSel = math.min(#filtered, tSel + 1)
      elseif code == keys.enter then
        local sel = filtered[tSel]
        if sel then tSelected = sel; tAmount = tostring(math.min(64, sel.count)); tMode = "amount" end
      end
      drawTerminal()
    elseif tMode == "amount" then
      if code == keys.backspace then tAmount = tAmount:sub(1, -2); drawTerminal()
      elseif code == keys.escape then tMode = "browse"; drawTerminal()
      elseif code == keys.enter then
        local n = math.min(tonumber(tAmount) or 0, tSelected.count)
        if n > 0 then withdraw(tSelected, n) end
        tMode = "browse"
        buildIndex(); applyFilter()
        drawTerminal(); drawStats()        -- refresh both after a withdraw
      end
    end

  elseif e1 == "redstone" then
    -- A comparator on the INPUT barrel pulses redstone when items arrive,
    -- so we import right away instead of waiting for the next poll.
    if importInput() then
      buildIndex(); applyFilter(); reselect()
      drawTerminal()
    end

  elseif e1 == "rednet_message" then
    if ev[4] == REMOTE_PROTO then handleRemote(ev[2], ev[3]) end

  elseif e1 == "monitor_touch" then
    local x, y = ev[3], ev[4]
    if refreshBtn and y == refreshBtn.y and x >= refreshBtn.x1 and x <= refreshBtn.x2 then
      pcall(function() absorb(INPUT) end)      -- also vacuum the input barrel
      buildIndex(); applyFilter(); reselect()
      drawStats(); drawTerminal()
    end

  elseif e1 == "monitor_resize" then
    drawStats()
  end
end
