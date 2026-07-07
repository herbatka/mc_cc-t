--[[  storage.lua  -----------------------------------------------------------
  Compact-storage system for CC: Tweaked (ATM10 / MC 1.21.1).

  INTERACTION  ->  keyboard, at the computer (right-click it):
      (Minecraft eats Escape and most F-keys before they reach a computer -
      Escape closes the screen, F2 takes a screenshot - so this UI never
      uses them. Left/Right switch tabs; [C] cancels instead of Escape.)

      Left/Right  ->  cycle between the Search / Craft / Teach tabs
      Search tab:  type to search  |  Up/Down to pick  |  Enter to withdraw
                   then type amount, Enter to confirm  ([C] cancels, Backspace edits)
      Craft tab:   type a name, Enter to search a recipe database (HTTP API)
                   plus anything you've taught locally  |  Up/Down to pick
                   |  Enter to select, then type amount, Enter shows the
                   ingredient list (what's needed + what's missing), Enter
                   again crafts it.
      Teach tab:   arrange the ingredients in the turtle's 3x3 crafting grid
                   yourself, then Enter - the turtle actually crafts it once
                   (for real) and the script remembers the arrangement +
                   real output for next time. Useful for anything not in the
                   recipe database (custom NBT variants, freshly added mods).

      The Craft/Teach tabs need a turtle (any kind) equipped with a Crafting
      Table, plus a staging barrel placed directly below it and wired into
      your storage network (see TURTLE_STAGING below). Without that, the
      tabs just say so and the Search tab keeps working as before. The
      Craft tab also needs the recipe database's HTTP API reachable (see
      API_BASE below and db/README.md) - if it isn't, locally-taught recipes
      still work, DB search just won't return anything.
      See README.md for full setup notes.

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
local RECIPE_FILE = "recipes.db"   -- where taught (custom) recipes are saved
-- A turtle can't join a wired network at all - the only way items move in
-- or out of one is turtle.suck()/turtle.drop(), run locally by the turtle
-- itself. So ingredients/output are staged through a barrel placed directly
-- BELOW the crafting turtle (turtle_craft.lua uses suckDown()/dropDown()).
local TURTLE_STAGING = "minecraft:barrel_3"
-- The recipe database's PostgREST API (see db/README.md). Must be reachable
-- from this computer - add it to CC:Tweaked's http.rules allowlist if it's
-- a loopback/private address (it blocks those by default).
local API_BASE = "http://127.0.0.1:3001"
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

-- Optional: a turtle equipped with a Crafting Table powers the Craft tab.
-- It's independent of AE2/ME systems entirely - it's just a real turtle
-- crafting real items using your existing sophisticatedstorage chests.
-- NOTE: the turtle is effectively its own separate computer - it doesn't
-- need to be anywhere near this one, isn't detected as a peripheral, and
-- can't join a wired network at all. All crafting, and moving items in/out
-- of the turtle, is done by turtle_craft.lua running ON the turtle, which
-- this computer talks to purely over rednet (see TURTLE_PROTO below) and
-- which stages items through TURTLE_STAGING using turtle.suck()/turtle.drop().
-- The only thing THIS computer needs directly is the staging barrel itself
-- (it has to be on the same storage network so pushItems/absorb can reach
-- it) - turtle reachability is checked live, per request, over rednet.
local TURTLE_PROTO, TURTLE_HOST = "cg_turtle", "craftbot"
local turtleOk = peripheral.isPresent(TURTLE_STAGING)

-- Open rednet on every modem present: a wireless one enables the pocket
-- remote, a wired one lets us reach the crafting turtle's helper program
-- over the same network as the storage chests. Both are optional.
local REMOTE_PROTO, REMOTE_HOST = "cg_storage", "mainstore"
local remoteOn = false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then
    rednet.open(name)
    if peripheral.call(name, "isWireless") then remoteOn = true end
  end
end
if remoteOn then rednet.host(REMOTE_PROTO, REMOTE_HOST) end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local index, filtered = {}, {}
local nameCache, freeSlots = {}, {}
local usedSlots, totalSlots = 0, 0
local query = ""

-- terminal (keyboard) UI state
local uiTab = "search"    -- "search" | "craft" | "teach"
local tMode, tSel, tScroll, tSelected, tAmount = "browse", 1, 1, nil, ""
local pollCount, barrelSeen, lastErr = 0, 0, nil   -- import heartbeat / diagnostics
local refreshBtn = nil        -- clickable area for the monitor REFRESH button

-- craft tab state
local cFiltered = {}
local cQuery = ""
local cMode, cSel, cScroll, cSelected, cAmount = "search", 1, 1, nil, ""
local cPlan, cCycles, cShort = {}, 1, false
local cStatusMsg = turtleOk and nil
  or ("No staging barrel found at " .. TURTLE_STAGING .. " (see README).")
local tchMsg = nil   -- last teach-attempt result, shown on the Teach tab

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

-- Plain vanilla ingredient items (planks, ingots, coal...) never carry NBT,
-- so looking them up is just keyOf with an empty NBT half.
local function findEntryByName(name)
  return findEntry(name .. "|")
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
-- RECIPE ENGINE (recipe database over HTTP + locally-taught recipes)
---------------------------------------------------------------------------
-- Turtle inventory is a 4x4 grid (slots 1-16). The vanilla crafting grid
-- uses the top-left 3x3: recipe positions 1-9 (row-major) map to these
-- actual turtle slots.
local GRID_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }

local function prettify(name)
  local short = name:gsub("^.-:", ""):gsub("_", " ")
  return (short:gsub("(%a)([%w']*)", function(f, r) return f:upper() .. r end))
end

local function labelFor(name)
  local e = findEntryByName(name)
  return e and e.displayName or prettify(name)
end

-- An ingredient is { names = {acceptable item ids}, count = n }; `single`
-- is the common case of exactly one acceptable item. Used both by taught
-- recipes' grids and by grids resolved from the database (see
-- apiResolveIngredients below).
local function ing(names, count) return { names = names, count = count or 1 } end
local function single(name, count) return ing({ name }, count) end

local customRecipes = {}

local function loadCustomRecipes()
  if not fs.exists(RECIPE_FILE) then return {} end
  local h = fs.open(RECIPE_FILE, "r")
  if not h then return {} end
  local data = h.readAll(); h.close()
  local ok, tbl = pcall(textutils.unserialize, data)
  return (ok and type(tbl) == "table") and tbl or {}
end

local function saveCustomRecipes()
  local h = fs.open(RECIPE_FILE, "w")
  if not h then return end
  h.write(textutils.serialize(customRecipes))
  h.close()
end

-- Minimal percent-encoding for building query strings - deliberately not
-- relying on textutils.urlEncode so this has no version-specific dependency.
local function urlEncode(s)
  return (s:gsub("[^%w%-%.%_%~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

-- Thin wrappers around CC:Tweaked's synchronous http.get/http.post (these
-- block until the request completes or fails - no manual event handling
-- needed) plus JSON en/decoding. Every caller gets (result, err) so a
-- database outage never crashes anything, it just fails that one lookup.
local function apiGet(path)
  local ok, handle, err = pcall(http.get, API_BASE .. path)
  if not ok then return nil, tostring(handle) end
  if not handle then return nil, err or "request failed" end
  local body = handle.readAll(); handle.close()
  local data = textutils.unserializeJSON(body)
  if data == nil then return nil, "bad response from API" end
  return data
end

local function apiPost(path, bodyTable)
  local ok, handle, err = pcall(http.post, API_BASE .. path, textutils.serializeJSON(bodyTable),
    { ["Content-Type"] = "application/json" })
  if not ok then return nil, tostring(handle) end
  if not handle then return nil, err or "request failed" end
  local body = handle.readAll(); handle.close()
  local data = textutils.unserializeJSON(body)
  if data == nil then return nil, "bad response from API" end
  return data
end

-- Searches the database for craftable recipes whose output item id contains
-- `query` (display names aren't in the data - see db/README.md).
local function apiSearchRecipes(query, limit)
  -- recipes_search (not the raw recipes table) so results are consistently
  -- ordered - a plain LIMIT with no ORDER BY isn't deterministic in
  -- Postgres, and with hundreds of matches for a common word, the same
  -- search could return a different arbitrary subset each time.
  local path = ("/recipes_search?output_item=ilike.%s&select=id,output_item,output_count"
    .. "&order=output_len.asc,output_item.asc&limit=%d")
    :format(urlEncode("*" .. query .. "*"), limit or 30)
  return apiGet(path)
end

-- Resolves a specific database recipe's ingredients into the same grid
-- shape as a taught recipe: grid[pos] = { names = {...}, count = n }.
-- Tag-based ingredients are already expanded into their full item list by
-- the recipe_ingredients_resolved() SQL function - this code never needs
-- to know whether a slot was an item or a tag.
local function apiResolveIngredients(recipeId)
  local data, err = apiPost("/rpc/recipe_ingredients_resolved", { p_recipe_id = recipeId })
  if not data then return nil, err end
  local grid = {}
  for _, row in ipairs(data) do
    grid[row.grid_pos] = { names = row.candidates, count = row.needed_count }
  end
  if next(grid) == nil then return nil, "recipe has no ingredients (bad data?)" end
  return grid
end

-- Fetches just enough of a database recipe to build a search-result entry,
-- given only its recipe id (used when the pocket remote hands back a
-- recipeKey and we need to reconstruct the entry server-side).
local function apiGetRecipeById(recipeId)
  local rows, err = apiGet(("/recipes?id=eq.%s&select=id,output_item,output_count"):format(urlEncode(recipeId)))
  if not rows or not rows[1] then return nil, err or "recipe not found" end
  return rows[1]
end

-- Every recipe entry (whether taught locally or found in the database) has
-- the same shape: { recipeKey, displayName, yield, output, grid, source }.
-- `grid` is nil for freshly-searched database entries until
-- resolveRecipeGrid() fetches + caches it (see below) - taught recipes
-- always have theirs already.
local function customRecipeEntry(r)
  return {
    recipeKey = "custom:" .. r.output,
    displayName = r.displayName or r.output,
    yield = r.yield,
    output = r.output,
    grid = r.grid,
    source = "custom",
  }
end

local function dbRecipeEntry(row)
  local ns = row.id:match("^([^:]+):") or "?"
  return {
    recipeKey = "db:" .. row.id,
    displayName = ("%s [%s]"):format(labelFor(row.output_item), ns),
    yield = row.output_count or 1,
    output = row.output_item,
    grid = nil,
    source = "db",
    dbId = row.id,
  }
end

-- Searches locally-taught recipes (instant) plus the database (one HTTP
-- request) and merges them into a single list. Returns (results, dbErr) -
-- dbErr is set (but results still returned) if the database was
-- unreachable, so local recipes keep working even if the API is down.
local function searchRecipes(query)
  local results, ql = {}, query:lower()
  for _, r in ipairs(customRecipes) do
    if r.output and (query == "" or (r.displayName or r.output):lower():find(ql, 1, true)) then
      results[#results + 1] = customRecipeEntry(r)
    end
  end

  local dbErr = nil
  if query ~= "" then
    local rows, err = apiSearchRecipes(query, 30)
    if rows then
      for _, row in ipairs(rows) do results[#results + 1] = dbRecipeEntry(row) end
    else
      dbErr = err
    end
  end

  table.sort(results, function(a, b) return a.displayName:lower() < b.displayName:lower() end)
  return results, dbErr
end

-- Reconstructs a recipe entry from a recipeKey alone (used by the pocket
-- remote, which only has the key round-tripped from an earlier search).
local function findByRecipeKey(key)
  local kind, ref = key:match("^(%a+):(.+)$")
  if kind == "custom" then
    for _, r in ipairs(customRecipes) do
      if r.output == ref then return customRecipeEntry(r) end
    end
    return nil, "recipe no longer exists"
  elseif kind == "db" then
    local row, err = apiGetRecipeById(ref)
    if not row then return nil, err end
    return dbRecipeEntry(row)
  end
  return nil, "bad recipe key"
end

-- Fills in entry.grid if it isn't already known (only database entries
-- need this - taught recipes always have theirs). Caches onto the entry
-- so re-using the same selection doesn't refetch.
local function resolveRecipeGrid(entry)
  if entry.grid then return entry.grid end
  if entry.source ~= "db" then return nil, "no grid data for this recipe" end
  local grid, err = apiResolveIngredients(entry.dbId)
  if not grid then return nil, err end
  entry.grid = grid
  return grid
end

-- Pick whichever acceptable item name has the most stock (handles "any
-- planks"-style ingredients, and resolved tags, without needing to know
-- which one specifically to prefer).
local function resolveIngredient(ingredient, cycles)
  local needed = ingredient.count * cycles
  local best, bestCount = ingredient.names[1], -1
  for _, nm in ipairs(ingredient.names) do
    local e = findEntryByName(nm)
    local count = e and e.count or 0
    if count > bestCount then best, bestCount = nm, count end
  end
  return { name = best, needed = needed, available = bestCount, short = math.max(0, needed - bestCount) }
end

local function planCraft(recipe, cycles)
  local plan, anyShort = {}, false
  for pos, ingredient in pairs(recipe.grid) do
    local r = resolveIngredient(ingredient, cycles)
    r.pos = pos
    plan[#plan + 1] = r
    if r.short > 0 then anyShort = true end
  end
  table.sort(plan, function(a, b) return a.pos < b.pos end)
  return plan, anyShort
end

-- Pushes `amount` of `name` from storage into the staging barrel (the
-- turtle sucks it from there itself - see below).
local function pushToBarrel(name, amount)
  local e = findEntryByName(name)
  if not e then return 0 end
  local remaining = amount
  for _, loc in ipairs(e.locations) do
    if remaining <= 0 then break end
    local moved = peripheral.wrap(loc.inv).pushItems(TURTLE_STAGING, loc.slot, remaining)
    remaining = remaining - moved
  end
  return amount - remaining
end

-- Only a program running ON the turtle can call turtle.craft(), read its
-- own inventory, or move items in/out of it - a peripheral-wrapped turtle
-- only exposes remote power control. turtle_craft.lua (running on the
-- turtle) does that work locally and answers these requests over rednet.
local function turtleRequest(msg, timeout)
  local addr = rednet.lookup(TURTLE_PROTO, TURTLE_HOST)
  if not addr then return nil, "turtle helper not found - is turtle_craft.lua running on it?" end
  rednet.send(addr, msg, TURTLE_PROTO)
  local _, reply = rednet.receive(TURTLE_PROTO, timeout or 5)
  if not reply then return nil, "no response from turtle" end
  return reply
end

local function turtleCraft(cycles)
  local reply, err = turtleRequest({ cmd = "craft", cycles = cycles })
  if not reply then return false, err end
  return reply.ok, reply.err
end

local function turtleSnapshot()
  local reply, err = turtleRequest({ cmd = "snapshot" })
  if not reply then return nil, err end
  if not reply.ok then return nil, reply.err or "snapshot failed" end
  return reply.slots
end

-- Tells the turtle to suckDown() `count` of whatever's currently staged in
-- the barrel into grid slot `slot`. Ingredients must be staged one distinct
-- item at a time (see runCraft) since suck() can't filter by item name.
local function turtleLoadSlot(slot, count)
  local reply, err = turtleRequest({ cmd = "loadSlot", slot = slot, count = count })
  if not reply then return false, err end
  return reply.ok, reply.err
end

-- Tells the turtle to dropDown() its entire inventory into the staging
-- barrel, so this computer can collect it from there.
local function turtleDump()
  turtleRequest({ cmd = "dump" })
end

-- Dumps the turtle's inventory into the staging barrel, sends anything
-- matching `outputName` on to OUTPUT (so crafted items land where
-- withdrawals do), and banks everything else (leftovers) into storage.
-- Pass nil to just bank everything (e.g. on failure, recovering ingredients).
local function collectFromTurtle(outputName)
  turtleDump()
  if outputName then
    local inv = peripheral.wrap(TURTLE_STAGING)
    for slot, item in pairs(inv.list()) do
      if item.name == outputName then inv.pushItems(OUTPUT, slot) end
    end
  end
  absorb(TURTLE_STAGING)
  buildIndex(); applyFilter()
end

-- Executes an already-validated plan: stages + loads ingredients one
-- distinct item at a time, crafts, then delivers the output to OUTPUT (or
-- banks leftovers back to storage, on failure) via the staging barrel.
local function runCraft(recipe, cycles, plan)
  local groups, order = {}, {}
  for _, p in ipairs(plan) do
    if not groups[p.name] then groups[p.name] = {}; order[#order + 1] = p.name end
    table.insert(groups[p.name], p)
  end

  for _, name in ipairs(order) do
    local entries = groups[name]
    local total = 0
    for _, p in ipairs(entries) do total = total + p.needed end
    pushToBarrel(name, total)
    buildIndex(); applyFilter()
    for _, p in ipairs(entries) do
      local ok, err = turtleLoadSlot(GRID_SLOTS[p.pos], p.needed)
      if not ok then
        collectFromTurtle(nil)
        return false, err or ("couldn't load " .. labelFor(name))
      end
    end
  end

  local craftOk, craftErr = turtleCraft(cycles)
  collectFromTurtle(craftOk and recipe.output or nil)

  return craftOk, craftErr
end

-- Learn a recipe by actually crafting whatever is currently arranged in the
-- turtle's grid. Diffs the turtle's inventory before/after to work out
-- exactly what was consumed (per grid slot) and what came out.
local function performTeach()
  local before, snapErr = turtleSnapshot()
  if not before then return false, snapErr end

  local craftOk, craftErr = turtleCraft(1)
  if not craftOk then return false, craftErr or "no matching recipe for that arrangement" end

  local after, snapErr2 = turtleSnapshot()
  if not after then return false, snapErr2 end

  local grid = {}
  for pos, slot in ipairs(GRID_SLOTS) do
    local b, a = before[slot], after[slot]
    if b then
      local sameItem = a and a.name == b.name
      local consumed = sameItem and (b.count - a.count) or b.count
      if consumed > 0 then grid[pos] = single(b.name, consumed) end
    end
  end

  local outputName, outputDisplay, outputYield
  for i = 1, 16 do
    local b, a = before[i], after[i]
    if a then
      if not b or b.name ~= a.name then
        outputName, outputDisplay, outputYield = a.name, a.displayName or a.name, a.count
        break
      elseif a.count > b.count then
        outputName, outputDisplay, outputYield = a.name, a.displayName or a.name, a.count - b.count
        break
      end
    end
  end

  if not outputName then
    collectFromTurtle(nil)
    return false, "crafted, but couldn't identify the output slot"
  end

  local recipe = { output = outputName, displayName = outputDisplay, yield = math.max(1, outputYield), grid = grid, custom = true }
  for i = #customRecipes, 1, -1 do
    if customRecipes[i].output == outputName then table.remove(customRecipes, i) end
  end
  customRecipes[#customRecipes + 1] = recipe
  saveCustomRecipes()

  collectFromTurtle(outputName)
  return true, ("Learned %s (yields %d). Sent to output."):format(outputDisplay, recipe.yield)
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
local function drawTabBar(tw)
  term.setCursorPos(1, 1)
  local function seg(label, active)
    term.setBackgroundColor(active and colors.blue or colors.black)
    term.setTextColor(active and colors.white or colors.lightGray)
    term.write(label)
  end
  seg(" Search ", uiTab == "search")
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.write(" ")
  seg(" Craft ", uiTab == "craft")
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.write(" ")
  seg(" Teach ", uiTab == "teach")
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
  local used = 8 + 1 + 7 + 1 + 7
  if tw > used then term.write(string.rep(" ", tw - used)) end
end

-- Minecraft eats Escape and most F-keys before they ever reach the
-- computer as key events (Escape closes the screen, F2 takes a
-- screenshot, etc.), so tabs cycle with Left/Right instead of a hotkey.
local UI_TAB_ORDER = { "search", "craft", "teach" }
local function nextTab(t, dir)
  local i = 1
  for idx, v in ipairs(UI_TAB_ORDER) do if v == t then i = idx end end
  i = i + dir
  if i < 1 then i = #UI_TAB_ORDER end
  if i > #UI_TAB_ORDER then i = 1 end
  return UI_TAB_ORDER[i]
end

local function drawSearchTab(tw, th)
  if tSel < 1 then tSel = 1 end
  if tSel > #filtered then tSel = math.max(1, #filtered) end
  term.setCursorPos(1, 2); term.setTextColor(colors.yellow)
  term.write("Search: " .. query)
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray)
  term.write(("%d matches  "):format(#filtered) .. "Up/Down + Enter = withdraw")
  term.setCursorPos(1, 4)
  if lastErr then
    term.setTextColor(colors.red); term.write(("ERR: " .. lastErr):sub(1, tw))
  else
    term.setTextColor(colors.gray)
    term.write(("poll #%d   in-barrel: %d"):format(pollCount, barrelSeen):sub(1, tw))
  end

  local top = 5
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
  term.setCursorPos(9 + #query, 2); term.setCursorBlink(true)
end

local function drawSearchAmount(tw)
  term.setCursorBlink(true)
  term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
  term.write("Withdraw: " .. tSelected.displayName)
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray)
  term.write(("Available: %d"):format(tSelected.count))
  term.setCursorPos(1, 5); term.setTextColor(colors.yellow)
  term.write("Amount: " .. tAmount)
  term.setCursorPos(1, 7); term.setTextColor(colors.lightGray)
  term.write("[Enter] confirm   [C] cancel   [Bksp] delete")
  term.setCursorPos(9 + #tAmount, 5); term.setTextColor(colors.yellow)
end

-- Handles both cMode "search" (typing a query) and "list" (browsing the
-- results of the last search) - a database lookup isn't free/instant like
-- the Search tab's local filtering, so unlike that tab, this one searches
-- on Enter rather than live as you type.
local function drawCraftBrowse(tw, th)
  if cSel < 1 then cSel = 1 end
  if cSel > #cFiltered then cSel = math.max(1, #cFiltered) end
  term.setCursorPos(1, 2); term.setTextColor(colors.yellow)
  term.write("Craft: " .. cQuery)
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray)
  term.write((cMode == "list" and "Enter=select  Bksp=edit search" or "Enter=search"):sub(1, tw))
  term.setCursorPos(1, 4); term.setTextColor(colors.gray)
  term.write((cStatusMsg or ("%d results"):format(#cFiltered)):sub(1, tw))

  local top = 5
  local rows = th - top + 1
  if cSel < cScroll then cScroll = cSel end
  if cSel > cScroll + rows - 1 then cScroll = cSel - rows + 1 end
  if cScroll < 1 then cScroll = 1 end
  for i = 0, rows - 1 do
    local e = cFiltered[cScroll + i]; if not e then break end
    local y, sel = top + i, (cMode == "list" and cScroll + i == cSel)
    term.setCursorPos(1, y)
    term.setBackgroundColor(sel and colors.gray or colors.black)
    term.setTextColor(sel and colors.white or colors.lightGray)
    local ln = ("%6dx %s"):format(e.yield, e.displayName):sub(1, tw)
    term.write(ln .. string.rep(" ", tw - #ln))
  end
  term.setBackgroundColor(colors.black); term.setTextColor(colors.yellow)
  if cMode == "search" then
    term.setCursorPos(8 + #cQuery, 2); term.setCursorBlink(true)
  else
    term.setCursorBlink(false)
  end
end

local function drawCraftAmount(tw)
  term.setCursorBlink(true)
  term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
  term.write("Craft: " .. cSelected.displayName)
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray)
  term.write(("Yield per batch: %d"):format(cSelected.yield))
  term.setCursorPos(1, 5); term.setTextColor(colors.yellow)
  term.write("Amount: " .. cAmount)
  term.setCursorPos(1, 7); term.setTextColor(colors.lightGray)
  term.write("[Enter] continue   [C] cancel   [Bksp] delete")
  term.setCursorPos(9 + #cAmount, 5); term.setTextColor(colors.yellow)
end

local function drawCraftConfirm(tw)
  term.setCursorBlink(false)
  term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
  term.write(("Craft %d x %s"):format(cCycles * cSelected.yield, cSelected.displayName):sub(1, tw))
  local y = 4
  for _, p in ipairs(cPlan) do
    term.setCursorPos(1, y)
    term.setTextColor(p.short > 0 and colors.red or colors.lightGray)
    local line = ("%-16s need %3d  have %3d"):format(labelFor(p.name):sub(1, 16), p.needed, p.available)
    if p.short > 0 then line = line .. "  SHORT " .. p.short end
    term.write(line:sub(1, tw))
    y = y + 1
  end
  term.setCursorPos(1, y + 1); term.setTextColor(colors.lightGray)
  if cShort then
    term.write("Missing ingredients above.  [C] cancel")
  else
    term.write("[Enter] craft it   [C] cancel")
  end
end

local function drawCraftStatus(tw)
  term.setCursorBlink(false)
  term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
  term.write((cSelected and cSelected.displayName or "Teach"):sub(1, tw))
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray)
  term.write((cStatusMsg or ""):sub(1, tw))
  term.setCursorPos(1, 5); term.setTextColor(colors.gray)
  term.write("[Enter] back to list")
end

local function drawTeachTab(tw)
  term.setCursorBlink(false)
  term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
  term.write("Teach a new recipe")
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray)
  term.write("Arrange ingredients in the turtle's grid")
  term.setCursorPos(1, 4); term.write("(top-left 3x3: slots 1-3, 5-7, 9-11)")
  term.setCursorPos(1, 6); term.setTextColor(colors.yellow)
  term.write("[Enter] capture + craft")
  term.setCursorPos(1, 8); term.setTextColor(colors.lightGray)
  term.write((tchMsg or ""):sub(1, tw))
end

local function drawTerminal()
  local tw, th = term.getSize()
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white); term.clear()
  drawTabBar(tw)

  if uiTab == "search" then
    if tMode == "browse" then drawSearchTab(tw, th)
    elseif tMode == "amount" then drawSearchAmount(tw) end
  elseif uiTab == "craft" then
    if not turtleOk then
      term.setCursorPos(1, 3); term.setTextColor(colors.red)
      term.write((cStatusMsg or "Craft tab unavailable."):sub(1, tw))
      term.setCursorPos(1, 4); term.write("See README.md.")
    elseif cMode == "search" or cMode == "list" then drawCraftBrowse(tw, th)
    elseif cMode == "amount" then drawCraftAmount(tw)
    elseif cMode == "confirm" then drawCraftConfirm(tw)
    elseif cMode == "status" then drawCraftStatus(tw)
    end
  elseif uiTab == "teach" then
    if not turtleOk then
      term.setCursorPos(1, 3); term.setTextColor(colors.red)
      term.write((cStatusMsg or "Teach tab unavailable."):sub(1, tw))
      term.setCursorPos(1, 4); term.write("See README.md.")
    else
      drawTeachTab(tw)
    end
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

  elseif msg.cmd == "craftSearch" then
    if not turtleOk then rednet.send(sender, { ok = false, err = "no staging barrel" }, REMOTE_PROTO); return end
    local results, err = searchRecipes(msg.query or "")
    local out = {}
    for i = 1, math.min(#results, msg.limit or 60) do
      local r = results[i]
      out[i] = { key = r.recipeKey, displayName = r.displayName, yield = r.yield }
    end
    rednet.send(sender, { ok = true, items = out, total = #results, err = err }, REMOTE_PROTO)

  elseif msg.cmd == "craftPlan" then
    if not turtleOk then rednet.send(sender, { ok = false, err = "no staging barrel" }, REMOTE_PROTO); return end
    local recipe, rerr = findByRecipeKey(msg.key or "")
    if not recipe then rednet.send(sender, { ok = false, err = rerr or "unknown recipe" }, REMOTE_PROTO); return end
    local grid, gerr = resolveRecipeGrid(recipe)
    if not grid then rednet.send(sender, { ok = false, err = gerr }, REMOTE_PROTO); return end
    local n = math.max(1, tonumber(msg.amount) or recipe.yield)
    local cycles = math.max(1, math.min(64, math.ceil(n / recipe.yield)))
    local plan, short = planCraft(recipe, cycles)
    local out = {}
    for _, p in ipairs(plan) do
      out[#out + 1] = { label = labelFor(p.name), needed = p.needed, available = p.available, short = p.short }
    end
    rednet.send(sender, { ok = true, cycles = cycles, produced = cycles * recipe.yield, plan = out, short = short }, REMOTE_PROTO)

  elseif msg.cmd == "craftRequest" then
    if not turtleOk then rednet.send(sender, { ok = false, err = "no staging barrel" }, REMOTE_PROTO); return end
    local recipe, rerr = findByRecipeKey(msg.key or "")
    if not recipe then rednet.send(sender, { ok = false, err = rerr or "unknown recipe" }, REMOTE_PROTO); return end
    local grid, gerr = resolveRecipeGrid(recipe)
    if not grid then rednet.send(sender, { ok = false, err = gerr }, REMOTE_PROTO); return end
    local n = math.max(1, tonumber(msg.amount) or recipe.yield)
    local cycles = math.max(1, math.min(64, math.ceil(n / recipe.yield)))
    local plan, short = planCraft(recipe, cycles)
    if short then rednet.send(sender, { ok = false, err = "missing ingredients" }, REMOTE_PROTO); return end
    local success, err = runCraft(recipe, cycles, plan)
    rednet.send(sender, { ok = success, err = err, produced = cycles * recipe.yield }, REMOTE_PROTO)
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
customRecipes = loadCustomRecipes()
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
    if uiTab == "search" then
      if tMode == "browse" then
        query = query .. c; applyFilter(); tSel = 1; tScroll = 1
      elseif tMode == "amount" then
        if c:match("%d") and #tAmount < 6 then tAmount = tAmount .. c end
      end
    elseif uiTab == "craft" and turtleOk then
      if cMode == "search" then
        cQuery = cQuery .. c
      elseif cMode == "amount" then
        if c:match("%d") and #cAmount < 6 then cAmount = cAmount .. c end
      end
    end
    drawTerminal()

  elseif e1 == "key" then
    -- Wrapped in pcall so a bad withdraw/craft (stale location data, a
    -- peripheral hiccup, etc.) can't crash the whole program and silently
    -- kill the import-timer loop along with it - it shows as an error on
    -- the Search tab instead, and everything else keeps running.
    local keyOk, keyErr = pcall(function()
    local code = ev[2]
    if code == keys.left or code == keys.right then
      local canSwitch = (uiTab == "search" and tMode == "browse")
        or (uiTab == "craft" and (cMode == "search" or cMode == "list"))
        or (uiTab == "teach")
      if canSwitch then
        uiTab = nextTab(uiTab, code == keys.right and 1 or -1)
        drawTerminal()
      end

    elseif uiTab == "search" then
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
        elseif code == keys.c then tMode = "browse"; drawTerminal()
        elseif code == keys.enter then
          -- Re-fetch by key: the auto-import timer may have rebuilt the
          -- index (and moved items around) since this entry was selected.
          local fresh = findEntry(tSelected.key) or tSelected
          local n = math.min(tonumber(tAmount) or 0, fresh.count)
          if n > 0 then withdraw(fresh, n) end
          tMode = "browse"
          buildIndex(); applyFilter()
          drawTerminal(); drawStats()        -- refresh both after a withdraw
        end
      end

    elseif uiTab == "craft" and turtleOk then
      if cMode == "search" then
        if code == keys.backspace then cQuery = cQuery:sub(1, -2)
        elseif code == keys.enter then
          local results, err = searchRecipes(cQuery)
          cFiltered = results
          cStatusMsg = err and ("DB search: " .. tostring(err)) or nil
          cSel, cScroll = 1, 1
          cMode = "list"
        end
        drawTerminal()
      elseif cMode == "list" then
        if code == keys.up then cSel = math.max(1, cSel - 1)
        elseif code == keys.down then cSel = math.min(#cFiltered, cSel + 1)
        elseif code == keys.backspace then cMode = "search"; cStatusMsg = nil
        elseif code == keys.enter then
          local sel = cFiltered[cSel]
          if sel then
            local grid, gerr = resolveRecipeGrid(sel)
            if grid then
              cSelected = sel; cAmount = tostring(sel.yield); cMode = "amount"
            else
              cStatusMsg = "Couldn't load recipe: " .. tostring(gerr)
            end
          end
        end
        drawTerminal()
      elseif cMode == "amount" then
        if code == keys.backspace then cAmount = cAmount:sub(1, -2); drawTerminal()
        elseif code == keys.c then cMode = "list"; drawTerminal()
        elseif code == keys.enter then
          local n = math.max(1, tonumber(cAmount) or cSelected.yield)
          cCycles = math.max(1, math.min(64, math.ceil(n / cSelected.yield)))
          cPlan, cShort = planCraft(cSelected, cCycles)
          cMode = "confirm"
          drawTerminal()
        end
      elseif cMode == "confirm" then
        if code == keys.c then cMode = "list"; drawTerminal()
        elseif code == keys.enter and not cShort then
          local success, err = runCraft(cSelected, cCycles, cPlan)
          cStatusMsg = success
            and ("Crafted %d x %s"):format(cCycles * cSelected.yield, cSelected.displayName)
            or ("Craft failed: " .. tostring(err or "unknown error"))
          cMode = "status"
          drawTerminal()
        end
      elseif cMode == "status" then
        if code == keys.enter or code == keys.c then
          cStatusMsg = nil; cMode = "list"; drawTerminal()
        end
      end

    elseif uiTab == "teach" and turtleOk then
      if code == keys.enter then
        local ok, msg = performTeach()
        tchMsg = msg
        drawTerminal()
      end
    end
    end)
    if not keyOk then lastErr = tostring(keyErr); drawTerminal() end

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
