--[[  remote.lua  ------------------------------------------------------------
  Pocket-computer remote for the storage system (CC: Tweaked).

  Runs on an Advanced Pocket Computer crafted with a Wireless or Ender Modem.
  Lets you search your storage and queue withdrawals from anywhere.

  NOTE: items can't teleport to you. A withdrawal is pushed into the OUTPUT
  barrel back at the storage computer, ready to collect when you get home.

  CONTROLS
    Search box:  type a name, Enter to search, Backspace to edit.
    Results:     Up/Down to pick, Enter to withdraw, Backspace to edit search.
    Amount:      type a number, Enter to send, Esc to cancel.

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

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local mode      = "search"   -- "search" | "list" | "amount"
local query     = ""
local items     = {}
local total     = 0
local sel, scroll = 1, 1
local amountStr = ""
local status    = "Type a name, Enter to search"

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

---------------------------------------------------------------------------
-- DRAW
---------------------------------------------------------------------------
local function draw()
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
  term.setCursorBlink(false)

  if mode == "amount" then
    local e = items[sel]
    term.setCursorPos(1, 1); term.setTextColor(colors.cyan); term.write((e.name):sub(1, w))
    term.setCursorPos(1, 2); term.setTextColor(colors.lightGray); term.write("Have: " .. e.count)
    term.setCursorPos(1, 4); term.setTextColor(colors.yellow); term.write("Amount: " .. amountStr)
    term.setCursorPos(1, 6); term.setTextColor(colors.lightGray); term.write("Enter=send  Esc=back")
    term.setCursorPos(9 + #amountStr, 4); term.setCursorBlink(true)
    return
  end

  term.setCursorPos(1, 1); term.setTextColor(colors.yellow); term.write("Find: " .. query)
  term.setCursorPos(1, 2); term.setTextColor(colors.lightGray); term.write(status:sub(1, w))

  local top = 4
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

  -- hint footer
  term.setCursorPos(1, h); term.setTextColor(colors.gray)
  local hint = (mode == "list") and "Enter=get  Tab=deposit" or "Enter=find  Tab=deposit"
  term.write(hint:sub(1, w))

  if mode == "search" then
    term.setCursorPos(7 + #query, 1); term.setTextColor(colors.yellow); term.setCursorBlink(true)
  end
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
    if mode == "search" then query = query .. c
    elseif mode == "amount" then
      if c:match("%d") and #amountStr < 6 then amountStr = amountStr .. c end
    end
    draw()

  elseif e1 == "key" then
    local k = ev[2]
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
      elseif k == keys.escape then mode = "list"
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
  end
end
