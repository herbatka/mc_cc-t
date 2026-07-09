--[[  remote.lua  ------------------------------------------------------------
  Pocket-computer remote for the storage system (CC: Tweaked).

  Runs on an Advanced Pocket Computer crafted with a Wireless or Ender Modem.
  Lets you search your storage, craft known recipes, and queue withdrawals
  from anywhere.

  NOTE: items can't teleport to you. A withdrawal is pushed into the OUTPUT
  barrel back at the storage computer, ready to collect when you get home.
  Crafting happens on the main computer's turtle; this remote just tells it
  what to craft and shows you the ingredient list before you commit.

  CONTROLS
    Left/Right:  switch between the Search tab and the Craft tab.
    Search box:  type a name, Enter to search, Backspace to edit.
    Results:     Up/Down to pick, Enter to withdraw/craft, Backspace to edit.
    Amount:      type a number, Enter to continue, C to cancel.
    Tab:         deposit (search tab only, same as before).

  Save as "startup.lua" on the pocket computer so it runs when opened.
--------------------------------------------------------------------------- ]]

local PROTO, HOST = "cg_storage", "mainstore"

local modem = peripheral.find("modem")
if not modem then
  error("No modem. Craft this pocket computer with a Wireless or Ender Modem.", 0)
end
rednet.open(peripheral.getName(modem))

term.clear(); term.setCursorPos(1, 1)
print("Locating storage server...")
local server = rednet.lookup(PROTO, HOST)
if not server then
  error("Server not found.\nIs the main computer running and in modem range?", 0)
end

local function req(msg, timeout)
  rednet.send(server, msg, PROTO)
  local _, reply = rednet.receive(PROTO, timeout or 3)
  return reply
end

-- The main computer now runs a big craft as several turtle.craft() batches
-- back to back (each capped at 64), so a large request can take a lot
-- longer than a single batch used to - "no response" within a short
-- timeout here does NOT mean the craft failed, it's very likely still
-- running on the main computer regardless of what this remote shows.
local function craftStatusText(r, requestedAmount, displayName, destLabel)
  if r and r.ok then
    return ("Crafted %d x %s (%s)"):format(r.produced or requestedAmount, displayName, destLabel)
  elseif r then
    local got = r.produced or 0
    if got > 0 then
      return ("Crafted %d of %d x %s (%s), then failed: %s")
        :format(got, r.requested or requestedAmount, displayName, destLabel, tostring(r.err or "unknown error"))
    end
    return "Craft failed: " .. tostring(r.err or "unknown error")
  end
  return "No response yet - it may still be crafting on the main computer, check there or try again"
end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local uiTab     = "search"    -- "search" | "craft"

local mode      = "search"   -- "search" | "list" | "amount"
local query     = ""
local items     = {}
local total     = 0
local sel, scroll = 1, 1
local amountStr = ""
local status    = "Type a name, Enter to search"

local cMode      = "search"  -- "search" | "list" | "amount" | "confirm" | "status"
local cQuery     = ""
local citems     = {}
local ctotal     = 0
local csel, cscroll = 1, 1
local camountStr = ""
local cstatus    = "Type a name, Enter to search"
local cSelected  = nil
local cPlan, cCycles, cShort, cProduced, cHasSub = {}, 1, false, 0, false

local function fetch()
  local r = req({ cmd = "list", query = query, limit = 100 })
  if r and r.ok then
    items, total, sel, scroll = r.items, r.total, 1, 1
    status = (#items) .. " shown / " .. total .. " match"
  else
    items, total = {}, 0
    status = "No response from server"
  end
end

local function cfetch()
  local r = req({ cmd = "craftSearch", query = cQuery, limit = 100 })
  if r and r.ok then
    citems, ctotal, csel, cscroll = r.items, r.total, 1, 1
    cstatus = (#citems) .. " shown / " .. ctotal .. " match"
  else
    citems, ctotal = {}, 0
    cstatus = (r and r.err) or "No response from server"
  end
end

---------------------------------------------------------------------------
-- DRAW
---------------------------------------------------------------------------
local function drawTabBar(w)
  term.setCursorPos(1, 1)
  local function seg(label, active)
    term.setBackgroundColor(active and colors.blue or colors.black)
    term.setTextColor(active and colors.white or colors.lightGray)
    term.write(label)
  end
  seg(" Search ", uiTab == "search")
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.write(" ")
  seg(" Craft ", uiTab == "craft")
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
  local used = 8 + 1 + 7
  if w > used then term.write(string.rep(" ", w - used)) end
end

local function drawSearch(w, h)
  if mode == "amount" then
    local e = items[sel]
    term.setCursorPos(1, 2); term.setTextColor(colors.cyan); term.write((e.name):sub(1, w))
    term.setCursorPos(1, 3); term.setTextColor(colors.lightGray); term.write("Have: " .. e.count)
    term.setCursorPos(1, 5); term.setTextColor(colors.yellow); term.write("Amount: " .. amountStr)
    term.setCursorPos(1, 7); term.setTextColor(colors.lightGray); term.write("Enter=send  C=back")
    term.setCursorPos(9 + #amountStr, 5); term.setTextColor(colors.yellow); term.setCursorBlink(true)
    return
  end

  term.setCursorPos(1, 2); term.setTextColor(colors.yellow); term.write("Find: " .. query)
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray); term.write(status:sub(1, w))

  local top = 5
  local rows = h - top        -- leave the bottom row for the hint footer
  if sel < scroll then scroll = sel end
  if sel > scroll + rows - 1 then scroll = sel - rows + 1 end
  if scroll < 1 then scroll = 1 end
  for i = 0, rows - 1 do
    local e = items[scroll + i]; if not e then break end
    local y, isSel = top + i, (mode == "list" and scroll + i == sel)
    term.setCursorPos(1, y)
    term.setBackgroundColor(isSel and colors.gray or colors.black)
    term.setTextColor(isSel and colors.white or colors.lightGray)
    local ln = (("%5dx %s"):format(e.count, e.name)):sub(1, w)
    term.write(ln .. string.rep(" ", w - #ln))
  end
  term.setBackgroundColor(colors.black)

  term.setCursorPos(1, h); term.setTextColor(colors.gray)
  local hint = (mode == "list") and "Enter=get  Tab=deposit" or "Enter=find  Tab=deposit"
  term.write(hint:sub(1, w))

  if mode == "search" then
    term.setCursorPos(7 + #query, 2); term.setTextColor(colors.yellow); term.setCursorBlink(true)
  end
end

local function drawCraft(w, h)
  if cMode == "amount" then
    local e = citems[csel]
    term.setCursorPos(1, 2); term.setTextColor(colors.cyan); term.write((e.displayName):sub(1, w))
    term.setCursorPos(1, 3); term.setTextColor(colors.lightGray); term.write("Yield per batch: " .. e.yield)
    term.setCursorPos(1, 5); term.setTextColor(colors.yellow); term.write("Amount: " .. camountStr)
    term.setCursorPos(1, 7); term.setTextColor(colors.lightGray); term.write("Enter=continue  C=back")
    term.setCursorPos(9 + #camountStr, 5); term.setTextColor(colors.yellow); term.setCursorBlink(true)
    return
  elseif cMode == "confirm" then
    term.setCursorBlink(false)
    term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
    term.write(("Craft %d x %s"):format(cProduced, cSelected.displayName):sub(1, w))
    local y = 4
    for _, p in ipairs(cPlan) do
      term.setCursorPos(1, y)
      term.setTextColor(p.short > 0 and colors.red or colors.lightGray)
      local line = ("%-16s need %3d  have %3d"):format(p.label:sub(1, 16), p.needed, p.available)
      if p.short > 0 then
        line = line .. "  SHORT " .. p.short
        if p.craftable then line = line .. " *" end
      end
      term.write(line:sub(1, w))
      y = y + 1
    end
    term.setCursorPos(1, y + 1); term.setTextColor(colors.lightGray)
    if cShort then
      term.write((cHasSub and "* = craftable" or "Missing ingredients above."):sub(1, w))
      term.setCursorPos(1, y + 2)
      if cHasSub then
        term.write("S=store")
        term.setCursorPos(1, y + 3)
        term.write("O=output  C=back")
      else
        term.write("C=back")
      end
    else
      term.write("Enter=store")
      term.setCursorPos(1, y + 2)
      term.write("O=output  C=back")
    end
    return
  elseif cMode == "status" then
    term.setCursorBlink(false)
    term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
    term.write((cSelected and cSelected.displayName or ""):sub(1, w))
    term.setCursorPos(1, 3); term.setTextColor(colors.lightGray); term.write(cstatus:sub(1, w))
    term.setCursorPos(1, h); term.setTextColor(colors.gray); term.write("Enter/C = back to list")
    return
  end

  term.setCursorPos(1, 2); term.setTextColor(colors.yellow); term.write("Find: " .. cQuery)
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray); term.write(cstatus:sub(1, w))

  local top = 5
  local rows = h - top
  if csel < cscroll then cscroll = csel end
  if csel > cscroll + rows - 1 then cscroll = csel - rows + 1 end
  if cscroll < 1 then cscroll = 1 end
  for i = 0, rows - 1 do
    local e = citems[cscroll + i]; if not e then break end
    local y, isSel = top + i, (cMode == "list" and cscroll + i == csel)
    term.setCursorPos(1, y)
    term.setBackgroundColor(isSel and colors.gray or colors.black)
    term.setTextColor(isSel and colors.white or colors.lightGray)
    local ln = (("%5dx %s"):format(e.yield, e.displayName)):sub(1, w)
    term.write(ln .. string.rep(" ", w - #ln))
  end
  term.setBackgroundColor(colors.black)

  term.setCursorPos(1, h); term.setTextColor(colors.gray)
  local hint = (cMode == "list") and "Enter=select" or "Enter=find"
  term.write(hint:sub(1, w))

  if cMode == "search" then
    term.setCursorPos(7 + #cQuery, 2); term.setTextColor(colors.yellow); term.setCursorBlink(true)
  end
end

local function draw()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
  term.setCursorBlink(false)
  drawTabBar(w)

  if uiTab == "search" then drawSearch(w, h)
  else drawCraft(w, h) end
end

---------------------------------------------------------------------------
-- INPUT LOOP
---------------------------------------------------------------------------
draw()
while true do
  local ev = { os.pullEvent() }
  local e1 = ev[1]

  if e1 == "char" then
    local c = ev[2]
    if uiTab == "search" then
      if mode == "search" then query = query .. c
      elseif mode == "amount" then
        if c:match("%d") and #amountStr < 6 then amountStr = amountStr .. c end
      end
    else
      if cMode == "search" then cQuery = cQuery .. c
      elseif cMode == "amount" then
        if c:match("%d") and #camountStr < 6 then camountStr = camountStr .. c end
      end
    end
    draw()

  elseif e1 == "key" then
    local k = ev[2]
    if (k == keys.left or k == keys.right)
        and mode ~= "amount"
        and (cMode == "search" or cMode == "list") then
      uiTab = (uiTab == "search") and "craft" or "search"
      draw()

    elseif uiTab == "search" then
      if k == keys.tab and mode ~= "amount" then
        status = "Depositing..."; draw()
        local r = req({ cmd = "deposit" })
        if mode == "list" then fetch() end
        status = (r and r.ok) and ("Deposited " .. r.moved .. " items") or "Deposit failed"
      elseif mode == "search" then
        if k == keys.backspace then query = query:sub(1, -2)
        elseif k == keys.enter then fetch(); mode = "list" end
      elseif mode == "list" then
        if k == keys.up then sel = math.max(1, sel - 1)
        elseif k == keys.down then sel = math.min(#items, sel + 1)
        elseif k == keys.enter then
          if items[sel] then amountStr = tostring(math.min(64, items[sel].count)); mode = "amount" end
        elseif k == keys.backspace then mode = "search"
        end
      elseif mode == "amount" then
        if k == keys.backspace then amountStr = amountStr:sub(1, -2)
        elseif k == keys.c then mode = "list"
        elseif k == keys.enter then
          local e = items[sel]
          local n = math.min(tonumber(amountStr) or 0, e.count)
          local r = (n > 0) and req({ cmd = "withdraw", key = e.key, amount = n }) or nil
          mode = "list"
          fetch()
          if r and r.ok then status = ("Sent %d %s to barrel"):format(r.moved, e.name)
          else status = "Withdraw failed" end
        end
      end
      draw()

    else -- uiTab == "craft"
      if cMode == "search" then
        if k == keys.backspace then cQuery = cQuery:sub(1, -2)
        elseif k == keys.enter then cfetch(); cMode = "list" end
      elseif cMode == "list" then
        if k == keys.up then csel = math.max(1, csel - 1)
        elseif k == keys.down then csel = math.min(#citems, csel + 1)
        elseif k == keys.enter then
          if citems[csel] then cSelected = citems[csel]; camountStr = tostring(cSelected.yield); cMode = "amount" end
        elseif k == keys.backspace then cMode = "search"
        end
      elseif cMode == "amount" then
        if k == keys.backspace then camountStr = camountStr:sub(1, -2)
        elseif k == keys.c then cMode = "list"
        elseif k == keys.enter then
          local n = math.max(1, tonumber(camountStr) or cSelected.yield)
          local r = req({ cmd = "craftPlan", key = cSelected.key, amount = n })
          if r and r.ok then
            cPlan, cCycles, cShort, cProduced, cHasSub = r.plan, r.cycles, r.short, r.produced, r.hasSub
            cMode = "confirm"
          else
            cstatus = "Plan failed: " .. tostring((r and r.err) or "no response")
            cMode = "status"
          end
        end
      elseif cMode == "confirm" then
        if k == keys.c then cMode = "list"
        elseif k == keys.enter and not cShort then
          cstatus = "Crafting..."; draw()
          local r = req({ cmd = "craftRequest", key = cSelected.key, amount = cProduced }, 60)
          cstatus = craftStatusText(r, cProduced, cSelected.displayName, "stored")
          cMode = "status"
        elseif k == keys.o and not cShort then
          cstatus = "Crafting..."; draw()
          local r = req({ cmd = "craftRequest", key = cSelected.key, amount = cProduced, deliverToOutput = true }, 60)
          cstatus = craftStatusText(r, cProduced, cSelected.displayName, "sent to output")
          cMode = "status"
        elseif k == keys.s and cShort and cHasSub then
          cstatus = "Crafting missing ingredients..."; draw()
          local r = req({ cmd = "craftRequest", key = cSelected.key, amount = cProduced, auto = true }, 90)
          cstatus = craftStatusText(r, cProduced, cSelected.displayName, "stored")
          cMode = "status"
        elseif k == keys.o and cShort and cHasSub then
          cstatus = "Crafting missing ingredients..."; draw()
          local r = req({ cmd = "craftRequest", key = cSelected.key, amount = cProduced, auto = true, deliverToOutput = true }, 90)
          cstatus = craftStatusText(r, cProduced, cSelected.displayName, "sent to output")
          cMode = "status"
        end
      elseif cMode == "status" then
        if k == keys.enter or k == keys.c then cMode = "list" end
      end
      draw()
    end
  end
end
