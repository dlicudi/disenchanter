-- Saved-variable migration and defensive repair. This module deliberately has
-- no UI or gameplay dependencies, so schema changes can be tested in isolation.
DisenchanterDBStore = DisenchanterDBStore or {}
local Store = DisenchanterDBStore
local cached

local function repair(d, guards, schemaVersion)
  local schema = tonumber(d.schemaVersion) or 0
  if schema < 1 then schema = 1 end

  if type(d.keep) ~= "table" then d.keep = {} end
  if type(d.keep.items) ~= "table" then d.keep.items = {} end
  if type(d.keep.names) ~= "table" then d.keep.names = {} end
  if type(d.learned) ~= "table" then d.learned = {} end
  if type(d.audit) ~= "table" then d.audit = {} end
  if type(d.runs) ~= "table" then d.runs = {} end
  if type(d.collapsed) ~= "table" then d.collapsed = {} end
  if type(d.panel) ~= "table" then d.panel = {} end

  d.confirmAbove = tonumber(d.confirmAbove) or 2
  if d.confirmAbove < 2 or d.confirmAbove > 4 then d.confirmAbove = 2 end
  d.valueGold = math.max(0, tonumber(d.valueGold) or 10)
  d.ilvlCap = math.max(0, tonumber(d.ilvlCap) or 0)
  if type(d.sortProfit) ~= "boolean" then d.sortProfit = false end

  -- Reset the old diagnostic spell path once. Macro mode is the supported
  -- default; the alternate remains available through /de mode.
  if d.clickModeVersion ~= 2 then d.clickMode, d.clickModeVersion = "macro", 2 end

  if type(d.guards) ~= "table" then d.guards = {} end
  for _, guard in ipairs(guards) do
    if type(d.guards[guard.key]) ~= "boolean" then
      d.guards[guard.key] = guard.key ~= "boe"
    end
  end

  for id, kept in pairs(d.keep.items) do
    if type(id) ~= "number" or kept ~= true then d.keep.items[id] = nil end
  end
  for i = #d.keep.names, 1, -1 do
    if type(d.keep.names[i]) ~= "string" then table.remove(d.keep.names, i) end
  end
  for id, learned in pairs(d.learned) do
    if type(id) ~= "number" or learned ~= true then d.learned[id] = nil end
  end
  for i = #d.audit, 1, -1 do
    local entry = d.audit[i]
    if type(entry) ~= "table" or type(entry.t) ~= "number"
        or type(entry.out) ~= "string" or type(entry.n) ~= "number" or entry.n < 1 then
      table.remove(d.audit, i)
    end
  end
  for i = #d.runs, 1, -1 do
    local run = d.runs[i]
    if type(run) ~= "table" or type(run.start) ~= "number"
        or type(run.finish) ~= "number" or type(run.totals) ~= "table" then
      table.remove(d.runs, i)
    end
  end

  d.schemaVersion = math.max(schema, schemaVersion)
  return d
end

function Store.Get(guards, schemaVersion)
  if type(DisenchanterDB) ~= "table" then DisenchanterDB = {} end
  if cached ~= DisenchanterDB then
    cached = repair(DisenchanterDB, guards, schemaVersion)
  end
  return cached
end
