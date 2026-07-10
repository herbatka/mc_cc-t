--[[  storage.lua  -----------------------------------------------------------
  Compact-storage system for CC: Tweaked (ATM10 / MC 1.21.1).

  INTERACTION  ->  keyboard, at the computer (right-click it):
      (Minecraft eats Escape and most F-keys before they reach a computer -
      Escape closes the screen, F2 takes a screenshot - so this UI never
      uses them. Left/Right switch tabs; [C] cancels instead of Escape.)

      Left/Right  ->  cycle between the Search / Craft tabs
      Search tab:  type to search  |  Up/Down to pick  |  Enter to withdraw
                   then type amount, Enter to confirm  ([C] cancels, Backspace edits)
      Craft tab:   type a name, Enter to search the recipe database (HTTP
                   API)  |  Up/Down to pick  |  Enter to select, then type
                   amount, Enter shows the ingredient list (what's needed +
                   what's missing), Enter again crafts it.

      The Craft tab needs a turtle (any kind) equipped with a Crafting
      Table, plus a staging barrel placed directly below it and wired into
      your storage network (see TURTLE_STAGING below), AND the recipe
      database's HTTP API reachable (see API_BASE below and db/README.md).
      Without the turtle/barrel, the tab just says so and the Search tab
      keeps working as before. Without the database, search just returns
      nothing (with a clear error) instead of hanging or crashing.
      See README.md for full setup notes.

  MONITOR  ->  passive stats dashboard, auto-refreshes every 15s:
      total items, item types, slots used, and the top items in storage.
      Full resync every 10 min, or tap the REFRESH button any time.

  Importing from the INPUT barrel and periodically compacting/consolidating
  storage is handled entirely by a separate computer (manager.lua) - this
  computer never touches INPUT itself, and just refreshes its view of
  storage when the manager computer says something changed (see
  MANAGER_PROTO below). See README.md for manager.lua setup.
  Save as "startup.lua" so it auto-runs. Config is baked in below.
--------------------------------------------------------------------------- ]]

-------------------------- CONFIG -------------------------------------------
local OUTPUT = "enderstorage:ender_chest_0"
-- Where POCKET-COMPUTER withdrawals go. Set this to an EnderStorage ender
-- chest so items land in your matching Ender Pouch anywhere. Leave nil to
-- just use OUTPUT. Find its name with the peripheral-listing trick; it's
-- likely something like "enderstorage:ender_chest_0".
local REMOTE_OUTPUT = nil
local STATS_INTERVAL  = 600   -- seconds: full resync + repaint (600 = 10 min)
-- A turtle can't join a wired network at all - the only way items move in
-- or out of one is turtle.suck()/turtle.drop(), run locally by the turtle
-- itself. So ingredients/output are staged through a barrel placed directly
-- BELOW the crafting turtle (turtle_craft.lua uses suckDown()/dropDown()).
local TURTLE_STAGING = "minecraft:barrel_3"
-- The recipe database's PostgREST API (see db/README.md). Must be reachable
-- from this computer - add it to CC:Tweaked's http.rules allowlist if it's
-- a loopback/private address (it blocks those by default).
local API_BASE = "http://127.0.0.1:3001"
-- peripheral.find("monitor") just grabs whichever monitor it happens to see
-- FIRST - fine with only one monitor on the whole network, but the storage
-- manager computer (manager.lua) has its own monitor too, on the SAME wired
-- network, so this computer could easily end up displaying on THAT one
-- instead of its own. Set this to this computer's own monitor's exact
-- peripheral name (check with the `peripheral.getNames()` trick - e.g.
-- "monitor_0") if that happens; leave nil to keep auto-finding.
local MONITOR_NAME = "left"
----------------------------------------------------------------------------

local monitor
if MONITOR_NAME then
  monitor = peripheral.wrap(MONITOR_NAME)
  if not monitor then
    error(("No monitor found named '%s' - check the exact name with peripheral.getNames() (side names like \"left\"/\"right\" only work for a monitor placed directly against this computer with no wired modem in between, and a multi-block Advanced Monitor only responds as a peripheral from its single origin block, not just anywhere the monitor visually covers)."):format(MONITOR_NAME), 0)
  end
else
  monitor = peripheral.find("monitor")
  if not monitor then error("No monitor found. Attach an Advanced Monitor.", 0) end
end
monitor.setTextScale(0.5)

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
-- and the storage manager computer over the same network as the storage
-- chests. All are optional independently of each other.
local REMOTE_PROTO, REMOTE_HOST = "cg_storage", "mainstore"
local MANAGER_PROTO, MANAGER_HOST = "cg_manager", "mainstore"
local remoteOn, anyModemOn = false, false
for _, name in ipairs(peripheral.getNames()) do
  if peripheral.getType(name) == "modem" then
    rednet.open(name)
    anyModemOn = true
    if peripheral.call(name, "isWireless") then remoteOn = true end
  end
end
if remoteOn then rednet.host(REMOTE_PROTO, REMOTE_HOST) end
-- manager.lua reaches this over whichever modem it shares a network with
-- (almost always the wired one, alongside the storage chests) - host this
-- regardless of wireless, unlike REMOTE_PROTO above.
if anyModemOn then rednet.host(MANAGER_PROTO, MANAGER_HOST) end

---------------------------------------------------------------------------
-- STATE
---------------------------------------------------------------------------
local index, filtered = {}, {}
local indexByKey = {}   -- same entries as `index`, keyed by e.key for O(1) lookup
local nameCache, tagCache, freeSlots = {}, {}, {}
local usedSlots, totalSlots = 0, 0
local query = ""

-- terminal (keyboard) UI state
local uiTab = "search"    -- "search" | "craft"
local tMode, tSel, tScroll, tSelected, tAmount = "browse", 1, 1, nil, ""
local lastErr = nil
local managerLastSeen = nil   -- os.epoch("utc") of the last heartbeat/storageChanged from manager.lua
local refreshBtn = nil        -- clickable area for the monitor REFRESH button

-- craft tab state
local cFiltered = {}
local cQuery = ""
local cMode, cSel, cScroll, cSelected, cAmount = "search", 1, 1, nil, ""
local cSummary, cCycles, cShort, cHasSub = {}, 1, false, false
local cProgPhase, cProgDone, cProgTotal = "", 0, 0   -- live crafting progress
local cStatusMsg = turtleOk and nil
  or ("No staging barrel found at " .. TURTLE_STAGING .. " (see README).")

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
          -- detailed=true is what surfaces `tags` (used for tag-based Search
          -- matching below) alongside displayName - both are static
          -- properties of the item type, so caching them forever per key is
          -- safe and keeps this expensive detailed call to once per distinct
          -- item type ever seen, not once per stack/slot.
          local d = inv.getItemDetail(slot, true)
          nameCache[k] = (d and d.displayName) or item.name
          tagCache[k] = d and d.tags
        end
        e = { key = k, displayName = nameCache[k], tags = tagCache[k], count = 0, locations = {} }
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
  -- `agg` is already keyed exactly the way findEntry needs - reuse it
  -- directly instead of building a second copy or scanning `index` (matters
  -- a lot now: a single tag-based ingredient can resolve to hundreds of
  -- candidate items, each needing a lookup here).
  indexByKey = agg
end

local function findEntry(key)
  return indexByKey[key]
end

-- Plain vanilla ingredient items (planks, ingots, coal...) never carry NBT,
-- so looking them up is just keyOf with an empty NBT half.
local function findEntryByName(name)
  return findEntry(name .. "|")
end

-- Matches on item name/displayName (as before) OR on tag membership, using
-- `e.tags` from the game itself (getItemDetail's detailed=true, cached in
-- buildIndex) rather than the recipe database - so e.g. typing "food"
-- surfaces both items literally named "food" and any stored item carrying
-- a tag like "c:foods", entirely locally: no network call, and always
-- exactly matches live game data instead of depending on a KubeJS dump
-- being complete or re-imported after a modpack change.
local function filterBy(q)
  if q == "" then return index end
  local out, ql = {}, q:lower()
  for _, e in ipairs(index) do
    local matches = e.displayName:lower():find(ql, 1, true)
    if not matches and e.tags then
      for tagId in pairs(e.tags) do
        if tagId:lower():find(ql, 1, true) then matches = true; break end
      end
    end
    if matches then out[#out + 1] = e end
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

local function withdraw(entry, amount, dest)
  dest = dest or OUTPUT
  local got = 0
  for _, loc in ipairs(entry.locations) do
    if got >= amount then break end
    local inv = peripheral.wrap(loc.inv)
    -- The manager computer (manager.lua) moves items between chests on its
    -- own to compact/consolidate storage, so a cached location can go stale
    -- between the last buildIndex() and here. Verify the slot still
    -- actually holds what we expect before taking from it, instead of
    -- trusting the snapshot and risking pushing whatever item is there now.
    local d = inv.getItemDetail(loc.slot)
    if d and keyOf(d) == entry.key then
      got = got + inv.pushItems(dest, loc.slot, amount - got)
    end
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
  --
  -- Matching is against output_item, the raw item id (e.g.
  -- "minecraft:iron_ingot"), which never has spaces - only the prettified
  -- displayName does ("Iron Ingot"). Typing what you see would otherwise
  -- never match anything, so any run of whitespace in the query becomes a
  -- wildcard gap instead of a literal space, matching across underscores
  -- (or any other separator) the same way the display name visually does.
  local pattern = "*" .. query:gsub("%s+", "*") .. "*"
  local path = ("/recipes_search?output_item=ilike.%s&select=id,output_item,output_count"
    .. "&order=output_len.asc,output_item.asc&limit=%d")
    :format(urlEncode(pattern), limit or 30)
  return apiGet(path)
end

-- Given a concrete item id, finds the best craftable recipe that produces
-- it exactly (if any) - used to offer "craft the missing ingredient too"
-- when a craft comes up short. This is a lookup, not user-facing search,
-- so it's an exact match rather than ilike.
local function apiFindRecipeForItem(itemName)
  local path = ("/recipes_search?output_item=eq.%s&select=id,output_item,output_count"
    .. "&order=output_len.asc,output_item.asc&limit=1"):format(urlEncode(itemName))
  local rows, err = apiGet(path)
  if not rows or #rows == 0 then return nil end
  return rows[1]
end

-- Fetches the concrete item membership of one or more tags in a single
-- request, returned as { [tag] = {item, item, ...} }. Batched so a recipe
-- referencing the same tag from several grid positions (e.g. a chest's 8
-- plank slots) only pays for that tag's membership list once.
local function apiFetchTagItems(tags)
  if #tags == 0 then return {} end
  local encoded = {}
  for i, t in ipairs(tags) do encoded[i] = urlEncode(t) end
  local path = ("/tags?tag=in.(%s)&select=tag,item"):format(table.concat(encoded, ","))
  local rows, err = apiGet(path)
  if not rows then return nil, err end
  local byTag = {}
  for _, row in ipairs(rows) do
    if not byTag[row.tag] then byTag[row.tag] = {} end
    byTag[row.tag][#byTag[row.tag] + 1] = row.item
  end
  return byTag
end

-- Resolves a specific database recipe's ingredients into the same grid
-- shape as a taught recipe: grid[pos] = { names = {...}, count = n }.
-- recipe_ingredients_raw() returns each slot's raw item/tag reference
-- rather than pre-expanding tags itself - expanding a tag inline for every
-- grid position that uses it repeats its entire membership list once per
-- position (a chest's 8 plank slots would otherwise resend the ~700-item
-- "any planks" list 8 times for one recipe). Fetching each distinct tag
-- exactly once here and reusing it keeps that cost fixed regardless of how
-- many positions share the same tag.
local function apiResolveIngredients(recipeId)
  local rows, err = apiPost("/rpc/recipe_ingredients_raw", { p_recipe_id = recipeId })
  if not rows then return nil, err end
  if #rows == 0 then return nil, "recipe has no ingredients (bad data?)" end

  local neededTags, seen = {}, {}
  for _, row in ipairs(rows) do
    if row.kind == "tag" and not seen[row.ref] then
      seen[row.ref] = true
      neededTags[#neededTags + 1] = row.ref
    end
  end
  local tagItems = {}
  if #neededTags > 0 then
    local byTag, tagErr = apiFetchTagItems(neededTags)
    if not byTag then return nil, tagErr end
    tagItems = byTag
  end

  local grid = {}
  for _, row in ipairs(rows) do
    if not grid[row.grid_pos] then grid[row.grid_pos] = { names = {}, count = row.needed_count } end
    local names = grid[row.grid_pos].names
    if row.kind == "item" then
      names[#names + 1] = row.ref
    else
      local items = tagItems[row.ref]
      if items then
        for _, it in ipairs(items) do names[#names + 1] = it end
      end
    end
  end
  -- A tag with zero known members would otherwise leave that slot with no
  -- candidates at all (crashing resolveIngredient, which expects at least
  -- one) - fall back to the raw ref so it just shows up as unavailable.
  for _, entry in pairs(grid) do
    if #entry.names == 0 then entry.names[1] = "?unresolvable" end
  end
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

-- Every recipe entry has the same shape: { recipeKey, displayName, yield,
-- output, grid }. recipeKey is just the database recipe id; `grid` is nil
-- until resolveRecipeGrid() fetches + caches it (see below) - not fetched
-- up front since a search can return many results and we only need the
-- grid for whichever one gets selected.
local function makeRecipeEntry(row)
  local ns = row.id:match("^([^:]+):") or "?"
  return {
    recipeKey = row.id,
    displayName = ("%s [%s]"):format(labelFor(row.output_item), ns),
    yield = row.output_count or 1,
    output = row.output_item,
    grid = nil,
  }
end

-- Searches the recipe database. Returns (results, err) - on failure,
-- results is an empty list and err explains why (e.g. database unreachable).
local function searchRecipes(query)
  if query == "" then return {} end
  local rows, err = apiSearchRecipes(query, 30)
  if not rows then return {}, err end
  local results = {}
  for _, row in ipairs(rows) do results[#results + 1] = makeRecipeEntry(row) end
  return results
end

-- Reconstructs a recipe entry from a recipeKey alone (used by the pocket
-- remote, which only has the key round-tripped from an earlier search).
local function findByRecipeKey(key)
  local row, err = apiGetRecipeById(key)
  if not row then return nil, err end
  return makeRecipeEntry(row)
end

-- Fills in entry.grid if it isn't already known. Caches onto the entry so
-- re-using the same selection doesn't refetch.
local function resolveRecipeGrid(entry)
  if entry.grid then return entry.grid end
  local grid, err = apiResolveIngredients(entry.recipeKey)
  if not grid then return nil, err end
  entry.grid = grid
  return grid
end

-- The turtle's own inventory is a plain vanilla 16-slot inventory (~64 max
-- stack per slot) - completely unrelated to any sophisticatedstorage stack
-- upgrades on the storage side - and a grid position always maps to the
-- SAME physical turtle slot. So a single BATCH of `cycles` crafts needs
-- ingredient.count * cycles to fit in ONE slot for every ingredient, or
-- turtle.suckDown() silently stops at whatever the slot can actually hold
-- and reports success anyway (it only tells you SOMETHING moved, not how
-- much). This is the safe per-BATCH cap runCraftBatched() uses to split a
-- bigger request into multiple turtle.craft() calls - it does NOT limit
-- how much the player can ask for overall, only how much fits in one
-- physical batch. turtle_craft.lua's loadSlot handler also verifies the
-- actual count moved as a second line of defense, in case an ingredient's
-- real max stack is smaller than the 64 assumed here (tools, potions, etc).
local function maxCyclesForGrid(grid)
  local maxPerCycle = 1
  for _, ingredient in pairs(grid) do
    if ingredient.count > maxPerCycle then maxPerCycle = ingredient.count end
  end
  return math.max(1, math.floor(64 / maxPerCycle))
end

-- Pick whichever acceptable item name has the most stock (handles "any
-- planks"-style ingredients, and resolved tags, without needing to know
-- which one specifically to prefer).
local function pickBest(ingredient)
  local best, bestCount = ingredient.names[1], -1
  for _, nm in ipairs(ingredient.names) do
    local e = findEntryByName(nm)
    local count = e and e.count or 0
    if count > bestCount then best, bestCount = nm, count end
  end
  return best
end

-- Resolves a recipe into two views:
--   positions - one row per grid slot (pos, name, needed), in position
--     order - what runCraft actually loads into each turtle slot.
--   summary   - one row per distinct concrete item, with the TOTAL needed
--     across every position that uses it vs. real storage stock. Checking
--     stock per-position instead of per-total was a real bug: a recipe
--     needing e.g. 5 grid slots of Reinforced Brick but only 1 in stock
--     would show each slot individually as "need 1, have 1" (looks fine)
--     and never flag the craft as short overall.
local function planCraft(recipe, cycles)
  local positions = {}
  for pos, ingredient in pairs(recipe.grid) do
    positions[#positions + 1] = { pos = pos, name = pickBest(ingredient), needed = ingredient.count * cycles }
  end
  table.sort(positions, function(a, b) return a.pos < b.pos end)

  local totals, order = {}, {}
  for _, p in ipairs(positions) do
    if not totals[p.name] then
      local e = findEntryByName(p.name)
      totals[p.name] = { name = p.name, needed = 0, available = e and e.count or 0 }
      order[#order + 1] = p.name
    end
    totals[p.name].needed = totals[p.name].needed + p.needed
  end

  local summary, anyShort = {}, false
  for _, name in ipairs(order) do
    local t = totals[name]
    t.short = math.max(0, t.needed - t.available)
    if t.short > 0 then anyShort = true end
    summary[#summary + 1] = t
  end

  return positions, summary, anyShort
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
-- keepInStorage: bank the crafted output into general storage instead of
-- routing it to OUTPUT. Used for the one-level auto-craft-missing-ingredient
-- flow below, where the "output" is really just an intermediate ingredient
-- for the craft the player actually asked for.
-- onProgress(phase), if given, is called with a short human-readable phase
-- string ("Moving Gold Nugget...", "Crafting...", "Collecting...") right
-- before each step - purely cosmetic, for a live progress display.
local function runCraft(recipe, cycles, plan, keepInStorage, onProgress)
  local groups, order = {}, {}
  for _, p in ipairs(plan) do
    if not groups[p.name] then groups[p.name] = {}; order[#order + 1] = p.name end
    table.insert(groups[p.name], p)
  end

  for _, name in ipairs(order) do
    local entries = groups[name]
    local total = 0
    for _, p in ipairs(entries) do total = total + p.needed end
    if onProgress then onProgress("Moving " .. labelFor(name) .. "...") end
    local staged = pushToBarrel(name, total)
    if staged < total then
      -- Silently pressing on here used to mean whichever grid slot got
      -- served last (of possibly several sharing this same ingredient,
      -- e.g. a tag-based ingredient occupying multiple grid positions)
      -- came up short with a confusing "slot maxed out or barrel short"
      -- error, even though the REAL problem was staging never having
      -- enough to begin with (not enough real stock despite the earlier
      -- plan check, or the staging barrel itself out of room) - failing
      -- here instead gives a clear, accurate reason immediately.
      collectFromTurtle(nil)
      return false, ("only staged %d of %d %s in the barrel - not enough stock, or the staging barrel has no room")
        :format(staged, total, labelFor(name))
    end
    buildIndex(); applyFilter()
    for _, p in ipairs(entries) do
      local ok, err = turtleLoadSlot(GRID_SLOTS[p.pos], p.needed)
      if not ok then
        collectFromTurtle(nil)
        return false, err or ("couldn't load " .. labelFor(name))
      end
    end
  end

  if onProgress then onProgress("Crafting...") end
  local craftOk, craftErr = turtleCraft(cycles)
  if onProgress then onProgress("Collecting output...") end
  collectFromTurtle((craftOk and not keepInStorage) and recipe.output or nil)

  return craftOk, craftErr
end

-- turtle.craft()'s own limit tops out at 64 crafting operations per call,
-- and a single grid slot can't hold more than maxCyclesForGrid() cycles'
-- worth of its heaviest ingredient either - so a request for more than
-- that safe per-batch cap physically can't be done in one runCraft() call,
-- no matter what. This runs as many batches as it takes (each within the
-- safe cap) to fulfill the full number of cycles requested, stopping
-- early - and reporting exactly how far it actually got - if a batch
-- fails partway (e.g. ingredients run out before the full request is
-- done). Re-plans fresh for each batch since consuming stock in one batch
-- affects what's available for the next.
-- onProgress(phase, cyclesDoneSoFar, cyclesTotal), if given, is called at
-- each phase transition within the CURRENT batch - the done/total numbers
-- reflect fully-completed prior batches, so a progress bar built from them
-- only advances once a whole batch actually finishes, while the phase text
-- shows what the in-flight batch is doing right now.
local function runCraftBatched(recipe, totalCycles, keepInStorage, onProgress)
  local batchCap = math.max(1, math.min(64, maxCyclesForGrid(recipe.grid)))
  local remaining, done = totalCycles, 0
  while remaining > 0 do
    local batch = math.min(batchCap, remaining)
    local positions = planCraft(recipe, batch)
    local ok, err = runCraft(recipe, batch, positions, keepInStorage, onProgress and function(phase)
      onProgress(phase, done, totalCycles)
    end)
    if not ok then
      return false, done, totalCycles, err
    end
    done = done + batch
    remaining = remaining - batch
  end
  return true, done, totalCycles, nil
end

-- One level of auto-resolution only: for each short ingredient, checks
-- whether it has its own craftable recipe AND that recipe's ingredients are
-- fully in stock right now. If the sub-recipe is itself short, it's left
-- alone rather than chasing a bigger tree - keeps this predictable instead
-- of silently kicking off a long chain of crafts the player didn't see.
local function findSubCrafts(summary)
  for _, t in ipairs(summary) do
    if t.short > 0 then
      local row = apiFindRecipeForItem(t.name)
      if row then
        local subRecipe = makeRecipeEntry(row)
        local grid = resolveRecipeGrid(subRecipe)
        if grid then
          local subCycles = math.max(1, math.ceil(t.short / subRecipe.yield))
          local subPositions, _, subShort = planCraft(subRecipe, subCycles)
          if not subShort then
            t.sub = { recipe = subRecipe, cycles = subCycles, positions = subPositions }
          end
        end
      end
    end
  end
end

-- Crafts every short ingredient's resolved sub-craft first (always banked
-- to storage regardless of `keepInStorage` - they're intermediates, not
-- what was actually asked for), then re-plans against the now-updated
-- stock and runs the craft the player actually asked for, delivering to
-- storage or OUTPUT per `keepInStorage` same as a direct runCraft call.
-- Both the sub-crafts and the final craft run through runCraftBatched, so
-- a sub-craft needing a large amount (or the main craft itself) isn't
-- limited to one turtle.craft() call's 64-cycle cap either.
local function craftResolvingShort(recipe, cycles, summary, keepInStorage, onProgress)
  for _, t in ipairs(summary) do
    if t.sub then
      local subOnProgress = onProgress and function(phase, d, tt)
        onProgress(("[missing: %s] %s"):format(labelFor(t.name), phase), d, tt)
      end
      local ok, done, total, err = runCraftBatched(t.sub.recipe, t.sub.cycles, true, subOnProgress)
      if not ok then
        return false, 0, cycles,
          ("couldn't craft %s (got %d/%d): %s"):format(labelFor(t.name), done, total, tostring(err))
      end
    end
  end
  local positions, _, short = planCraft(recipe, cycles)
  if short then return false, 0, cycles, "still missing ingredients after auto-crafting" end
  return runCraftBatched(recipe, cycles, keepInStorage, onProgress)
end

-- Formats a craft result covering all three outcomes: fully done, partially
-- done (some batches succeeded before one failed - e.g. ran out of an
-- ingredient partway through a big multi-batch request), or nothing done.
local function craftStatusMsg(success, done, total, recipe, destLabel, err)
  if success then
    return ("Crafted %d x %s (%s)"):format(done * recipe.yield, recipe.displayName, destLabel)
  elseif done > 0 then
    return ("Crafted %d of %d x %s (%s), then failed: %s")
      :format(done * recipe.yield, total * recipe.yield, recipe.displayName, destLabel, tostring(err or "unknown error"))
  else
    return "Craft failed: " .. tostring(err or "unknown error")
  end
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
  term.setBackgroundColor(colors.black); term.setTextColor(colors.white)
  local used = 8 + 1 + 7
  if tw > used then term.write(string.rep(" ", tw - used)) end
end

-- Minecraft eats Escape and most F-keys before they ever reach the
-- computer as key events (Escape closes the screen, F2 takes a
-- screenshot, etc.), so tabs cycle with Left/Right instead of a hotkey.
local function nextTab(t) return (t == "search") and "craft" or "search" end

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
    local managerStatus
    if not managerLastSeen then
      managerStatus = "manager: not seen"
    else
      managerStatus = ("manager: %ds ago"):format(math.floor((os.epoch("utc") - managerLastSeen) / 1000))
    end
    term.write(managerStatus:sub(1, tw))
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
  for _, t in ipairs(cSummary) do
    term.setCursorPos(1, y)
    term.setTextColor(t.short > 0 and colors.red or colors.lightGray)
    local line = ("%-16s need %3d  have %3d"):format(labelFor(t.name):sub(1, 16), t.needed, t.available)
    if t.short > 0 then
      line = line .. "  SHORT " .. t.short
      if t.sub then line = line .. " *" end
    end
    term.write(line:sub(1, tw))
    y = y + 1
  end
  term.setCursorPos(1, y + 1); term.setTextColor(colors.lightGray)
  if cShort then
    term.write((cHasSub and "* = craftable" or "Missing ingredients above."):sub(1, tw))
    term.setCursorPos(1, y + 2)
    if cHasSub then
      term.write("[S] missing + this -> storage")
      term.setCursorPos(1, y + 3)
      term.write("[O] -> output   [C] cancel")
    else
      term.write("[C] cancel")
    end
  else
    term.write("[Enter] craft -> storage")
    term.setCursorPos(1, y + 2)
    term.write("[O] craft -> output   [C] cancel")
  end
end

local function drawCraftProgress(tw)
  term.setCursorBlink(false)
  term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
  term.write(("Crafting %d x %s"):format(cCycles * cSelected.yield, cSelected.displayName):sub(1, tw))
  term.setCursorPos(1, 4); term.setTextColor(colors.yellow)
  term.write(cProgPhase:sub(1, tw))

  local barWidth = math.max(10, math.min(tw, 40))
  local frac = (cProgTotal > 0) and (cProgDone / cProgTotal) or 0
  local filled = math.floor(barWidth * frac + 0.5)
  term.setCursorPos(1, 6); term.setTextColor(colors.green)
  term.write(("[%s%s]"):format(string.rep("=", filled), string.rep("-", barWidth - filled)):sub(1, tw))

  term.setCursorPos(1, 7); term.setTextColor(colors.gray)
  term.write(("%d / %d crafted"):format(cProgDone * cSelected.yield, cProgTotal * cSelected.yield):sub(1, tw))
end

local function drawCraftStatus(tw)
  term.setCursorBlink(false)
  term.setCursorPos(1, 2); term.setTextColor(colors.cyan)
  term.write(cSelected.displayName:sub(1, tw))
  term.setCursorPos(1, 3); term.setTextColor(colors.lightGray)
  term.write((cStatusMsg or ""):sub(1, tw))
  term.setCursorPos(1, 5); term.setTextColor(colors.gray)
  term.write("[Enter] back to list")
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
    elseif cMode == "progress" then drawCraftProgress(tw)
    elseif cMode == "status" then drawCraftStatus(tw)
    end
  end
end

local function reselect()
  if tMode == "amount" then
    tSelected = tSelected and findEntry(tSelected.key)
    if not tSelected then tMode = "browse" end
  end
end

---------------------------------------------------------------------------
-- MANAGER (storage-manager computer) MESSAGE HANDLER
---------------------------------------------------------------------------
-- manager.lua owns INPUT importing and periodic compaction/consolidation on
-- its own wired connection to the same chests - this computer never touches
-- INPUT itself, it just refreshes its cached index when told something
-- changed, and tracks the last time it heard from the manager at all so
-- that's visible on the Search tab (see managerLastSeen/drawSearchTab).
local function handleManager(sender, msg)
  if type(msg) ~= "table" then return end
  managerLastSeen = os.epoch("utc")
  if msg.cmd == "storageChanged" then
    buildIndex(); applyFilter(); reselect()
    drawTerminal()
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
    local cycles = math.max(1, math.ceil(n / recipe.yield))
    local _, summary, short = planCraft(recipe, cycles)
    if short then findSubCrafts(summary) end
    local out, hasSub = {}, false
    for _, t in ipairs(summary) do
      local craftable = t.sub ~= nil
      if craftable then hasSub = true end
      out[#out + 1] = { label = labelFor(t.name), needed = t.needed, available = t.available,
        short = t.short, craftable = craftable }
    end
    rednet.send(sender, { ok = true, cycles = cycles, produced = cycles * recipe.yield,
      plan = out, short = short, hasSub = hasSub }, REMOTE_PROTO)

  elseif msg.cmd == "craftRequest" then
    if not turtleOk then rednet.send(sender, { ok = false, err = "no staging barrel" }, REMOTE_PROTO); return end
    local recipe, rerr = findByRecipeKey(msg.key or "")
    if not recipe then rednet.send(sender, { ok = false, err = rerr or "unknown recipe" }, REMOTE_PROTO); return end
    local grid, gerr = resolveRecipeGrid(recipe)
    if not grid then rednet.send(sender, { ok = false, err = gerr }, REMOTE_PROTO); return end
    local n = math.max(1, tonumber(msg.amount) or recipe.yield)
    local cycles = math.max(1, math.ceil(n / recipe.yield))
    local _, summary, short = planCraft(recipe, cycles)
    -- Default is banked to storage - deliverToOutput is an explicit opt-in,
    -- same as the local UI's Enter (store) vs O (output) keys.
    local keepInStorage = not msg.deliverToOutput
    local success, done, total, err
    if short and msg.auto then
      findSubCrafts(summary)
      success, done, total, err = craftResolvingShort(recipe, cycles, summary, keepInStorage)
    elseif short then
      rednet.send(sender, { ok = false, err = "missing ingredients" }, REMOTE_PROTO); return
    else
      success, done, total, err = runCraftBatched(recipe, cycles, keepInStorage)
    end
    rednet.send(sender, { ok = success, err = err, produced = done * recipe.yield,
      requested = total * recipe.yield }, REMOTE_PROTO)
  end
end

---------------------------------------------------------------------------
-- MAIN LOOP
---------------------------------------------------------------------------
buildIndex(); applyFilter()
drawStats(); drawTerminal()

local statTimer = os.startTimer(STATS_INTERVAL)

while true do
  local ev = { os.pullEvent() }
  local e1 = ev[1]

  if e1 == "timer" then
    if ev[2] == statTimer then
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
      if canSwitch then
        uiTab = nextTab(uiTab)
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
          cCycles = math.max(1, math.ceil(n / cSelected.yield))
          _, cSummary, cShort = planCraft(cSelected, cCycles)
          if cShort then findSubCrafts(cSummary) end
          cHasSub = false
          for _, t in ipairs(cSummary) do if t.sub then cHasSub = true end end
          cMode = "confirm"
          drawTerminal()
        end
      elseif cMode == "confirm" then
        if code == keys.c then cMode = "list"; drawTerminal()
        elseif (code == keys.enter and not cShort) or (code == keys.o and not cShort)
            or (code == keys.s and cShort and cHasSub) or (code == keys.o and cShort and cHasSub) then
          local toOutput = (code == keys.o)
          local destLabel = toOutput and "sent to output" or "stored"
          cProgPhase, cProgDone, cProgTotal = "Starting...", 0, cCycles
          cMode = "progress"
          drawTerminal()
          local function onProgress(phase, done, total)
            cProgPhase, cProgDone, cProgTotal = phase, done, total
            drawTerminal()
          end
          local success, done, total, err
          if cShort then
            success, done, total, err = craftResolvingShort(cSelected, cCycles, cSummary, not toOutput, onProgress)
          else
            success, done, total, err = runCraftBatched(cSelected, cCycles, not toOutput, onProgress)
          end
          cStatusMsg = craftStatusMsg(success, done, total, cSelected, destLabel, err)
          cMode = "status"
          drawTerminal()
        end
      elseif cMode == "status" then
        if code == keys.enter or code == keys.c then
          cStatusMsg = nil; cMode = "list"; drawTerminal()
        end
      end
    end
    end)
    if not keyOk then lastErr = tostring(keyErr); drawTerminal() end

  elseif e1 == "rednet_message" then
    if ev[4] == REMOTE_PROTO then handleRemote(ev[2], ev[3])
    elseif ev[4] == MANAGER_PROTO then handleManager(ev[2], ev[3]) end

  elseif e1 == "monitor_touch" then
    local x, y = ev[3], ev[4]
    if refreshBtn and y == refreshBtn.y and x >= refreshBtn.x1 and x <= refreshBtn.x2 then
      buildIndex(); applyFilter(); reselect()
      drawStats(); drawTerminal()
    end

  elseif e1 == "monitor_resize" then
    drawStats()
  end
end
