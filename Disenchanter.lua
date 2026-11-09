-- Guarded disenchanting, trash deletion, and run accounting.
-- User documentation and the release checklist live in README.md. Keep the
-- safety rationale beside the secure-action code that enforces it.

local DE = {}
Disenchanter = DE -- global, mostly for /dump poking
local VERSION = "0.6.0"
local DB_SCHEMA = 1

local C = assert(DisenchanterCompat and DisenchanterCompat.Container,
  "Disenchanter: compatibility module did not load")

--- The 1.60 Classic client finished a migration the older builds hadn't started:
--- the loose item/spell/money globals now live in C_Item, C_SpellBook and
--- C_CurrencyInfo, and the globals are simply gone. These locals shadow the
--- globals with whichever spelling the running client has, so every call site
--- below stays written the old way and works on all three flavours.
local GetItemInfo         = GetItemInfo         or (C_Item and C_Item.GetItemInfo)
local GetItemInfoInstant  = GetItemInfoInstant  or (C_Item and C_Item.GetItemInfoInstant)
local GetItemSpell        = GetItemSpell        or (C_Item and C_Item.GetItemSpell)
local GetInventoryItemLink = GetInventoryItemLink or (C_Item and C_Item.GetInventoryItemLink)
local GetCoinTextureString = GetCoinTextureString or (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString)
local IsSpellKnown        = IsSpellKnown        or (C_SpellBook and C_SpellBook.IsSpellKnown)
-- Blizzard's own deprecation maps IsPlayerSpell onto the "or overrides" variant.
local IsPlayerSpell       = IsPlayerSpell       or (C_SpellBook and C_SpellBook.IsSpellKnownOrOverridesKnown)
local DE_SPELL   = 13262 -- Disenchant
local ENCH_SPELL = 7411  -- Enchanting (for the skill-line name)

local function pr(msg) print("|cffa335eeDisenchanter:|r " .. msg) end

--- The localised name of a spell. The Anniversary client rides the modern
--- engine, where GetSpellInfo has variously returned a name, returned a table,
--- and stopped existing — so try every shape and fall back to the enUS name
--- rather than letting a nil reach string.format.
local function spellName(spellID, fallback)
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
  end
  if GetSpellInfo then
    local ok, a = pcall(GetSpellInfo, spellID)
    if ok then
      if type(a) == "string" then return a end
      if type(a) == "table" and type(a.name) == "string" then return a.name end
    end
  end
  return fallback
end

local function deName() return spellName(DE_SPELL, "Disenchant") end

local BANDS = assert(DisenchanterData and DisenchanterData.bands,
  "Disenchanter: data module did not load")

local function bandFor(quality, ilvl)
  local bands = BANDS[quality]
  if not bands then return nil end
  for _, band in ipairs(bands) do
    if ilvl <= band[1] then return band end
  end
  return bands[#bands]
end

local function yieldFor(quality, ilvl)
  local bands = BANDS[quality]
  if not bands then return nil, nil end
  local band = bandFor(quality, ilvl)
  return band[3], band[2]
end

--------------------------------------------------------------------------------
-- Item classification.
--------------------------------------------------------------------------------
-- Equippable things that are still not disenchantable, whatever their quality.
local NEVER_INVTYPE = {
  INVTYPE_BODY = true,   -- shirts
  INVTYPE_TABARD = true,
  INVTYPE_BAG = true,
  INVTYPE_AMMO = true,
  INVTYPE_QUIVER = true,
}
-- Armor subclasses 7-10 are the relic slot (Libram / Idol / Totem / Sigil).
local RELIC_SUB = { [7] = true, [8] = true, [9] = true, [10] = true }

-- Equipment slots an item type can occupy, for the "is this better than what
-- I'm wearing" guard.
local INV_SLOTS = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 },
  INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 }, INVTYPE_WAIST = { 6 },
  INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 },
  INVTYPE_HAND = { 10 }, INVTYPE_FINGER = { 11, 12 },
  INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
  INVTYPE_WEAPON = { 16, 17 }, INVTYPE_2HWEAPON = { 16 },
  INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_WEAPONOFFHAND = { 17 },
  INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
  INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 },
  INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}

local QUALITY_NAME = { [2] = "uncommon", [3] = "rare", [4] = "epic" }
local CONFIRM_LABEL = { [2] = "Uncommon (green)", [3] = "Rare (blue)", [4] = "Epic (purple)" }

--- Can this item be disenchanted at all? Cheap id-only test, no tooltip work.
local function isDisenchantable(classID, subID, quality, invType)
  if not quality or quality < 2 or quality > 4 then return false end
  if classID ~= 2 and classID ~= 4 then return false end -- weapon / armor only
  if invType and NEVER_INVTYPE[invType] then return false end
  return true
end

--------------------------------------------------------------------------------
-- Saved variables.
--------------------------------------------------------------------------------
-- Every guard, in the order they're checked and shown. `hard` guards move an
-- item to Protected (no click works); the rest only ask for a Ctrl-click.
-- `off` guards start switched off.
local GUARDS = {
  { key = "quest",    hard = true,  label = "Quest items" },
  { key = "relic",    hard = true,  label = "Relics (idol / libram / totem)" },
  { key = "set",      hard = true,  label = "Item-set pieces" },
  { key = "use",      hard = true,  label = "Items with a Use: effect" },
  { key = "upgrade",  hard = true,  label = "Beats my equipped item" },
  { key = "pawn",     hard = true,  label = "Pawn calls it an upgrade" },
  { key = "itemrack", hard = true,  label = "In an ItemRack set" },
  { key = "boe",      hard = false, off = true, label = "Any bind-on-equip item" },
  { key = "value",    hard = false, label = "Valuable BoEs (see /de value)" },
  { key = "loss",     hard = false, off = true, label = "Loses money to disenchant (see /de loss)" },
}

local DB = assert(DisenchanterDBStore, "Disenchanter: database module did not load")
local function db()
  return DB.Get(GUARDS, DB_SCHEMA)
end

--- The guard switches and thresholds in force: this character's own when it
--- opted in (/de char), the account's otherwise. Everything else — the keep
--- list, the audit, runs — is always the account's, through db().
local function cfg()
  local c = DB.GetChar(GUARDS)
  return c.own and c or db()
end

-- Overrides live for the session only. Protecting something is permanent (it
-- goes on the keep list); un-protecting it is deliberately not, so a guard you
-- waved past today is back tomorrow.
local allowed = {}
local filterText = ""

--------------------------------------------------------------------------------
-- Item identity. An item id alone is not an item: "Notched Shortsword of
-- Magic" and "... of Healing" share one id and differ only in the link. Older
-- clients carry the difference in the suffix field (7th); the 1.60 client
-- leaves that empty and uses bonus ids instead (a count in the 13th field,
-- then the ids). The fields in between — unique id, link level, spec — vary
-- per copy or per character without changing what the item is, so they stay
-- out of the key, as do enchants and gems: a kept sword is still kept after
-- you enchant it.
--------------------------------------------------------------------------------
--- @return the bare item id (a number) for a plain item, or "id:suffix:bonus.bonus"
local function itemKey(link, itemID)
  local body = type(link) == "string" and link:match("item:([^|]+)")
  if not body then return itemID end
  local f = {}
  for field in (body .. ":"):gmatch("([^:]*):") do f[#f + 1] = field end
  local id = tonumber(f[1]) or itemID
  local suffix = tonumber(f[7]) or 0
  local bonus = {}
  for i = 14, 13 + (tonumber(f[13]) or 0) do
    local b = tonumber(f[i])
    if b then bonus[#bonus + 1] = b end
  end
  if suffix == 0 and #bonus == 0 then return id end
  table.sort(bonus)
  return ("%s:%d:%s"):format(tostring(id), suffix, table.concat(bonus, "."))
end

--- The name as the link spells it, suffix included. GetItemInfo(itemID) only
--- ever knows the base name.
local function linkName(link)
  return type(link) == "string" and link:match("|h%[(.-)%]|h") or nil
end

local function keyOf(it) return it.key or it.itemID end

--- Is this item on the keep list? An exact entry (what the padlock writes)
--- wins; a bare item id — `/de keep #727`, or a padlock from before variants
--- were told apart — covers every version of that item. Erring that way round
--- means an old entry never silently stops protecting something.
--- @return the matching keep-list key, and true when it was the bare-id entry
---         standing in for a variant
local function keptAs(it)
  local items = db().keep.items
  local key = keyOf(it)
  if items[key] then return key, false end
  if key ~= it.itemID and items[it.itemID] then return it.itemID, true end
  return nil
end

local KEPT, KEPT_ALL = "on your keep list", "on your keep list (every version of this item)"

--------------------------------------------------------------------------------
-- Odds and ends the guards lean on.
--------------------------------------------------------------------------------
local function money(copper) return GetCoinTextureString(copper or 0) end

--- Money for a narrow column: from a gold upwards the copper is noise.
local function shortMoney(copper)
  copper = math.floor((copper or 0) + 0.5)
  if copper >= 10000 then copper = copper - copper % 100 end
  return GetCoinTextureString(copper)
end

--- Money with no texture escapes, for chat channels (which reject them).
local function plainMoney(copper)
  copper = math.floor((copper or 0) + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
  if g > 0 then return s > 0 and ("%dg %ds"):format(g, s) or ("%dg"):format(g) end
  if s > 0 then return c > 0 and ("%ds %dc"):format(s, c) or ("%ds"):format(s) end
  return ("%dc"):format(c)
end

--- Your Enchanting rank, or nil if we can't see it (collapsed skill headers).
local function enchantingSkill()
  local want = spellName(ENCH_SPELL, "Enchanting")
  for i = 1, (GetNumSkillLines and GetNumSkillLines() or 0) do
    local name, isHeader, _, rank = GetSkillLineInfo(i)
    if not isHeader and name == want then return rank end
  end
  return nil
end

--- True once we've confirmed the player actually has Disenchant.
local function knowsDisenchant()
  if IsSpellKnown and IsSpellKnown(DE_SPELL) then return true end
  if IsPlayerSpell and IsPlayerSpell(DE_SPELL) then return true end
  return enchantingSkill() ~= nil
end

-- Tooltip scanning, only for the two things no API exposes: quest text and
-- "this item begins a quest". Cached per item id — the answer never changes.
local scanTip = CreateFrame("GameTooltip", "DisenchanterScanTooltip", nil, "GameTooltipTemplate")
scanTip:SetOwner(UIParent, "ANCHOR_NONE")
local questCache = {}

local function isQuestItem(bag, slot, itemID)
  local cached = questCache[itemID]
  if cached ~= nil then return cached end
  scanTip:ClearLines()
  scanTip:SetBagItem(bag, slot)
  local found = false
  for i = 2, scanTip:NumLines() do
    local fs = _G["DisenchanterScanTooltipTextLeft" .. i]
    local text = fs and fs:GetText()
    if text then
      if (ITEM_BIND_QUEST and text == ITEM_BIND_QUEST)
        or (ITEM_STARTS_QUEST and text == ITEM_STARTS_QUEST) then
        found = true
        break
      end
    end
  end
  questCache[itemID] = found
  return found
end

--- Best value we can put on a stack: Auctionator's market price if the addon is
--- there and has seen the item, otherwise the vendor price. Returns copper and
--- which of the two it was.
local function valueOf(itemID, sellPrice, count)
  local ah = Auctionator and Auctionator.API and Auctionator.API.v1
  if ah and ah.GetAuctionPriceByItemID then
    local ok, price = pcall(ah.GetAuctionPriceByItemID, "Disenchanter", itemID)
    if ok and type(price) == "number" and price > 0 then return price * (count or 1), "ah" end
  end
  if TSM_API and TSM_API.GetCustomPriceValue then
    local ok, price = pcall(TSM_API.GetCustomPriceValue, "dbmarket", "i:" .. itemID)
    if ok and type(price) == "number" and price > 0 then return price * (count or 1), "ah" end
  end
  if sellPrice and sellPrice > 0 then return sellPrice * (count or 1), "vendor" end
  return nil, nil
end

local function marketPrice(itemID)
  if not itemID then return 0 end
  local price, src = valueOf(itemID, nil, 1)
  return src == "ah" and price or nil
end

--------------------------------------------------------------------------------
-- Observed yields. Every disenchant this addon attributes is counted against
-- its band (quality + item-level bracket), so after YIELD_MIN of a kind the
-- value estimate rests on what you actually got rather than on book odds.
--------------------------------------------------------------------------------
local YIELD_MIN = 25

local function yieldKey(quality, band) return quality * 1000 + band[1] end

local function recordYield(srcLink, matID, count)
  if not srcLink then return end
  local _, _, quality, ilvl = GetItemInfo(srcLink)
  local band = quality and ilvl and bandFor(quality, ilvl)
  if not band then return end
  local yields, key = db().yields, yieldKey(quality, band)
  local seen = yields[key]
  if not seen then seen = { n = 0, mats = {} }; yields[key] = seen end
  seen.n = seen.n + 1
  local m = seen.mats[matID]
  if not m then m = { h = 0, q = 0 }; seen.mats[matID] = m end
  m.h, m.q = m.h + 1, m.q + count
end

--- @return expected copper from one disenchant, and — when the figure comes
---         from your own results — how many disenchants it rests on
local function expectedDisenchantValue(quality, ilvl)
  local band = bandFor(quality, ilvl)
  if not band then return nil end
  local seen = db().yields[yieldKey(quality, band)]
  if seen and seen.n >= YIELD_MIN then
    local total, priced = 0, true
    for id, m in pairs(seen.mats) do
      local price = marketPrice(id)
      if not price or price <= 0 then priced = false break end
      total = total + price * m.q / seen.n
    end
    if priced and total > 0 then return total, seen.n end
  end
  local mats = band[4]
  if quality ~= 2 then return marketPrice(mats[1]) end
  local dust, essence, shard = marketPrice(mats[1]), marketPrice(mats[2]), marketPrice(mats[3])
  if not dust or (mats[2] and not essence) or (mats[3] and not shard) then return nil end
  -- Approximate classic uncommon distribution: mostly dust, sometimes essence,
  -- rarely a shard. Quantities are expected stack sizes, not guaranteed drops.
  return dust * 1.875 + (essence or 0) * 0.3 + (shard or 0) * 0.05
end

--- Pawn's own "should this have an upgrade arrow" test, if Pawn is loaded.
local function pawnSaysUpgrade(link)
  if not (link and PawnShouldItemLinkHaveUpgradeArrow) then return false end
  local ok, up = pcall(PawnShouldItemLinkHaveUpgradeArrow, link)
  return ok and up and true or false
end

--- itemID -> ItemRack set name, rebuilt once per scan (sets change rarely, but
--- rebuilding is trivial and beats going stale).
local function itemRackIndex()
  local out = {}
  local sets = ItemRackUser and ItemRackUser.Sets
  if type(sets) ~= "table" then return out end
  for setName, set in pairs(sets) do
    if type(set) == "table" and type(set.equip) == "table" and setName:sub(1, 1) ~= "~" then
      for _, itemString in pairs(set.equip) do
        local id = tonumber(tostring(itemString):match("^(%d+)"))
        if id then out[id] = out[id] or setName end
      end
    end
  end
  return out
end

--- The equipped item in each of an item's candidate slots, so we can tell an
--- upgrade from vendor trash. Compares like for like: a cloth piece is never an
--- "upgrade" over the plate you're wearing.
---
--- Empty slots are skipped rather than counted as "anything is an upgrade" —
--- otherwise every off-hand green looks like a keeper to a two-hander user.
--- @return the name of the equipped item this out-levels, or nil
local function beatsEquipped(invType, ilvl, classID, subID)
  local slots = INV_SLOTS[invType]
  if not slots then return nil end
  local worst, worstName -- the slot you'd actually replace: the weakest one
  for _, s in ipairs(slots) do
    local link = GetInventoryItemLink and GetInventoryItemLink("player", s)
    if link then
      local eName, _, _, eLvl, _, _, _, _, _, _, _, eClass, eSub = GetItemInfo(link)
      -- Armour classes only compare against their own kind (1 cloth .. 4 plate);
      -- subclasses above 4 (shields, relics) and all weapons compare freely.
      local comparable = (classID ~= 4) or (eClass ~= 4) or (subID > 4) or (eSub == subID)
      if eLvl and comparable and (not worst or eLvl < worst) then
        worst, worstName = eLvl, eName
      end
    end
  end
  if worst and ilvl > worst then return worstName end
  return nil
end

--------------------------------------------------------------------------------
-- The verdict. Order matters: the first thing that fires is the reason shown,
-- so the most alarming checks come first.
--------------------------------------------------------------------------------
local function verdict(it, skill)
  local d, s = db(), cfg()
  local g = s.guards

  local kept, everyVersion = keptAs(it)
  if kept then return "blocked", everyVersion and KEPT_ALL or KEPT, true end
  for _, n in ipairs(d.keep.names) do
    if n ~= "" and it.name:lower():find(n:lower(), 1, true) then
      return "blocked", 'keep list: "' .. n .. '"', true
    end
  end
  if d.learned[it.itemID] then return "blocked", "the server says this can't be disenchanted", true end
  if it.skillNeeded and skill and skill < it.skillNeeded then
    return "blocked", ("needs Enchanting %d (you have %d)"):format(it.skillNeeded, skill), true
  end

  if not allowed[keyOf(it)] then
    if g.quest and it.isQuest then return "blocked", "quest item" end
    if g.relic and it.isRelic then return "blocked", "relic — idol / libram / totem" end
    if g.set and it.setID then return "blocked", "part of an item set" end
    if g.use and it.useSpell then return "blocked", "has a Use: effect (" .. it.useSpell .. ")" end
    if g.upgrade and it.beats then return "blocked", "out-levels your equipped " .. it.beats end
    if g.pawn and it.pawnUpgrade then return "blocked", "Pawn rates this an upgrade" end
    if g.itemrack and it.rackSet then return "blocked", "in your ItemRack set '" .. it.rackSet .. "'" end
  end

  if g.boe and it.boe then return "confirm", "bind-on-equip" end
  if g.value and s.valueGold > 0 and it.boe and it.value and it.value >= s.valueGold * 10000 then
    return "confirm", ("worth %s%s"):format(money(it.value), it.valueSrc == "ah" and " on the AH" or " to a vendor")
  end
  -- Only bites when both sides are priced: `profit` is nil without market
  -- prices for the materials, so the guard stands down rather than guess.
  if g.loss and it.profit and -it.profit > s.lossSilver * 100 then
    return "confirm", ("loses about %s against %s"):format(shortMoney(-it.profit),
      it.valueSrc == "ah" and "its AH price" or "vendoring it")
  end
  if it.quality > s.confirmAbove then
    return "confirm", (QUALITY_NAME[it.quality] or "high") .. " quality"
  end
  if s.ilvlCap > 0 and it.ilvl > s.ilvlCap then
    return "confirm", ("item level %d, over your cap of %d"):format(it.ilvl, s.ilvlCap)
  end
  return "safe", nil
end

--------------------------------------------------------------------------------
-- Scan the bags.
--------------------------------------------------------------------------------
--- @return safe, confirm, blocked  three arrays of item records
function DE.Scan()
  local safe, confirm, blocked = {}, {}, {}
  local d, g = db(), cfg().guards
  local rack = g.itemrack and itemRackIndex() or {}
  local skill = enchantingSkill()

  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, (C.GetContainerNumSlots(bag) or 0) do
      local info = C.GetContainerItemInfo(bag, slot)
      local casting = DE.cast and info and DE.cast.bag == bag and DE.cast.slot == slot
        and DE.cast.itemID == info.itemID
      -- Locked items are mid-move or mid-cast; leave them alone — except the
      -- slot our own cast locked, which stays listed so its row can show progress.
      if info and info.itemID and (casting or not info.isLocked) then
        -- GetItemInfo is nil until the client caches the item; the call itself
        -- requests it and GET_ITEM_INFO_RECEIVED repaints, so a skipped item
        -- reappears a moment later.
        local name, link, quality, ilvl, _, _, _, _, invType, _, sellPrice,
              classID, subID, bindType, _, setID = GetItemInfo(info.itemID)
        if name and isDisenchantable(classID, subID, quality, invType) then
          local yield, skillNeeded = yieldFor(quality, ilvl)
          local value, valueSrc = valueOf(info.itemID, sellPrice, info.stackCount or 1)
          local deValue, deSeen = expectedDisenchantValue(quality, ilvl)
          local it = {
            bag = bag, slot = slot, itemID = info.itemID,
            key = itemKey(info.hyperlink, info.itemID),
            name = linkName(info.hyperlink) or name,
            link = info.hyperlink or link, icon = info.iconFileID,
            quality = quality, ilvl = ilvl, count = info.stackCount or 1,
            yield = yield, skillNeeded = skillNeeded,
            value = value, valueSrc = valueSrc,
            deValue = deValue and math.floor(deValue + 0.5) or nil,
            deSeen = deSeen,
            profit = deValue and value and math.floor(deValue - value + 0.5) or nil,
            boe = (bindType == 2) and not info.isBound,
            setID = setID,
            isRelic = (classID == 4 and RELIC_SUB[subID]) or invType == "INVTYPE_RELIC",
            isQuest = isQuestItem(bag, slot, info.itemID),
            useSpell = (GetItemSpell and GetItemSpell(info.itemID)) or nil,
            rackSet = rack[info.itemID],
            casting = casting or nil,
          }
          it.beats = g.upgrade and beatsEquipped(invType, ilvl, classID, subID) or nil
          it.pawnUpgrade = g.pawn and pawnSaysUpgrade(it.link) or false

          local tier, reason, permanent = verdict(it, skill)
          it.tier, it.reason, it.permanent = tier, reason, permanent
          local bucket = (tier == "safe" and safe) or (tier == "confirm" and confirm) or blocked
          bucket[#bucket + 1] = it
        end
      end
    end
  end

  -- Cheapest first inside each bucket: you work down a bag of greens from the
  -- top, and the top row is always the one you care least about.
  local function order(a, b)
    if d.sortProfit and a.profit ~= b.profit then
      if a.profit == nil then return false end
      if b.profit == nil then return true end
      return a.profit > b.profit
    end
    local av, bv = a.value or math.huge, b.value or math.huge
    if av ~= bv then return av < bv end
    if a.quality ~= b.quality then return a.quality < b.quality end
    if a.ilvl ~= b.ilvl then return a.ilvl < b.ilvl end
    return a.name < b.name
  end
  table.sort(safe, order); table.sort(confirm, order); table.sort(blocked, order)
  return safe, confirm, blocked
end

--------------------------------------------------------------------------------
-- The Trash tab's scan: junk worth deleting when the bags are full. Quality 0
-- and 1 only — anything disenchantable belongs on the other tab, and deleting
-- anything better than white is a decision, not a chore.
--------------------------------------------------------------------------------
-- Items no click may ever delete, whatever their quality says.
local NEVER_DELETE = {
  [6948] = true, -- Hearthstone
}

local function trashVerdict(it)
  local d, s = db(), cfg()
  local kept, everyVersion = keptAs(it)
  if kept then return "blocked", everyVersion and KEPT_ALL or KEPT, true end
  for _, n in ipairs(d.keep.names) do
    if n ~= "" and it.name:lower():find(n:lower(), 1, true) then
      return "blocked", 'keep list: "' .. n .. '"', true
    end
  end
  if not allowed[keyOf(it)] then
    if s.guards.quest and it.isQuest then return "blocked", "quest item" end
    -- The value guard bites harder here than on the disenchant tab: deleting
    -- a stack of cloth is pure loss, so a valuable stack is Protected, not
    -- merely Ctrl-gated. Allow drops it to "check first" as usual.
    if s.guards.value and s.valueGold > 0 and it.value and it.value >= s.valueGold * 10000 then
      return "blocked", ("worth %s%s"):format(money(it.value),
        it.valueSrc == "ah" and " on the AH" or " to a vendor")
    end
  end
  if it.quality >= 1 then return "confirm", "white quality" end
  return "safe", nil
end

--- Same three-bucket shape as DE.Scan, sorted cheapest stack first: working
--- through it top-down always loses you the least.
function DE.ScanTrash()
  local safe, confirm, blocked = {}, {}, {}
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, (C.GetContainerNumSlots(bag) or 0) do
      local info = C.GetContainerItemInfo(bag, slot)
      if info and info.itemID and not info.isLocked and not NEVER_DELETE[info.itemID] then
        local name, link, quality, _, _, _, _, _, _, _, sellPrice = GetItemInfo(info.itemID)
        if name and quality and quality <= 1 then
          local count = info.stackCount or 1
          local value, valueSrc = valueOf(info.itemID, sellPrice, count)
          local it = {
            bag = bag, slot = slot, itemID = info.itemID,
            key = itemKey(info.hyperlink, info.itemID),
            name = linkName(info.hyperlink) or name,
            link = info.hyperlink or link, icon = info.iconFileID,
            quality = quality, count = count,
            isBound = info.isBound,
            vendor = (sellPrice or 0) * count,
            value = value, valueSrc = valueSrc,
            isQuest = isQuestItem(bag, slot, info.itemID),
            trash = true,
          }
          local tier, reason, permanent = trashVerdict(it)
          it.tier, it.reason, it.permanent = tier, reason, permanent
          local bucket = (tier == "safe" and safe) or (tier == "confirm" and confirm) or blocked
          bucket[#bucket + 1] = it
        end
      end
    end
  end
  local function order(a, b)
    if a.vendor ~= b.vendor then return a.vendor < b.vendor end
    return a.name < b.name
  end
  table.sort(safe, order); table.sort(confirm, order); table.sort(blocked, order)
  return safe, confirm, blocked
end

local function qcolor(q)
  local c = ITEM_QUALITY_COLORS[q]
  return c and c.hex or "|cffffffff"
end

--------------------------------------------------------------------------------
-- Item tooltips. Anywhere an item tooltip appears — bags, the auction house,
-- a loot roll, a chat link — a disenchantable item says what it turns into
-- and what that is worth. Half the guards (bound state, quest text) can only
-- be read from a bag slot, so a verdict exists only for a copy you are
-- carrying — and the line says so, because the tooltip itself may be showing
-- an auction or a link to the same item.
--------------------------------------------------------------------------------
local tipIndex          -- item key -> its scanned record; rebuilt lazily
local tipQuiet = false  -- set while the window paints its own, fuller tooltip
local tipWarned = false
local tipTwoHooks = false -- both hook paths are installed; check before adding
local TIER_RANK = { safe = 1, confirm = 2, blocked = 3 }
local TIER_TEXT = {
  safe    = "|cff55c96bSafe to disenchant|r",
  confirm = "|cffd7ad45Ctrl-click|r",
  blocked = "|cffb96a6aProtected|r",
}

--- The verdict for an item as it sits in your bags; with two copies that
--- disagree (one bound, one not) the stricter one is reported.
local function bagVerdict(key)
  if not tipIndex then
    tipIndex = {}
    local safe, confirm, blocked = DE.Scan()
    for _, list in ipairs({ safe, confirm, blocked }) do
      for _, it in ipairs(list) do
        local k = keyOf(it)
        local old = tipIndex[k]
        if not old or TIER_RANK[it.tier] > TIER_RANK[old.tier] then tipIndex[k] = it end
      end
    end
  end
  return tipIndex[key]
end

local function tooltipLines(tip, data)
  if tipQuiet or not db().tooltips then return end
  if tip ~= GameTooltip and tip ~= ItemRefTooltip then return end
  local link
  if tip.GetItem then
    local _, l = tip:GetItem()
    link = l
  end
  if not link and type(data) == "table" then
    link = data.hyperlink or (data.id and ("item:" .. data.id)) or nil
  end
  if type(link) ~= "string" then return end
  local name, _, quality, ilvl, _, _, _, _, invType, _, sellPrice, classID, subID = GetItemInfo(link)
  if not (name and ilvl and isDisenchantable(classID, subID, quality, invType)) then return end
  local itemID = tonumber(link:match("item:(%d+)"))
  local yield, skillNeeded = yieldFor(quality, ilvl)
  if not yield then return end

  if tipTwoHooks then
    -- Both hooks may fire for one tooltip; the second finds the lines there.
    local tipName = tip.GetName and tip:GetName()
    for i = (tipName and tip:NumLines() or 0), 1, -1 do
      local fs = _G[tipName .. "TextLeft" .. i]
      local text = fs and fs:GetText()
      if type(text) == "string" and text:find("Disenchants into: ", 1, true) then return end
    end
  end

  local found = itemID and bagVerdict(itemKey(link, itemID))
  tip:AddLine(" ")
  if found then
    tip:AddLine("In your bags: " .. TIER_TEXT[found.tier]
      .. (found.reason and (" |cff999999— " .. found.reason .. "|r") or ""), 1, 1, 1, true)
  end
  tip:AddLine("Disenchants into: " .. yield, 0.6, 0.85, 1, true)
  local skill = enchantingSkill()
  if skillNeeded and skill and skill < skillNeeded then
    tip:AddLine(("Needs Enchanting %d (you have %d)"):format(skillNeeded, skill), 1, 0.4, 0.4)
  end
  local deValue = expectedDisenchantValue(quality, ilvl)
  if deValue then
    local value, src = valueOf(itemID, sellPrice, 1)
    local versus = ""
    if value then
      local diff = deValue - value
      versus = (" |cff999999(%s%s|cff999999 vs %s)|r"):format(
        diff >= 0 and "|cff55bb66+" or "|cffff6666-", shortMoney(math.abs(diff)),
        src == "ah" and "AH" or "vendor")
    end
    tip:AddLine("Materials worth about " .. shortMoney(deValue) .. versus, 0.55, 0.85, 1)
  end
end

--- A broken tooltip hook would raise an error on every hover, so failures are
--- reported once and then swallowed.
local function onTooltipItem(tip, data)
  local ok, err = pcall(tooltipLines, tip, data)
  if not ok and not tipWarned then
    tipWarned = true
    pr("item tooltips hit an error and were skipped: " .. tostring(err))
  end
end

--- Newer clients route item tooltips through TooltipDataProcessor; the older
--- ones fire OnTooltipSetItem. A client in between could define the first and
--- still use the second, so hook every path that exists and let tooltipLines
--- skip a tooltip it has already written to.
local function hookTooltips()
  local processor = TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
    and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item
  local scripts = 0
  for _, tip in pairs({ GameTooltip, ItemRefTooltip }) do
    if tip.HookScript and tip.HasScript and tip:HasScript("OnTooltipSetItem") then
      tip:HookScript("OnTooltipSetItem", onTooltipItem)
      scripts = scripts + 1
    end
  end
  if processor then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onTooltipItem)
  end
  tipTwoHooks = processor and scripts > 0 or false
end

--------------------------------------------------------------------------------
-- Chat report.
--------------------------------------------------------------------------------

function DE.Report()
  local safe, confirm, blocked = DE.Scan()
  if #safe + #confirm + #blocked == 0 then
    pr("nothing disenchantable in your bags.")
    return
  end
  local function dump(label, list, color)
    if #list == 0 then return end
    pr(("%s%s|r (%d):"):format(color, label, #list))
    for _, it in ipairs(list) do
      print(("    %s%s"):format(it.link, it.reason and ("  |cff888888" .. it.reason .. "|r") or
        (it.yield and ("  |cff888888~ " .. it.yield .. "|r") or "")))
    end
  end
  dump("Safe", safe, "|cff33cc44")
  dump("Check first", confirm, "|cffffd100")
  dump("Protected", blocked, "|cffff5555")
  print("    |cff888888/de opens the window — click a Safe row to disenchant it.|r")
end

--------------------------------------------------------------------------------
-- Session tally and the audit log: what each cast actually produced. Loot
-- lines that land within a couple of seconds of a Disenchant completing are
-- attributed to it — only YOUR loot lines, so a party member picking a mob
-- clean at the same instant can't pollute the count. Still imprecise if you
-- yourself loot at that exact moment; good enough otherwise.
--
-- The tally is per-session; the audit (what → what, when, where, group size)
-- is saved, capped at the newest AUDIT_MAX entries. /de split totals the audit
-- from a marker onward and divides by the group — see DE.Split.
--------------------------------------------------------------------------------
DE.tally = {}
local lastDE = 0
local lastDESource -- link of the item the completed cast consumed
local lastDEOwn    -- the same, but only when this addon started the cast
local sessionStart = time() -- fallback split marker: since login; see resumeSession
local AUDIT_MAX = 300

-- Disenchant outputs on the supported Era/TBC-family clients. Restricting the
-- audit to these ids prevents an unrelated personal loot line in the short
-- attribution window from becoming part of the shard split.
local ENCHANT_MATERIAL = {
  [10938]=true, [10939]=true, [10940]=true, [10998]=true,
  [11082]=true, [11083]=true, [11084]=true,
  [11134]=true, [11135]=true, [11137]=true, [11138]=true, [11139]=true,
  [11174]=true, [11175]=true, [11176]=true, [11177]=true, [11178]=true,
  [14343]=true, [14344]=true, [16202]=true, [16203]=true, [16204]=true,
  [20725]=true, [22445]=true, [22446]=true, [22447]=true, [22448]=true,
  [22449]=true, [22450]=true,
}

-- "You receive loot: %s." and friends, turned into literal prefixes. If none
-- of the globals exist on this client, the filter stands down (old behavior).
local SELF_LOOT_PREFIX = {}
for _, fmt in pairs({ LOOT_ITEM_SELF, LOOT_ITEM_SELF_MULTIPLE,
                      LOOT_ITEM_PUSHED_SELF, LOOT_ITEM_PUSHED_SELF_MULTIPLE }) do
  local prefix = type(fmt) == "string" and fmt:match("^(.-)%%s")
  if prefix and prefix ~= "" then SELF_LOOT_PREFIX[#SELF_LOOT_PREFIX + 1] = prefix end
end

local function isSelfLoot(msg)
  if #SELF_LOOT_PREFIX == 0 then return true end
  for _, p in ipairs(SELF_LOOT_PREFIX) do
    if msg:sub(1, #p) == p then return true end
  end
  return false
end

-- "Since login" has to mean since you sat down, not since the client last
-- loaded the UI: a /reload or a dropped connection mid-dungeon must not wipe
-- the run. So the session start is saved, and a login that follows the last
-- sign of life by less than SESSION_GRACE picks the old session back up.
-- Half an hour is how long an instance waits for you before it resets.
--
-- `lastSeen` is stamped on every event the addon receives (see the event
-- handler) rather than only on PLAYER_LOGOUT, so it is still recent if the
-- connection drops without a clean logout. What can't be survived is the
-- client itself dying: saved variables are only written on a clean UI
-- shutdown, so a crash loses everything since the previous save.
local SESSION_GRACE = 30 * 60
local sessionLive = false

local function resumeSession()
  local d = db()
  local now = time()
  local resumed = d.sessionStart and d.lastSeen
    and d.sessionStart <= now and now - d.lastSeen <= SESSION_GRACE
  if not resumed then d.sessionStart = now end
  d.lastSeen = now
  sessionStart = d.sessionStart
  sessionLive = true
  -- The tally is "this session" too; rebuild it from the audit so it agrees.
  DE.tally = {}
  for _, e in ipairs(d.audit) do
    if e.t >= sessionStart and not e.del then
      DE.tally[e.out] = (DE.tally[e.out] or 0) + e.n
    end
  end
end

--- `deleted` marks a Trash-tab deletion: it shows in /de audit like anything
--- else, but /de split skips it — a destroyed grey is nobody's shard.
local function auditAppend(src, out, count, deleted)
  local d = db()
  local grp = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  d.audit[#d.audit + 1] = {
    t = time(),
    zone = (GetRealZoneText and GetRealZoneText()) or (GetZoneText and GetZoneText()) or "?",
    src = src, out = out, n = count,
    grp = grp > 0 and grp or nil,
    del = deleted or nil,
  }
  while #d.audit > AUDIT_MAX do table.remove(d.audit, 1) end
end

local function noteLoot(msg)
  if GetTime() - lastDE > 3 then return end
  if not isSelfLoot(msg) then return end
  -- The colour escape is "|cff1eff00" on older clients and "|cnIQ2:" on 1.60;
  -- match whatever sits between "|c" and the link rather than assume hex.
  local link, count = msg:match("(|c[^|]*|Hitem:.-|h.-|h|r)%s*x?(%d*)")
  if not link then return end
  local itemID = tonumber(link:match("|Hitem:(%d+)"))
  local isMaterial = itemID and ENCHANT_MATERIAL[itemID]
  -- Future Classic branches may introduce new enchanting reagents. Preserve
  -- those without reopening attribution to arbitrary personal loot: WoW's
  -- numeric class/subclass for Enchanting trade goods is 7/12.
  if not isMaterial and GetItemInfoInstant then
    local ok, _, _, _, _, _, classID, subID = pcall(GetItemInfoInstant, link)
    isMaterial = ok and classID == 7 and subID == 12
  end
  if not isMaterial then return end
  local n = tonumber(count) or 1
  DE.tally[link] = (DE.tally[link] or 0) + n
  auditAppend(lastDESource, link, n)
  -- Yields are learned only from casts the window started and followed: the
  -- audit's fallback source can be a click from long ago.
  recordYield(lastDEOwn, itemID, n)
  -- A disenchant produces one material loot event. Close the transaction as
  -- soon as that event is accepted so a second personal loot line inside the
  -- old time window can never be attached to the completed cast.
  lastDE, lastDESource, lastDEOwn = 0, nil, nil
end

local pendingTrash

local function recordTrashDeletion(it)
  auditAppend(it.link, "deleted", it.count, true)
  pr(("deleted %s%s%s."):format(it.link,
    it.count > 1 and (" x" .. it.count) or "",
    it.vendor and it.vendor > 0 and (" — worth " .. money(it.vendor) .. " to a vendor") or ""))
end

local function finishPendingTrash()
  local p = pendingTrash
  if not p then return end
  local now = C.GetContainerItemInfo(p.bag, p.slot)
  if now and now.itemID == p.it.itemID and (now.stackCount or 1) == p.it.count
      and (not p.hyperlink or now.hyperlink == p.hyperlink)
      and (p.isBound == nil or now.isBound == p.isBound) then return end
  pendingTrash = nil
  recordTrashDeletion(p.it)
end

local function deleteTrash(it, bag, slot)
  local now = C.GetContainerItemInfo(bag, slot)
  if not (now and now.itemID == it.itemID and (now.stackCount or 1) == it.count
      and (not it.link or not now.hyperlink or now.hyperlink == it.link)
      and (it.isBound == nil or now.isBound == it.isBound)) then
    return false, "the bag slot changed"
  end
  ClearCursor()
  if not C.PickupContainerItem(bag, slot) then return false, "item pickup is unavailable" end
  if CursorHasItem and not CursorHasItem() then return false, "the item was not picked up" end
  if not DeleteCursorItem then ClearCursor(); return false, "deletion is unavailable" end
  pendingTrash = { it = it, bag = bag, slot = slot,
    hyperlink = now.hyperlink, isBound = now.isBound }
  DeleteCursorItem()

  -- Greys normally settle synchronously. Whites may open Blizzard's deletion
  -- confirmation; in that case BAG_UPDATE completes the audit only after the
  -- player accepts. A cancelled dialog therefore produces no success record.
  local after = C.GetContainerItemInfo(bag, slot)
  if not (after and after.itemID == it.itemID and (after.stackCount or 1) == it.count
      and (not pendingTrash.hyperlink or after.hyperlink == pendingTrash.hyperlink)
      and (pendingTrash.isBound == nil or after.isBound == pendingTrash.isBound)) then
    pendingTrash = nil
    auditAppend(it.link, "deleted", it.count, true)
    return true
  end
  local token = pendingTrash
  C_Timer.After(30, function() if pendingTrash == token then pendingTrash = nil end end)
  return nil, "waiting for the client confirmation"
end

function DE.Tally()
  local links = {}
  for link in pairs(DE.tally) do links[#links + 1] = link end
  if #links == 0 then pr("nothing disenchanted this session yet.") return end
  table.sort(links)
  pr("this session:")
  for _, link in ipairs(links) do
    print(("    %s x%d"):format(link, DE.tally[link]))
  end
end

--- /de yields [clear] — what your own disenchants have produced, per band.
function DE.Yields(args)
  local d = db()
  if (args or ""):lower() == "clear" then
    d.yields = {}
    pr("observed yields forgotten — estimates are back on book odds.")
    DE.Refresh()
    return
  end
  local keys = {}
  for key in pairs(d.yields) do keys[#keys + 1] = key end
  if #keys == 0 then
    pr("no yields recorded yet — they build up as you disenchant from the window.")
    return
  end
  table.sort(keys)
  pr(("your disenchant results (estimates use them from %d of a kind):"):format(YIELD_MIN))
  for _, key in ipairs(keys) do
    local seen = d.yields[key]
    local quality, top = math.floor(key / 1000), key % 1000
    local low = 1
    for _, band in ipairs(BANDS[quality] or {}) do
      if band[1] < top then low = band[1] + 1 end
    end
    local parts = {}
    for id, m in pairs(seen.mats) do
      parts[#parts + 1] = { id = id, text = ("%s %d%% (avg %.1f)"):format(
        (GetItemInfo(id)) or ("#" .. id), math.floor(m.h / seen.n * 100 + 0.5), m.q / m.h) }
    end
    table.sort(parts, function(a, b) return a.id < b.id end)
    for i, part in ipairs(parts) do parts[i] = part.text end
    print(("    %s%s|r i%d-%d |cff888888(%d)|r  %s"):format(qcolor(quality),
      QUALITY_NAME[quality] or "?", low, top, seen.n, table.concat(parts, ", ")))
  end
  print("    |cff888888/de yields clear forgets them.|r")
end

--- /de audit [n]  — the last n audit entries (default 20); /de audit clear.
function DE.Audit(args)
  local d = db()
  if args:lower() == "clear" then
    local n = #d.audit
    d.audit = {}
    pr(n == 0 and "the audit was already empty." or ("audit cleared — %d entr%s forgotten."):format(n, n == 1 and "y" or "ies"))
    return
  end
  if #d.audit == 0 then pr("no disenchants recorded yet.") return end
  local want = math.min(math.max(tonumber(args) or 20, 1), #d.audit)
  pr(("last %d of %d recorded disenchants:"):format(want, #d.audit))
  for i = #d.audit - want + 1, #d.audit do
    local e = d.audit[i]
    print(("    |cff888888%s  %s|r  %s%s%s%s"):format(
      date("%d %b %H:%M", e.t), e.zone or "?",
      e.src and (e.src .. " |cff888888→|r ") or "", e.out,
      e.n > 1 and (" x" .. e.n) or "",
      e.grp and ("  |cff888888group of " .. e.grp .. "|r") or ""))
  end
end

--- Materials produced since `since`, straight out of the audit: totals keyed
--- by output link, the order each first appeared, and how many loot lines
--- that covered. Trash-tab deletions are skipped — a destroyed grey is
--- nobody's shard. Shared by /de split and the window's Run Split tab, so the two
--- can never disagree.
---
--- Links embed your character level, so the same dust looted either side of a
--- level-up arrives as two different strings. Totals are grouped by item id
--- and shown under the first link seen.
local function runTotals(since)
  local totals, order, drops, firstLink = {}, {}, 0, {}
  for _, e in ipairs(db().audit) do
    if e.t >= since and not e.del then
      drops = drops + 1
      local id = e.out:match("item:(%d+)") or e.out
      local out = firstLink[id]
      if not out then
        out = e.out
        firstLink[id] = out
        order[#order + 1] = out
      end
      totals[out] = (totals[out] or 0) + e.n
    end
  end
  return totals, order, drops
end

--- What a run's materials would fetch at today's market prices.
--- @return copper (nil when nothing is priced), and whether every material was
local function runValue(totals, order)
  local sum, priced = 0, 0
  for _, out in ipairs(order) do
    local price = marketPrice(tonumber(out:match("item:(%d+)")))
    if price and price > 0 then
      sum = sum + price * totals[out]
      priced = priced + 1
    end
  end
  if priced == 0 then return nil end
  return sum, priced == #order
end

--- The group roster this moment — the loot master adjudicates mid-run leavers.
local function roster()
  local members = {}
  local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
  if n > 0 then
    if IsInRaid and IsInRaid() then
      for i = 1, n do members[#members + 1] = UnitName("raid" .. i) end
    else
      members[#members + 1] = UnitName("player")
      for i = 1, n - 1 do members[#members + 1] = UnitName("party" .. i) end
    end
  end
  return members
end

local RUN_HISTORY_MAX = 20

--- Freeze the current run into a compact summary independent of the capped
--- audit log. "Current run" is exactly what the Run Split tab is showing: from
--- the marker, or from login when no marker was ever set — otherwise the first
--- New run of a session would discard everything on screen. Returns false when
--- there are no material drops to save.
---
--- Callers must move the marker to now afterwards (startRun does), so the
--- same drops can never be archived a second time.
local function archiveCurrentRun(name)
  local d = db()
  local since = d.splitStart or sessionStart
  local totals, order, drops = runTotals(since)
  if drops == 0 then return false end
  local saved = { start = since, finish = time(), drops = drops,
    name = name or d.runName or ((GetRealZoneText and GetRealZoneText()) or "Run"),
    members = roster(), totals = {} }
  for _, out in ipairs(order) do
    saved.totals[#saved.totals + 1] = { out = out, n = totals[out] }
  end
  -- Worth at the moment it was archived; prices will have moved by the time
  -- anyone reads the History tab.
  local worth = runValue(totals, order)
  saved.value = worth and math.floor(worth + 0.5) or nil
  d.runs[#d.runs + 1] = saved
  while #d.runs > RUN_HISTORY_MAX do table.remove(d.runs, 1) end
  return true
end

--- Archive whatever the current run holds, then start counting from now.
--- @return true when a run was archived
local function startRun(name)
  local d = db()
  local archived = archiveCurrentRun()
  d.splitStart = time()
  d.runName = name and name ~= "" and name or nil
  return archived
end

function DE.RunHistory(args)
  local d = db()
  args = (args or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local op, value = args:match("^(%S+)%s*(.-)$")
  op = (op or ""):lower()
  if op == "name" then
    if value == "" then pr("usage: /de runs name <text>") return end
    d.runName = value
    pr("current run named |cffffd100" .. value .. "|r.")
    return
  elseif op == "end" then
    -- Ending leaves a fresh marker rather than none: with no marker the split
    -- falls back to "since login" and would show the archived drops again.
    if archiveCurrentRun() then
      d.splitStart, d.runName = time(), nil
      pr("run archived — it's on the History tab. Counting starts again from now.")
    else
      pr("the current run has no disenchant drops to archive.")
    end
    DE.Refresh()
    return
  elseif op == "clear" then
    local n = #d.runs
    d.runs = {}
    pr(n == 0 and "run history was already empty." or ("cleared %d archived run%s."):format(n, n == 1 and "" or "s"))
    DE.Refresh()
    return
  elseif args ~= "" then
    pr("usage: /de runs [name <text>|end|clear]")
    return
  end
  if #d.runs == 0 then pr("no archived runs yet.") return end
  pr(("archived runs (%d):"):format(#d.runs))
  for i = #d.runs, 1, -1 do
    local r = d.runs[i]
    print(("    %s  |cffffd100%s|r — %d drop%s, %d material type%s"):format(
      date("%d %b %H:%M", r.start), r.name or "Run", r.drops or 0,
      r.drops == 1 and "" or "s", #r.totals, #r.totals == 1 and "" or "s"))
  end
end

--- /de split [start|say|party|raid]
--- Totals the audit from the split marker (or login) and divides by the
--- current group. Printing to a chat channel only ever happens on the explicit
--- say/party/raid argument — the addon never speaks on its own.
function DE.Split(args)
  local d = db()
  args = args:lower()
  if args == "start" then
    local archived = startRun()
    pr((archived and "previous run archived; " or "")
      .. "split marker set — |cffffd100/de split|r now totals everything from this moment.")
    return
  end
  local channel = (args == "say" and "SAY")
    or (args == "raid" and "RAID")
    or (args == "party" and ((IsInRaid and IsInRaid()) and "RAID" or "PARTY"))
    or nil
  if args ~= "" and not channel then
    pr("usage: /de split [start|say|party|raid]")
    return
  end

  local since = d.splitStart or sessionStart
  local totals, order = runTotals(since)
  if #order == 0 then
    pr("nothing disenchanted since " .. (d.splitStart and "the split marker" or "login") .. ".")
    return
  end

  local members = roster()
  local lines = {}
  local k = #members
  lines[#lines + 1] = ("Shard split since %s%s:"):format(date("%H:%M", since),
    k > 1 and (" — " .. k .. " members") or " — not in a group, totals only")
  for _, out in ipairs(order) do
    local total = totals[out]
    if k > 1 then
      local each, spare = math.floor(total / k), total % k
      lines[#lines + 1] = ("%s x%d — %d each%s"):format(out, total, each,
        spare > 0 and (", " .. spare .. " spare") or "")
    else
      lines[#lines + 1] = ("%s x%d"):format(out, total)
    end
  end
  local worth, complete = runValue(totals, order)
  if worth then
    lines[#lines + 1] = ("Estimated value: %s%s%s"):format(plainMoney(worth),
      k > 1 and (" — about %s each"):format(plainMoney(worth / k)) or "",
      complete and "" or " (some materials unpriced)")
  end

  if channel then
    for _, line in ipairs(lines) do SendChatMessage(line, channel) end
  else
    pr(lines[1])
    for i = 2, #lines do print("    " .. lines[i]) end
    if k > 1 then print("    |cff888888/de split party announces this to the group.|r") end
  end
end

--------------------------------------------------------------------------------
-- Compact meter-style chrome shared with Summon. Disenchanter keeps taller
-- rows because its actions are destructive and each item needs a second line
-- for its yield or the reason it was held back.
--------------------------------------------------------------------------------
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local PLUS   = "Interface\\Buttons\\UI-PlusButton-Up"
local MINUS  = "Interface\\Buttons\\UI-MinusButton-Up"
local LOCKED   = "Interface\\Buttons\\LockButton-Locked-Up"
local UNLOCKED = "Interface\\Buttons\\LockButton-Unlocked-Up"

local function backdrop(f, alpha)
  f:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  f:SetBackdropColor(0, 0, 0, alpha or 0.45)
  f:SetBackdropBorderColor(0.5, 0.5, 0.5)
end

local function tipHide() GameTooltip:Hide() end

--------------------------------------------------------------------------------
-- The window. Three collapsible buckets; each item row is a secure button
-- carrying the disenchant macro for exactly that bag slot.
--
-- Arming a row means SetAttribute, which Blizzard forbids in combat — so in
-- combat the list greys out and stops updating, and PLAYER_REGEN_ENABLED
-- rebuilds it. You can't disenchant in combat anyway.
--------------------------------------------------------------------------------
local win
local pendingToggle, pendingTab, pendingShow = false, nil, false
local WIN_W, WIN_H = 410, 460
local MIN_W, MIN_H = 380, 420 -- wide enough for the footer: buttons, filter, Next
local MAX_W, MAX_H = 620, 760
local ROW_W  = 372 -- initial width; resized rows are anchored to both edges
local ROW_H  = 28
local HEAD_H = 18

local function rowWidth()
  if win and win.content and win.content.GetWidth then
    local w = win.content:GetWidth()
    if type(w) == "number" and w > 1 then return w end
  end
  return ROW_W
end

local BUCKETS = {
  { key = "safe",    title = "SAFE TO DISENCHANT", color = "|cff55c96b" },
  { key = "confirm", title = "REVIEW FIRST",       color = "|cffd7ad45" },
  { key = "blocked", title = "PROTECTED",          color = "|cffb96a6a" },
}

-- The Trash tab's buckets. `key` picks the list out of the scan; `col` keeps
-- its collapse state separate from the disenchant tab's.
local TRASH_BUCKETS = {
  { key = "safe",    col = "tsafe",    title = "JUNK · CLICK TO DELETE", color = "|cff55c96b" },
  { key = "confirm", col = "tconfirm", title = "REVIEW FIRST",           color = "|cffd7ad45" },
  { key = "blocked", col = "tblocked", title = "PROTECTED",              color = "|cffb96a6a" },
}

local function isCollapsed(key) return db().collapsed[key] == true end

-- SecureButton_GetModifiedAttribute looks up "<modifier>type<button>" and falls
-- back through progressively less specific names — but which string it uses for
-- <button> ("", "1" or "LeftButton") has moved around between client versions.
-- Writing all three costs nothing and takes the guesswork out of it.
-- Left-click only. Deliberately no unsuffixed ("type") variant: the rows are
-- registered for any button so the secure handler sees the down event, and a
-- bare "type" would answer a right-click too.
local CLICK_SUFFIX = { "1", "LeftButton" }

local function setAction(row, prefix, atype, value, bag, slot)
  for _, sfx in ipairs(CLICK_SUFFIX) do
    row:SetAttribute(prefix .. "type" .. sfx, atype)
    row:SetAttribute(prefix .. "macrotext" .. sfx, atype == "macro" and value or nil)
    row:SetAttribute(prefix .. "spell" .. sfx, atype == "spell" and value or nil)
    row:SetAttribute(prefix .. "target-bag" .. sfx, bag)
    row:SetAttribute(prefix .. "target-slot" .. sfx, slot)
  end
end

--- Point a row at a bag slot, or at nothing. `tier` decides which click fires
--- it: safe rows take a plain left-click, "check first" rows only fire with
--- Ctrl held, protected rows are never armed at all.
---
--- The Ctrl gate works by only ever writing "ctrl-"-prefixed attributes: with no
--- modifier held the lookup finds nothing and the click is a genuine no-op.
---
--- The action only ever casts Disenchant. It deliberately does NOT carry a
--- `/use <bag> <slot>` line: a macro doesn't stop when `/cast` fails, so on a
--- character without Disenchant (or mid-cast, or dead) that line would run on
--- its own and equip the item — or sell it to an open vendor, attach it to an
--- open mail, or drop it into a trade. Instead the item goes in the button's
--- `target-bag` / `target-slot` attributes. Blizzard's secure handler reads
--- those after the action and applies the spell with UseContainerItem only if
--- SpellCanTargetItem() — i.e. only if the cast actually put Disenchant on the
--- cursor (SecureTemplates.lua, OnActionButtonClick). Same protection as the
--- default bag UI, all inside secure code; a failed cast touches nothing.
--- (UseContainerItem is protected on this client, so it can't be done from
--- PostClick — that just raises the "blocked from an action" popup.)
---
--- Two ways to issue the cast, swappable with /de mode:
---   "macro" (default) — a `/cast [nocombat] Disenchant` macrotext. A
---     secure button can't be disarmed once lockdown starts, so a row or the
---     Next button can sit armed at a slot whose contents then change; the
---     condition makes the macro itself refuse for as long as combat lasts.
---   "spell"           — the `spell` attribute. Kept in case a patch breaks
---     macrotext. It can't carry a condition, so in combat it relies on the
---     game refusing the cast.
local function arm(row, tier, bag, slot)
  setAction(row, "", nil, nil, nil, nil)
  setAction(row, "ctrl-", nil, nil, nil, nil)
  row.cancelCast = nil
  row.deBag, row.deSlot, row.deTier = nil, nil, nil
  row.trashBag, row.trashSlot = nil, nil
  if not (bag and slot and tier ~= "blocked") then return end
  local prefix = (tier == "safe") and "" or "ctrl-"
  if db().clickMode == "macro" then
    setAction(row, prefix, "macro", "/cast [nocombat] " .. deName(), bag, slot)
  else
    setAction(row, prefix, "spell", deName(), bag, slot)
  end
  row.deBag, row.deSlot, row.deTier = bag, slot, tier
end

--- While this row's item is actively being disenchanted, turn the same row
--- into a cancel button. `/stopcasting` remains a secure, hardware-triggered
--- action; no ordinary Lua handler attempts to stop a protected cast. It has
--- no item target attributes, so the cancelling click cannot touch a bag slot.
local function armCancel(row)
  arm(row, "blocked")
  setAction(row, "", "macro", "/stopcasting", nil, nil)
  row.cancelCast = true
end

--- Trash rows carry no secure action at all — deleting an item isn't a
--- protected call, so the plain PostClick handler does the whole job. arm()
--- runs first to strip any disenchant macro the row kept from the other tab,
--- and to clear the trash fields on a disarm.
local function armTrash(row, tier, bag, slot)
  arm(row, "blocked")
  if tier ~= "blocked" then row.trashBag, row.trashSlot = bag, slot end
end

--- Disarm every row, and the Next button, right now. Called the instant bags
--- change, so nothing can fire at whatever slid into a slot before the
--- rebuild lands.
local function disarmAll()
  if not win or InCombatLockdown() then return end
  for _, row in ipairs(win.rows) do arm(row, "blocked") end
  if win.next then arm(win.next, "blocked"); win.next.item = nil end
end

-- Row order is held while the window stays open, so a rebuild never slides a
-- different item under the cursor: rows keep the position they were first
-- shown at and anything new joins the bottom of its section. Each item key is
-- ranked the first time it is seen; DE.Resort forgets the ranks, which puts
-- the list back in scan order (cheapest first). Ranks outlive a row, so an
-- item that drops out for a moment — locked mid-move — returns to its place.
local listOrder = {}
local function byHeldOrder(a, b)
  if a.rank ~= b.rank then return a.rank < b.rank end
  return a.scanIdx < b.scanIdx
end
local function holdOrder(tab, ...)
  local o = listOrder[tab]
  if not o then o = { n = 0, rank = {} }; listOrder[tab] = o end
  for li = 1, select("#", ...) do
    local list = select(li, ...)
    for i, it in ipairs(list) do
      local k = keyOf(it)
      if not o.rank[k] then o.n = o.n + 1; o.rank[k] = o.n end
      it.rank, it.scanIdx = o.rank[k], i
    end
    table.sort(list, byHeldOrder)
  end
end

--------------------------------------------------------------------------------
-- Small building blocks shared by every tab.
--------------------------------------------------------------------------------
local function simpleTip(frame, title, body, anchor)
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    if body then GameTooltip:AddLine(body, 0.6, 0.6, 0.6, true) end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", tipHide)
end

--- A flat button drawn to match the tabs, instead of Blizzard's red panel
--- button. A real Button with a font string, so SetText / SetEnabled behave.
local function flatButton(parent, label, w, h)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h or 22)
  b.edge = b:CreateTexture(nil, "BACKGROUND")
  b.edge:SetAllPoints()
  b.edge:SetColorTexture(0.26, 0.28, 0.33, 1)
  b.bg = b:CreateTexture(nil, "BORDER")
  b.bg:SetPoint("TOPLEFT", 1, -1)
  b.bg:SetPoint("BOTTOMRIGHT", -1, 1)
  b.bg:SetColorTexture(0.11, 0.12, 0.15, 1)
  local hover = b:CreateTexture(nil, "HIGHLIGHT")
  hover:SetAllPoints(b.bg)
  hover:SetColorTexture(1, 1, 1, 0.09)
  b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  b.text:SetPoint("CENTER", 0, 0)
  b:SetFontString(b.text)
  b:SetNormalFontObject("GameFontHighlightSmall")
  b:SetDisabledFontObject("GameFontDisableSmall")
  b:SetText(label)
  return b
end

--------------------------------------------------------------------------------
-- The Next button and its key. One secure button, parked in the footer where
-- it never moves, always pointed at the top row of "Safe to disenchant" — the
-- same item, the same macro and the same target-bag/-slot as that row. A key
-- can be bound to it, but only as an override binding that exists while the
-- window is open on the Disenchant tab: close the window and the key is its
-- old self again. Still one hardware event per cast, and never a Check first
-- or Protected item — those keep their Ctrl-click and their dead rows.
--------------------------------------------------------------------------------
local KEY_SHORT = {
  MOUSEWHEELUP = "Wheel Up", MOUSEWHEELDOWN = "Wheel Down",
  BUTTON3 = "Mouse 3", BUTTON4 = "Mouse 4", BUTTON5 = "Mouse 5",
}
-- BUTTON1/2 are the mouse itself: an override on the right button leaves the
-- 1.60 client's cursor hidden until restart. Escape and Enter belong to the UI.
local BAD_KEY = { BUTTON1 = true, BUTTON2 = true, ESCAPE = true, ENTER = true, UNKNOWN = true }

-- The button has room for a short badge only; anything long is left to the
-- tooltip and Settings.
local KEY_BADGE = {
  MOUSEWHEELUP = "WhlUp", MOUSEWHEELDOWN = "WhlDn",
  BUTTON3 = "M3", BUTTON4 = "M4", BUTTON5 = "M5",
}

local function keyLabel(key) return key and (KEY_SHORT[key] or key) or nil end

local keyDirty = false
local function applyNextKey()
  if not win then return end
  -- Bindings can't change in combat; PLAYER_REGEN_ENABLED comes back here.
  if InCombatLockdown() then keyDirty = true return end
  keyDirty = false
  if ClearOverrideBindings then ClearOverrideBindings(win) end
  local key = db().nextKey
  -- IsVisible, not IsShown: with the whole UI hidden (Alt-Z, a cinematic) the
  -- window still counts as shown, and a key that disenchants unseen items is
  -- exactly what this must never be.
  if key and SetOverrideBindingClick and win:IsVisible() and win.tab == "de" then
    SetOverrideBindingClick(win, true, key, "DisenchanterNextButton", "LeftButton")
  end
end

--- Point the Next button at an item, or at nothing. Anything but the
--- Disenchant tab of a visible window gets nothing.
local function syncNext(it)
  local nb = win and win.next
  if not nb or InCombatLockdown() then return end -- SetAttribute / Show are protected
  nb:SetShown(win.tab == "de")
  if not (win:IsVisible() and win.tab == "de") then it = nil end
  nb.item = it
  if it then arm(nb, "safe", it.bag, it.slot) else arm(nb, "blocked") end
  local key = KEY_BADGE[db().nextKey or ""] or db().nextKey
  local label
  if it then
    label = "Disenchant next" .. ((key and #key <= 6) and ("  |cffd9c2f5[" .. key .. "]|r") or "")
  elseif DE.cast then
    label = "Disenchanting..."
  elseif not knowsDisenchant() then
    label = "Can't disenchant"
  else
    label = "Nothing safe"
  end
  nb.text:SetText(label)
  nb.text:SetTextColor(it and 1 or 0.5, it and 1 or 0.5, it and 1 or 0.52)
  nb.bg:SetColorTexture(it and 0.34 or 0.11, it and 0.15 or 0.12, it and 0.50 or 0.15, 1)
  nb.edge:SetColorTexture(it and 0.62 or 0.26, it and 0.36 or 0.28, it and 0.86 or 0.33, 1)
end

--- /de key, and the Settings key button. `key` is a single key name with no
--- modifier: the Next button only carries a plain-click action, so a
--- modified press would find nothing to do.
function DE.SetNextKey(key)
  key = tostring(key or ""):upper()
  key = key:gsub("%s+", "")
  if key == "" or key == "NONE" or key == "OFF" or key == "CLEAR" then
    db().nextKey = nil
    pr("next-item key cleared.")
  elseif BAD_KEY[key] or (#key > 1 and key:find("-", 1, true)) then
    pr(("|cffffd100%s|r can't be the next-item key — use one key with no modifier, or the mouse wheel / buttons 3-5."):format(key))
    return
  else
    db().nextKey = key
    pr(("next-item key is |cffffd100%s|r: while the window is on the Disenchant tab it disenchants the top Safe row."):format(keyLabel(key)))
  end
  applyNextKey()
  DE.Refresh()
end

--- Switch this character between the account's guard settings and its own.
--- The first switch starts from a copy of the account's, so nothing changes
--- at the moment of switching; later ones return to what the character had.
function DE.SetCharSettings(on)
  local c, d = DB.GetChar(GUARDS), db()
  if on and type(c.guards) ~= "table" then
    c.guards = {}
    for key, value in pairs(d.guards) do c.guards[key] = value end
    c.confirmAbove, c.valueGold, c.ilvlCap, c.lossSilver = d.confirmAbove, d.valueGold, d.ilvlCap, d.lossSilver
  end
  c.own = on and true or false
  if c.own then DB.RepairSettings(c, GUARDS) end
  pr(c.own and "this character now has its own guards and thresholds. The keep list is still shared."
    or "this character is back on the account's guards and thresholds.")
  DE.Refresh()
end

--------------------------------------------------------------------------------
-- Rows.
--------------------------------------------------------------------------------
local function headerRow(i)
  local row = win.heads[i]
  if row then return row end
  row = CreateFrame("Button", nil, win.content)
  row:SetHeight(HEAD_H)
  row:SetPoint("RIGHT", win.content, "RIGHT", 0, 0)
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  row.bg:SetColorTexture(0.12, 0.12, 0.14, 0.92)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.toggle = row:CreateTexture(nil, "ARTWORK")
  row.toggle:SetSize(14, 14)
  row.toggle:SetPoint("LEFT", 0, 0)
  -- What the section adds up to, where there is something to add up.
  row.right = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.right:SetPoint("RIGHT", -6, 0)
  -- The title gives way to it: a long run name truncates instead of colliding.
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.text:SetPoint("LEFT", row.toggle, "RIGHT", 4, 0)
  row.text:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWordWrap(false)
  row:SetScript("OnClick", function(self)
    local col = db().collapsed
    col[self.key] = not col[self.key]
    DE.Refresh()
  end)
  win.heads[i] = row
  return row
end

local function placeHead(hi, y, key, text, right)
  local head = headerRow(hi)
  head.key = key
  head.toggle:SetTexture(isCollapsed(key) and PLUS or MINUS)
  head.text:SetText(text)
  head.right:SetText(right or "")
  head:ClearAllPoints()
  head:SetPoint("TOPLEFT", 0, y)
  head:SetPoint("TOPRIGHT", 0, y)
  head:Show()
  return y - HEAD_H
end

-- PreClick can't cancel a secure action, but it can tell us what we were
-- aiming at — which is what turns "Item cannot be disenchanted" into a
-- permanent note against that item id, and what the cast bar follows. Shared
-- by the rows and the Next button.
local function notePending(self, button)
  local it = self.item
  if DE.trace then
    pr(("PRE  button=%s ctrl=%s item=%s tier=%s type=%s"):format(
      tostring(button), tostring(IsControlKeyDown()),
      it and it.link or "nil", it and it.tier or "nil",
      tostring(self:GetAttribute("type"))))
  end
  if self.cancelCast or not (it and it.bag) then return end
  local now = C.GetContainerItemInfo(it.bag, it.slot)
  DE._pending = (now and now.itemID == it.itemID) and it or nil
  DE._pendingAt = GetTime()
end

local TEXT_LEFT = 34   -- past the icon
local LOCK_PAD  = 26   -- the padlock and its margins
local VALUE_COL = 72   -- the right-hand figure column, when a row has one

--- Lay out a row's text against whatever sits on its right: `pad` is the
--- width taken by the padlock / Allow button, `column` whether the value
--- column is in use. Regions only — safe to call on a secure row.
local function rowInsets(row, pad, column)
  row.value:ClearAllPoints()
  row.value:SetPoint("TOPRIGHT", -pad, -4)
  row.tag:ClearAllPoints()
  row.tag:SetPoint("TOPRIGHT", -pad, -16)
  local inset = pad + (column and VALUE_COL or 0) + 4
  row.name:ClearAllPoints()
  row.name:SetPoint("TOPLEFT", TEXT_LEFT, -4)
  row.name:SetPoint("TOPRIGHT", -inset, -4)
  row.note:ClearAllPoints()
  row.note:SetPoint("TOPLEFT", TEXT_LEFT, -16)
  row.note:SetPoint("TOPRIGHT", -inset, -16)
end

local function itemRow(i)
  local row = win.rows[i]
  if row then return row end
  row = CreateFrame("Button", "DisenchanterRow" .. i, win.content, "SecureActionButtonTemplate")
  row:SetHeight(ROW_H)
  row:SetPoint("RIGHT", win.content, "RIGHT", 0, 0)
  -- Both edges, not just "LeftButtonUp". This client's secure handler acts on
  -- whichever edge ActionButtonUseKeyDown selects and returns silently on the
  -- other, so registering one edge can leave the button doing nothing at all.
  -- Every working secure button ships this way (Leatrix_Plus, Broker_Everything).
  row:RegisterForClicks("AnyUp", "AnyDown")
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()

  row.state = row:CreateTexture(nil, "BORDER")
  row.state:SetPoint("TOPLEFT", 0, -1)
  row.state:SetPoint("BOTTOMLEFT", 0, 1)
  row.state:SetWidth(3)

  -- The in-row cast bar: a translucent fill that sweeps across the row while
  -- your Disenchant is casting on its item. BACKGROUND layer, so the icon and
  -- text stay readable on top of it.
  row.castFill = row:CreateTexture(nil, "BACKGROUND")
  row.castFill:SetPoint("TOPLEFT")
  row.castFill:SetPoint("BOTTOMLEFT")
  row.castFill:SetColorTexture(0.64, 0.21, 0.93, 0.35)
  row.castFill:SetWidth(1)
  row.castFill:Hide()

  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(22, 22)
  row.icon:SetPoint("LEFT", 7, 0)
  row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- shave the icon's baked border

  -- The padlock: closed means the item is on your keep list forever, open means
  -- click to put it there. Blocked-by-a-guard rows also get an Allow button.
  row.lock = CreateFrame("Button", nil, row)
  row.lock:SetSize(16, 16)
  row.lock:SetPoint("RIGHT", -6, 0)
  row.lock:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  row.lock:SetScript("OnClick", function(self)
    local it = self:GetParent().item
    if not it then return end
    DE.ToggleKeep(it)
  end)
  row.lock:SetScript("OnEnter", function(self)
    local it = self:GetParent().item
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(it and keptAs(it)
      and "On your keep list — click to remove"
      or "Click to never disenchant this item", 1, 1, 1)
    GameTooltip:Show()
  end)
  row.lock:SetScript("OnLeave", tipHide)

  row.allow = flatButton(row, "Allow", 46, 18)
  row.allow:SetPoint("RIGHT", row.lock, "LEFT", -3, 0)
  row.allow:SetScript("OnClick", function(self)
    local it = self:GetParent().item
    if not it then return end
    if allowed[keyOf(it)] then
      allowed[keyOf(it)] = nil
      pr(("%s is protected by its guards again."):format(it.link))
    else
      allowed[keyOf(it)] = true
      pr(("%s allowed for this session — Ctrl-click to %s it."):format(it.link,
        it.trash and "delete" or "disenchant"))
    end
    DE.Refresh()
  end)
  row.allow:SetScript("OnEnter", function(self)
    local it = self:GetParent().item
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(it and allowed[keyOf(it)]
      and "Restore guard protection" or "Ignore the guard for this session", 1, 1, 1)
    GameTooltip:AddLine(it and allowed[keyOf(it)]
      and "Undo the session override and apply all guards again."
      or (("The row moves to Check first; a Ctrl-click will then %s it. Forgotten on logout.")
        :format(it and it.trash and "delete" or "disenchant")), 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  row.allow:SetScript("OnLeave", tipHide)

  -- Two lines of text on the left, and a figure column on the right: what the
  -- row is worth on top, and under it the "next" marker for the Next button.
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)
  row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.note:SetJustifyH("LEFT")
  row.note:SetWordWrap(false)
  row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.value:SetJustifyH("RIGHT")
  row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.tag:SetJustifyH("RIGHT")
  rowInsets(row, LOCK_PAD, false)

  row:SetScript("OnEnter", function(self)
    local it = self.item
    if not it then return end
    -- Run-tab rows describe an audit entry, not a bag slot: the only tooltip
    -- that makes sense is the material itself.
    if it.run then
      if it.runLink then
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetHyperlink(it.runLink)
        GameTooltip:Show()
      end
      return
    end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    -- This tooltip says everything the item-tooltip hook would, and more.
    tipQuiet = true
    GameTooltip:SetBagItem(it.bag, it.slot)
    tipQuiet = false
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(("Bag %d, slot %d"):format(it.bag, it.slot), 0.55, 0.55, 0.55)
    if it.yield then GameTooltip:AddLine("Disenchants into: " .. it.yield, 0.6, 0.85, 1, true) end
    if it.value then
      GameTooltip:AddLine(("Worth %s%s"):format(money(it.value),
        it.valueSrc == "ah" and " on the AH" or " to a vendor"), 0.9, 0.9, 0.6)
    end
    if it.deValue then
      GameTooltip:AddLine(("Estimated disenchant value: %s"):format(money(it.deValue)), 0.55, 0.85, 1)
      GameTooltip:AddLine(it.deSeen
        and ("Based on your own %d disenchants of this kind, at current Auctionator/TSM prices."):format(it.deSeen)
        or "Uses current Auctionator/TSM material prices and approximate drop odds.",
        0.55, 0.55, 0.55, true)
    end
    if it.casting then
      GameTooltip:AddLine("Click again to cancel this disenchant.", 0.75, 0.5, 1)
    elseif it.tier == "blocked" then
      GameTooltip:AddLine("Protected: " .. (it.reason or "?"), 1, 0.4, 0.4, true)
      GameTooltip:AddLine(it.permanent and "Use the padlock to take it off your keep list."
        or "Press Allow to override for this session.", 0.6, 0.6, 0.6, true)
    elseif it.trash then
      if it.tier == "safe" then
        GameTooltip:AddLine("Click to delete it — gone for good.", 1, 0.4, 0.4)
      else
        GameTooltip:AddLine("Held back: " .. (it.reason or "?"), 1, 0.82, 0)
        GameTooltip:AddLine("Ctrl-click to delete it anyway — gone for good.", 1, 0.82, 0)
      end
    elseif it.tier == "safe" then
      GameTooltip:AddLine("Click to disenchant.", 0.4, 1, 0.4)
    else
      GameTooltip:AddLine("Held back: " .. (it.reason or "?"), 1, 0.82, 0)
      GameTooltip:AddLine("Ctrl-click to disenchant anyway.", 1, 0.82, 0)
    end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", tipHide)

  row:SetScript("PreClick", notePending)

  -- PostClick runs straight after the secure handler. The Trash tab's delete
  -- lives here; the disenchant tab has nothing left to do by this point — the
  -- secure handler both cast the spell and applied it via target-bag/-slot —
  -- so for those rows this only feeds the click trace.
  row:SetScript("PostClick", function(self, button, down)
    -- The Trash tab's whole action lives here — deletion isn't a protected
    -- call, so no secure attributes are involved. Left-button release only,
    -- and the slot is re-read at the last instant, so the click can only ever
    -- destroy the exact item the row was showing.
    if self.trashBag then
      local it = self.item
      if down or button ~= "LeftButton" or not (it and it.trash) then return end
      if it.tier ~= "safe" and not IsControlKeyDown() then return end
      local ok, why = deleteTrash(it, self.trashBag, self.trashSlot)
      if ok == false then
        pr(("did not delete %s — %s. Rescan and try again."):format(it.link, why))
        return
      end
      if ok == nil then
        pr(("confirm deletion of %s in the client dialog."):format(it.link))
        return
      end
      pr(("deleted %s%s%s."):format(it.link,
        it.count > 1 and (" x" .. it.count) or "",
        it.vendor > 0 and (" — worth " .. money(it.vendor) .. " to a vendor") or ""))
      return
    end
    -- Disenchant rows: nothing to do. Deliberately no UseContainerItem here —
    -- it's protected, and calling it from this insecure handler only raises
    -- the "blocked from an action" popup. If the trace shows Disenchant still
    -- on the cursor after the acting edge, the target-bag/-slot attributes
    -- didn't land on this row.
    if DE.trace then
      pr(("POST mode=%s down=%s targeting=%s"):format(
        db().clickMode or "macro", tostring(down),
        tostring(SpellIsTargeting and SpellIsTargeting())))
    end
  end)

  win.rows[i] = row
  return row
end

local function iconOf(link)
  if not (link and GetItemInfoInstant) then return nil end
  local ok, icon = pcall(function() return select(5, GetItemInfoInstant(link)) end)
  return ok and icon or nil
end

--- A read-only row for the Run Split and History tabs: an icon, two lines and
--- an optional figure. Never armed.
local function placeInfo(ri, y, tint, link, nameText, noteText, valueText, icon)
  local row = itemRow(ri)
  row.item = { run = true, runLink = link }
  row.bg:SetColorTexture(0.055, 0.06, 0.07, ri % 2 == 0 and 0.88 or 0.72)
  row.state:SetColorTexture(tint[1], tint[2], tint[3], 0.85)
  row.icon:SetTexture(icon or iconOf(link) or FALLBACK_ICON)
  row.icon:SetDesaturated(false)
  row.name:SetText(nameText)
  row.note:SetText(noteText or "")
  row.value:SetText(valueText or "")
  row.tag:SetText("")
  rowInsets(row, 6, (valueText or "") ~= "")
  row.castFill:Hide()
  row.lock:Hide()
  row.allow:Hide()
  arm(row, "blocked")
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", 0, y)
  row:SetPoint("TOPRIGHT", 0, y)
  row:Show()
  return y - ROW_H
end

--- Hide and disarm whatever a shorter list no longer uses.
local function hideRest(hi, ri)
  for i = hi + 1, #win.heads do win.heads[i]:Hide() end
  for i = ri + 1, #win.rows do
    arm(win.rows[i], "blocked")
    win.rows[i].item = nil
    win.rows[i]:Hide()
  end
end

local function statusText(safe, confirm, blocked)
  if InCombatLockdown() then
    return "|cffff5555In combat|r — the list is frozen until you leave it."
  end
  local skill = enchantingSkill()
  if not knowsDisenchant() then
    return ("|cff33cc44%d safe|r, |cffffd100%d to check|r, |cffff5555%d protected|r   |cffff5555no Disenchant on this character|r")
      :format(#safe, #confirm, #blocked)
  end
  return ("|cff33cc44%d safe|r, |cffffd100%d to check|r, |cffff5555%d protected|r%s")
    :format(#safe, #confirm, #blocked, skill and ("   |cff888888Enchanting " .. skill .. "|r") or "")
end

local function profitText(profit)
  if not profit then return "" end
  return (profit >= 0 and "|cff55bb66+" or "|cffff6666-") .. shortMoney(math.abs(profit)) .. "|r"
end

function DE.Refresh()
  tipIndex = nil -- whatever prompted this may have changed a verdict
  -- Visible, not just shown: nothing is armed while the UI itself is hidden.
  -- OnShow redraws when it comes back.
  if not (win and win:IsVisible()) then return end
  if win.tab == "options" then
    DE.RefreshOptions()
    win.status:SetText("Settings" .. (DB.GetChar(GUARDS).own
      and "   |cff888888this character's own guards|r" or ""))
    win.hint:SetText("Choose what is protected and what requires confirmation.")
    syncNext(nil)
    return
  end
  if InCombatLockdown() then
    win.content:SetAlpha(0.35) -- visibly frozen; SetAlpha is fine in lockdown
    win.status:SetText(statusText({}, {}, {}))
    return -- SetAttribute is forbidden in combat; PLAYER_REGEN_ENABLED redraws
  end
  win.content:SetAlpha(1)
  if win.tab == "split" then syncNext(nil); return DE.RefreshSplit() end
  if win.tab == "history" then syncNext(nil); return DE.RefreshHistory() end
  local trash = win.tab == "trash"
  local safe, confirm, blocked
  if trash then
    safe, confirm, blocked = DE.ScanTrash()
  else
    safe, confirm, blocked = DE.Scan()
  end
  holdOrder(trash and "trash" or "disenchant", safe, confirm, blocked)
  if filterText ~= "" then
    local needle = filterText:lower()
    local function filter(list)
      for i = #list, 1, -1 do
        local it = list[i]
        if not ((it.name or ""):lower():find(needle, 1, true)
            or (it.reason or ""):lower():find(needle, 1, true)) then
          table.remove(list, i)
        end
      end
    end
    filter(safe); filter(confirm); filter(blocked)
  end
  local lists = { safe = safe, confirm = confirm, blocked = blocked }

  win.hint:SetText(trash
    and "Click a row to delete it forever — Ctrl-click a white item."
    or "Click a green row to disenchant it — Ctrl-click an amber one.")
  win.empty:SetText(filterText ~= "" and ("No items match “" .. filterText .. "”")
    or (trash and "No junk in your bags" or "Nothing disenchantable in your bags"))

  win.castingRow = nil
  -- Without Disenchant a row has nothing safe to do: leave it unarmed rather
  -- than let a click raise "You don't know that spell" against the item.
  local canCast = trash or knowsDisenchant()
  -- What the Next button fires: the top Safe row, when it is on screen and
  -- nothing is mid-cast. What you can't see, the button can't touch.
  local nextIt = (not trash and canCast and not DE.cast and not isCollapsed("safe"))
    and safe[1] or nil
  local hi, ri, y = 0, 0, 0
  for _, b in ipairs(trash and TRASH_BUCKETS or BUCKETS) do
    local list = lists[b.key]
    local ck = b.col or b.key
    local sum = 0
    if b.key ~= "blocked" then
      for _, it in ipairs(list) do sum = sum + ((trash and it.vendor or it.deValue) or 0) end
    end
    hi = hi + 1
    y = placeHead(hi, y, ck, ("%s%s|r  |cff888888(%d)|r"):format(b.color, b.title, #list),
      sum > 0 and ((trash and "forfeits " or "materials ~") .. shortMoney(sum)) or "")

    if not isCollapsed(ck) then
      for _, it in ipairs(list) do
        ri = ri + 1
        local row = itemRow(ri)
        row.item = it
        row.bg:SetColorTexture(0.055, 0.06, 0.07, ri % 2 == 0 and 0.88 or 0.72)
        if it.tier == "safe" then
          row.state:SetColorTexture(0.25, 0.72, 0.38, 0.95)
        elseif it.tier == "confirm" then
          row.state:SetColorTexture(0.86, 0.62, 0.18, 0.95)
        else
          row.state:SetColorTexture(0.62, 0.32, 0.32, 0.80)
        end
        row.icon:SetTexture(it.icon or FALLBACK_ICON)
        row.icon:SetDesaturated(it.tier == "blocked")

        local figure = ""
        if trash then
          -- The figure is the sort key, and what deleting the row costs you.
          row.name:SetText(("%s%s|r%s"):format(qcolor(it.quality), it.name,
            it.count > 1 and (" x" .. it.count) or ""))
          if it.tier ~= "blocked" and it.vendor > 0 then
            figure = "|cffd0c080" .. shortMoney(it.vendor) .. "|r"
          end
          if it.tier == "safe" then
            row.note:SetText(it.vendor > 0 and "|cff777777click to delete — gone for good|r"
              or "|cff777777worthless — click to delete|r")
          else
            row.note:SetText((it.tier == "confirm" and "|cffbfa640Ctrl-click: " or "|cffbf5555")
              .. (it.reason or "") .. "|r")
          end
        else
          row.name:SetText(("%s%s|r%s  |cff888888i%d|r"):format(
            qcolor(it.quality), it.name, it.count > 1 and (" x" .. it.count) or "", it.ilvl))
          if it.tier ~= "blocked" then figure = profitText(it.profit) end
          if it.casting then
            row.note:SetText("|cffb37ce8Disenchanting... click again to cancel|r")
          elseif it.tier == "safe" then
            row.note:SetText("|cff777777" .. (it.yield or "") .. "|r")
          else
            row.note:SetText((it.tier == "confirm" and "|cffbfa640Ctrl-click: " or "|cffbf5555")
              .. (it.reason or "") .. "|r")
          end
        end
        local tag = (it == nextIt) and "|cffb37ce8next|r" or ""
        row.value:SetText(figure)
        row.tag:SetText(tag)

        row.castFill:SetShown(it.casting and true or false)
        if it.casting then win.castingRow = row end
        row.lock:Show() -- the Run Split and History tabs hide it
        row.lock:SetNormalTexture(keptAs(it) and LOCKED or UNLOCKED)
        local override = allowed[keyOf(it)]
        local showAllow = (it.tier == "blocked" and not it.permanent) or override
        local allowW = override and 54 or 46
        row.allow:SetText(override and "Restore" or "Allow")
        row.allow:SetWidth(allowW)
        row.allow:SetShown(showAllow and true or false)
        rowInsets(row, LOCK_PAD + (showAllow and (allowW + 5) or 0), figure ~= "" or tag ~= "")

        if trash then
          armTrash(row, it.tier, it.bag, it.slot)
        else
          if it.casting then
            armCancel(row)
          else
            arm(row, not canCast and "blocked" or it.tier, it.bag, it.slot)
          end
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, y)
        row:SetPoint("TOPRIGHT", 0, y)
        row:Show()
        y = y - ROW_H
      end
    end
  end
  hideRest(hi, ri)
  win.content:SetHeight(math.max(-y, 1))
  win.empty:SetShown(#safe + #confirm + #blocked == 0)
  win.status:SetText(statusText(safe, confirm, blocked))
  syncNext(nextIt)
  if win.opts and win.opts:IsShown() then DE.RefreshOptions() end
  -- The broker always shows disenchant counts; on the trash tab it rescans.
  if trash or filterText ~= "" then DE.UpdateBroker() else DE.UpdateBroker(#safe, #confirm) end
end

--- Rebuild in scan order, dropping the held row order. For moments the user
--- asked for a fresh list — opening the window, switching tab, Rescan, a sort
--- change — never for a bag event.
function DE.Resort()
  listOrder = {}
  DE.Refresh()
end

--------------------------------------------------------------------------------
-- The Run Split tab: the live audit-backed material inventory. Everything shown is
-- since the run marker (or login), so the shards you walked in with never
-- appear — the numbers come from the audit log, not from your bags.
--------------------------------------------------------------------------------
local RUN_LOG_MAX = 40 -- rows drawn; the header still counts everything
local SPLIT_TINT, HISTORY_TINT = { 0.32, 0.48, 0.68 }, { 0.50, 0.36, 0.65 }
local NOTE_ICON = "Interface\\Icons\\INV_Misc_Note_01"

function DE.RefreshSplit()
  local d = db()
  local since = d.splitStart or sessionStart
  local sinceLabel = date("%H:%M", since) .. (d.splitStart and "" or " (login)")
  local totals, order, drops = runTotals(since)
  local members = roster()
  local k = #members
  local worth, complete = runValue(totals, order)

  win.hint:SetText("Counts from the run marker — earlier shards never appear.")
  win.empty:SetText("Nothing disenchanted since " .. sinceLabel)
  win.castingRow = nil
  win.announce:SetEnabled(k > 1)

  local hi, ri, y = 1, 0, 0
  y = placeHead(hi, y, "runmats",
    ("|cff33cc44MATERIALS THIS RUN|r  |cff888888(%d)|r"):format(#order),
    worth and ("worth ~" .. shortMoney(worth) .. (complete and "" or "+")) or "")
  if not isCollapsed("runmats") then
    for _, out in ipairs(order) do
      local total = totals[out]
      local price = marketPrice(tonumber(out:match("item:(%d+)")))
      if price and price <= 0 then price = nil end
      local share
      if k > 1 then
        local each, spare = math.floor(total / k), total % k
        share = ("%d each for %d members%s"):format(each, k,
          spare > 0 and (", " .. spare .. " spare") or "")
      else
        share = "not in a group — totals only"
      end
      ri = ri + 1
      y = placeInfo(ri, y, SPLIT_TINT, out, ("%s |cffffffffx%d|r"):format(out, total),
        "|cff777777" .. share .. "|r", price and shortMoney(price * total) or "")
    end
  end

  -- Newest first: mid-run you're asking about the thing that just happened.
  local log = {}
  for i = #d.audit, 1, -1 do
    if d.audit[i].t >= since then log[#log + 1] = d.audit[i] end
  end
  hi = hi + 1
  y = placeHead(hi, y, "runlog", ("|cffffd100LOG|r  |cff888888(%d, newest first)|r"):format(#log))
  if not isCollapsed("runlog") then
    for i = 1, math.min(#log, RUN_LOG_MAX) do
      local e = log[i]
      local what
      if e.del then
        what = (e.src or "?") .. "  |cffff5555deleted|r"
      else
        -- ">" not an arrow: the row font on this client has no U+2192 glyph
        -- and draws a tofu box instead.
        what = (e.src and (e.src .. " |cff888888>|r ") or "") .. e.out
          .. (e.n > 1 and (" |cffffffffx" .. e.n .. "|r") or "")
      end
      ri = ri + 1
      y = placeInfo(ri, y, SPLIT_TINT, e.del and e.src or e.out, what,
        ("|cff777777%s   %s%s|r"):format(date("%H:%M", e.t), e.zone or "?",
          e.grp and ("  —  group of " .. e.grp) or ""))
    end
    if #log > RUN_LOG_MAX then
      ri = ri + 1
      y = placeInfo(ri, y, SPLIT_TINT, nil, ("|cff888888… and %d earlier — /de audit %d shows them all|r")
        :format(#log - RUN_LOG_MAX, #log), "", nil, NOTE_ICON)
    end
  end

  hideRest(hi, ri)
  win.content:SetHeight(math.max(-y, 1))
  win.empty:SetShown(#log == 0)
  local split = "   |cff888888not in a group|r"
  if k > 1 then
    split = (" — |cff33cc44split %d ways|r%s"):format(k,
      worth and (", ~" .. shortMoney(worth / k) .. " each") or "")
  end
  win.status:SetText(("Run since |cffffd100%s|r — %d drop%s%s"):format(sinceLabel,
    drops, drops == 1 and "" or "s", split))
  DE.UpdateBroker()
end

-- Archived runs are deliberately separate from the live split inventory. Each
-- run expands to its roster and its material totals.
function DE.RefreshHistory()
  local d = db()
  win.hint:SetText("Archived runs — expand one to inspect its materials and roster.")
  -- The hint line is hidden, so the empty state has to say how runs get here.
  win.empty:SetText("No archived runs yet\nPress New run on the Run Split tab (or /de runs end)\nto save what you've disenchanted so far as a run.")
  win.castingRow = nil

  local hi, ri, y = 0, 0, 0
  for i = #d.runs, 1, -1 do
    local run = d.runs[i]
    local key = "history" .. tostring(run.start or i)
    hi = hi + 1
    y = placeHead(hi, y, key, ("|cffb37ce8%s|r  |cff888888%s — %d drop%s|r"):format(
      run.name or "Run", date("%d %b %Y %H:%M", run.start), run.drops or 0,
      run.drops == 1 and "" or "s"),
      type(run.value) == "number" and ("was ~" .. shortMoney(run.value)) or "")
    if not isCollapsed(key) then
      local members = run.members or {}
      ri = ri + 1
      y = placeInfo(ri, y, HISTORY_TINT, nil,
        #members > 0 and ("Roster |cff888888(%d)|r"):format(#members) or "No roster captured",
        "|cff777777" .. (#members > 0 and table.concat(members, ", ") or "You weren't in a group when this run ended.") .. "|r",
        nil, NOTE_ICON)
      for _, material in ipairs(run.totals or {}) do
        local n = material.n or 0
        local price = marketPrice(tonumber(tostring(material.out):match("item:(%d+)")))
        if price and price <= 0 then price = nil end
        ri = ri + 1
        y = placeInfo(ri, y, HISTORY_TINT, material.out,
          ("%s |cffffffffx%d|r"):format(material.out, n),
          price and "|cff777777at today's prices|r" or "",
          price and shortMoney(price * n) or "")
      end
    end
  end

  hideRest(hi, ri)
  win.content:SetHeight(math.max(-y, 1))
  win.empty:SetShown(#d.runs == 0)
  win.status:SetText(("|cffb37ce8%d archived run%s|r"):format(#d.runs, #d.runs == 1 and "" or "s"))
  DE.UpdateBroker()
end

--------------------------------------------------------------------------------
-- Settings tab. One scrolling column in sections: who the settings belong to,
-- the guards that protect, the guards and thresholds that ask for Ctrl, the
-- list's extras, and the Next key.
--------------------------------------------------------------------------------
local MODIFIER_KEY = {
  LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
  LALT = true, RALT = true, LMETA = true, RMETA = true,
}
local MOUSE_KEY = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local function ensureOptions(parent)
  local o = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  o:SetPoint("TOPLEFT", parent, "TOPLEFT", 5, -64)
  o:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -5, 6)
  backdrop(o, 0.96)
  o:EnableMouse(true)
  o:Hide()
  o.checks, o.boxes = {}, {}

  local scroll = CreateFrame("ScrollFrame", "DisenchanterOptionsScroll", o, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 6, -6)
  scroll:SetPoint("BOTTOMRIGHT", -27, 6)
  local c = CreateFrame("Frame", nil, scroll)
  c:SetSize(ROW_W - 10, 1)
  scroll:SetScrollChild(c)
  o:SetScript("OnSizeChanged", function(self) c:SetWidth(math.max(1, self:GetWidth() - 38)) end)

  local y = 0
  local function section(title, sub)
    y = y - 8
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", 4, y)
    fs:SetText(title .. (sub and ("  |cff888888" .. sub .. "|r") or ""))
    local rule = c:CreateTexture(nil, "ARTWORK")
    rule:SetPoint("TOPLEFT", 4, y - 13)
    rule:SetPoint("TOPRIGHT", -4, y - 13)
    rule:SetHeight(1)
    rule:SetColorTexture(0.30, 0.32, 0.37, 0.7)
    y = y - 17
  end
  local function check(id, label, get, set, tipTitle, tipBody)
    local cb = CreateFrame("CheckButton", "DisenchanterOption" .. id, c, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", 4, y)
    -- The template's label has been a global, .Text and .text over the years.
    local text = _G[cb:GetName() .. "Text"] or cb.Text or cb.text
    if text then
      text:SetFontObject("GameFontHighlightSmall")
      text:SetText(label)
    end
    cb.get = get
    cb:SetScript("OnClick", function(self) set(self:GetChecked() and true or false) end)
    if tipTitle then simpleTip(cb, tipTitle, tipBody) end
    o.checks[#o.checks + 1] = cb
    y = y - 22
    return cb
  end
  -- A labelled whole-number box, indented under the guard it belongs to.
  -- Committing lives in OnEditFocusLost so a typed value isn't silently
  -- dropped by clicking elsewhere. Enter just clears focus; Escape reverts
  -- the text first, so the commit that follows is a no-op.
  local function number(label, get, set)
    local fs = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 32, y - 5)
    fs:SetText(label)
    local eb = CreateFrame("EditBox", nil, c, "InputBoxTemplate")
    eb:SetSize(46, 20)
    eb:SetPoint("LEFT", fs, "RIGHT", 12, 0)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    eb.get = get
    eb:SetScript("OnEditFocusLost", function(self)
      set(math.max(0, tonumber(self:GetText()) or 0))
      DE.Refresh()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:SetText(tostring(get())); self:ClearFocus() end)
    o.boxes[#o.boxes + 1] = eb
    y = y - 24
    return eb
  end
  local function guardCheck(g)
    check("Guard" .. g.key, g.label,
      function() return cfg().guards[g.key] end,
      function(v) cfg().guards[g.key] = v; DE.Refresh() end)
  end

  section("THIS CHARACTER")
  check("Char", "Own guards and thresholds for " .. ((UnitName and UnitName("player")) or "this character"),
    function() return DB.GetChar(GUARDS).own end,
    function(v) DE.SetCharSettings(v) end,
    "Per-character settings",
    "Off: every character shares the guards and thresholds below. On: this character keeps its own, starting from a copy of the shared ones. The keep list, audit and run history are always shared.")

  section("PROTECT", "no click does anything")
  for _, g in ipairs(GUARDS) do
    if g.hard then guardCheck(g) end
  end

  section("ASK FOR A CTRL-CLICK")
  for _, g in ipairs(GUARDS) do
    if not g.hard then
      guardCheck(g)
      if g.key == "value" then
        number("BoEs worth more than (gold)",
          function() return cfg().valueGold end, function(v) cfg().valueGold = v end)
      elseif g.key == "loss" then
        number("Loses more than (silver)",
          function() return cfg().lossSilver end, function(v) cfg().lossSilver = v end)
      end
    end
  end
  y = y - 4
  number("Above item level (0 = off)",
    function() return cfg().ilvlCap end, function(v) cfg().ilvlCap = v end)
  o.quality = flatButton(c, "", 220, 22)
  o.quality:SetPoint("TOPLEFT", 32, y - 2)
  o.quality:SetScript("OnClick", function()
    local s = cfg()
    s.confirmAbove = (s.confirmAbove >= 4) and 2 or (s.confirmAbove + 1)
    DE.Refresh()
  end)
  simpleTip(o.quality, "Plain-click ceiling", "Anything better than this needs a Ctrl-click. Click to cycle.")
  y = y - 28

  section("LIST AND TOOLTIPS")
  check("Profit", "Sort by estimated profit, best first",
    function() return db().sortProfit end,
    function(v) db().sortProfit = v; DE.Resort() end,
    "Estimated disenchant profit",
    "Uses Auctionator or TSM prices for the item and its likely materials. Items with no price stay at the bottom.")
  check("Tooltips", "Show disenchant info in item tooltips",
    function() return db().tooltips end,
    function(v) db().tooltips = v; DE.Refresh() end,
    "Item tooltips",
    "Adds what an item disenchants into and what that is worth to its tooltip, wherever it appears. Items in your bags also show their verdict.")

  section("NEXT-ITEM KEY", "Disenchant tab only")
  local key = flatButton(c, "", 190, 22)
  key:SetPoint("TOPLEFT", 6, y - 2)
  local clear = flatButton(c, "Clear", 50, 22)
  clear:SetPoint("LEFT", key, "RIGHT", 6, 0)
  clear:SetScript("OnClick", function() DE.SetNextKey("none") end)
  local function stopCapture()
    key.capturing = nil
    key:EnableKeyboard(false)
    key:EnableMouseWheel(false)
    DE.RefreshOptions()
  end
  key:EnableKeyboard(false)
  key:SetScript("OnClick", function(self)
    if self.capturing then stopCapture() return end
    -- While capturing, this button swallows the keyboard. Give up after a few
    -- seconds so a click that was never followed by a key can't leave it deaf.
    local token = {}
    self.capturing = token
    self:EnableKeyboard(true)
    self:EnableMouseWheel(true)
    C_Timer.After(8, function() if key.capturing == token then stopCapture() end end)
    DE.RefreshOptions()
  end)
  key:SetScript("OnKeyDown", function(self, pressed)
    if not self.capturing or MODIFIER_KEY[pressed] then return end
    stopCapture()
    if pressed ~= "ESCAPE" then DE.SetNextKey(pressed) end
  end)
  key:SetScript("OnMouseWheel", function(self, delta)
    if not self.capturing then return end
    stopCapture()
    DE.SetNextKey(delta > 0 and "MOUSEWHEELUP" or "MOUSEWHEELDOWN")
  end)
  key:SetScript("OnMouseDown", function(self, button)
    if not (self.capturing and MOUSE_KEY[button]) then return end
    stopCapture()
    DE.SetNextKey(MOUSE_KEY[button])
  end)
  key:SetScript("OnHide", function(self) if self.capturing then stopCapture() end end)
  simpleTip(key, "Next-item key",
    "Click, then within a few seconds press a key (or scroll the wheel, or press mouse button 3-5, over this button). While the window is open on the Disenchant tab that key presses Disenchant next: one press, one Safe item. It goes back to its usual job when the window closes.")
  o.key, o.keyClear = key, clear
  y = y - 30

  local hint = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOPLEFT", 6, y - 6)
  hint:SetPoint("TOPRIGHT", -6, y - 6)
  hint:SetJustifyH("LEFT")
  hint:SetText("Padlock a row to keep that exact item. |cffffd100/de keep #itemid|r keeps "
    .. "every version, |cffffd100/de keep name:text|r matches names.")
  y = y - 40

  c:SetHeight(-y)
  return o
end

function DE.RefreshOptions()
  local o = win and win.opts
  if not o then return end
  for _, cb in ipairs(o.checks) do cb:SetChecked(cb.get() and true or false) end
  for _, eb in ipairs(o.boxes) do eb:SetText(tostring(eb.get())) end
  o.quality:SetText("Plain-click up to: " .. (CONFIRM_LABEL[cfg().confirmAbove] or "?"))
  local key = db().nextKey
  o.key:SetText(o.key.capturing and "Press a key  (Esc cancels)"
    or (key and ("Key: " .. keyLabel(key) .. "  — click to change") or "No key — click to set one"))
  o.keyClear:SetEnabled(key ~= nil and not o.key.capturing)
end

--------------------------------------------------------------------------------
local TAB_ID = { de = 1, trash = 2, split = 3, history = 4, options = 5 }

local function ensureWindow()
  if win then return win end
  local f = CreateFrame("Frame", "DisenchanterFrame", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(math.max(MIN_W, math.min(MAX_W, db().panel.w or WIN_W)),
    math.max(MIN_H, math.min(MAX_H, db().panel.h or WIN_H)))
  if db().panel.point then
    f:SetPoint(db().panel.point, UIParent, db().panel.relativePoint or db().panel.point,
      db().panel.x or 0, db().panel.y or 0)
  else
    f:SetPoint("CENTER", 0, 60)
  end
  f:SetBackdrop({
    bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 8,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
  })
  f:SetBackdropColor(0.035, 0.04, 0.05, 0.97)
  f:SetBackdropBorderColor(0.20, 0.22, 0.25, 1)
  f:SetMovable(true)
  f:SetResizable(true)
  if f.SetResizeBounds then f:SetResizeBounds(MIN_W, MIN_H, MAX_W, MAX_H)
  elseif f.SetMinResize then f:SetMinResize(MIN_W, MIN_H); f:SetMaxResize(MAX_W, MAX_H) end
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relativePoint, x, y = self:GetPoint()
    db().panel.point, db().panel.relativePoint = point, relativePoint
    db().panel.x, db().panel.y = x, y
  end)
  f:SetFrameStrata("DIALOG")
  -- The next-item key only exists while the window does: bound on the way in,
  -- released (and the button disarmed) on the way out.
  f:SetScript("OnShow", function() DE.Resort(); applyNextKey() end)
  f:SetScript("OnHide", function() syncNext(nil); applyNextKey() end)
  tinsert(UISpecialFrames, "DisenchanterFrame") -- Esc closes it

  local header = f:CreateTexture(nil, "BORDER")
  header:SetPoint("TOPLEFT", 1, -1)
  header:SetPoint("TOPRIGHT", -1, -1)
  header:SetHeight(20)
  header:SetColorTexture(0.10, 0.085, 0.13, 0.98)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  title:SetPoint("TOPLEFT", 8, -5)
  title:SetText("Disenchanter  |cff6f6a7a" .. VERSION .. "|r")
  local close = CreateFrame("Button", nil, f)
  close:SetSize(20, 18)
  close:SetPoint("TOPRIGHT", -2, -2)
  local closeHover = close:CreateTexture(nil, "HIGHLIGHT")
  closeHover:SetAllPoints()
  closeHover:SetColorTexture(0.80, 0.25, 0.25, 0.45)
  local closeText = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  closeText:SetPoint("CENTER", 0, 1)
  closeText:SetText("x")
  close:SetScript("OnClick", function() f:Hide() end)

  win = f
  win.rows, win.heads = {}, {}

  win.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.status:SetPoint("TOPLEFT", 8, -25)
  win.status:SetPoint("TOPRIGHT", -8, -25)
  win.status:SetJustifyH("LEFT")
  win.status:SetWordWrap(false)

  win.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  win.hint:SetPoint("TOPLEFT", 8, -39)
  win.hint:SetPoint("TOPRIGHT", -8, -39)
  win.hint:SetJustifyH("LEFT")
  win.hint:SetWordWrap(false) -- a long hint truncates rather than spill into the tabs
  win.hint:Hide() -- row state and tooltips explain actions without another chrome line
  win.hint:SetText("Click a green row to disenchant it \226\128\148 Ctrl-click an amber one.")

  -- Draw tabs locally instead of inheriting a FrameXML tab template: the
  -- available template names differ between Classic client branches.
  local function tabButton(id, label, w, tab)
    local b = CreateFrame("Button", "DisenchanterFrameTab" .. id, f)
    b:SetID(id)
    b:SetSize(w, 20)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetPoint("TOPLEFT", 1, -1)
    b.bg:SetPoint("BOTTOMRIGHT", -1, 0)
    b.bg:SetColorTexture(0.055, 0.06, 0.07, 0.96)
    b.edge = b:CreateTexture(nil, "BORDER")
    b.edge:SetPoint("BOTTOMLEFT", 1, 0)
    b.edge:SetPoint("BOTTOMRIGHT", -1, 0)
    b.edge:SetHeight(2)
    b.edge:SetColorTexture(0.24, 0.26, 0.30, 0.9)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.text:SetPoint("CENTER", 0, 1)
    b.text:SetText(label)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b:SetScript("OnClick", function() DE.SetTab(tab) end)
    return b
  end
  win.tab = "de"
  win.tabDE = tabButton(1, "Disenchant", 82, "de")
  win.tabDE:SetPoint("TOPLEFT", 5, -43)
  win.tabTrash = tabButton(2, "Cleanup", 58, "trash")
  win.tabTrash:SetPoint("LEFT", win.tabDE, "RIGHT", 2, 0)
  win.tabSplit = tabButton(3, "Run Split", 66, "split")
  win.tabSplit:SetPoint("LEFT", win.tabTrash, "RIGHT", 2, 0)
  win.tabHistory = tabButton(4, "History", 58, "history")
  win.tabHistory:SetPoint("LEFT", win.tabSplit, "RIGHT", 2, 0)
  win.tabOptions = tabButton(5, "Settings", 60, "options")
  win.tabOptions:SetPoint("LEFT", win.tabHistory, "RIGHT", 2, 0)
  function win:SelectTabChrome(tabID)
    for id, button in ipairs({ self.tabDE, self.tabTrash, self.tabSplit, self.tabHistory, self.tabOptions }) do
      local selected = id == tabID
      button:SetEnabled(not selected)
      button.bg:SetColorTexture(selected and 0.11 or 0.055,
        selected and 0.115 or 0.06, selected and 0.14 or 0.07, 0.96)
      button.edge:SetColorTexture(selected and 0.88 or 0.24,
        selected and 0.68 or 0.26, selected and 0.24 or 0.30, selected and 1 or 0.9)
      button.text:SetTextColor(selected and 1 or 0.68,
        selected and 0.84 or 0.70, selected and 0.46 or 0.74)
    end
  end
  win:SelectTabChrome(1)

  local inset = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  inset:SetPoint("TOPLEFT", 5, -64)
  inset:SetPoint("BOTTOMRIGHT", -5, 34)
  backdrop(inset, 0.55)
  local scroll = CreateFrame("ScrollFrame", "DisenchanterScroll", inset, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 5, -5)
  scroll:SetPoint("BOTTOMRIGHT", -27, 5)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(ROW_W, 1)
  scroll:SetScrollChild(content)
  win.content = content
  win.empty = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  win.empty:SetPoint("CENTER")
  win.empty:SetText("Nothing disenchantable in your bags")

  -- The options tab sits over the list and the footer, so it has to win on
  -- frame level.
  win.opts = ensureOptions(f)
  win.opts:SetFrameLevel(inset:GetFrameLevel() + 20)

  -- Footer, list tabs: Rescan, To chat, the filter, and — on the Disenchant
  -- tab — the Next button in the corner.
  local rescan = flatButton(f, "Rescan", 58)
  rescan:SetPoint("BOTTOMLEFT", 6, 6)
  rescan:SetScript("OnClick", function() questCache = {}; DE.Resort() end)
  simpleTip(rescan, "Rescan and re-sort",
    "While the window is open rows hold their place and new items join the bottom of their section. This puts the list back in order.")

  local report = flatButton(f, "To chat", 58)
  report:SetPoint("LEFT", rescan, "RIGHT", 4, 0)
  report:SetScript("OnClick", function() DE.Report() end)
  simpleTip(report, "Print to chat", "Lists every item and its verdict in your chat window. Only you see it.")
  win.rescan, win.report = rescan, report

  local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  search:SetHeight(20)
  search:SetPoint("BOTTOMLEFT", 140, 7)
  search:SetPoint("BOTTOMRIGHT", -164, 7)
  search:SetAutoFocus(false)
  search:SetMaxLetters(40)
  search:SetTextInsets(2, 6, 0, 0)
  -- A placeholder, so an empty box says what it is for.
  search.placeholder = search:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  search.placeholder:SetPoint("LEFT", 3, 0)
  search.placeholder:SetText("Filter")
  local function placeholderState(self)
    self.placeholder:SetShown(self:GetText() == "" and not self:HasFocus())
  end
  search:HookScript("OnEditFocusGained", placeholderState)
  search:HookScript("OnEditFocusLost", placeholderState)
  search:SetScript("OnTextChanged", function(self, userInput)
    placeholderState(self)
    if not userInput then return end
    filterText = self:GetText():gsub("^%s+", ""):gsub("%s+$", "")
    DE.Refresh()
  end)
  search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  search:SetScript("OnEscapePressed", function(self)
    self:SetText(""); self:ClearFocus()
    filterText = ""
    DE.Refresh()
  end)
  search:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Filter items", 1, 1, 1)
    GameTooltip:AddLine("Matches item names and safety reasons. Escape clears it.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  search:SetScript("OnLeave", tipHide)
  win.search = search

  -- The Next button: secure, like a row, and armed by syncNext at the top
  -- Safe row. See the note above applyNextKey.
  local nb = CreateFrame("Button", "DisenchanterNextButton", f, "SecureActionButtonTemplate")
  nb:SetSize(136, 22)
  nb:SetPoint("BOTTOMRIGHT", -20, 6)
  nb:RegisterForClicks("AnyUp", "AnyDown")
  nb.edge = nb:CreateTexture(nil, "BACKGROUND")
  nb.edge:SetAllPoints()
  nb.bg = nb:CreateTexture(nil, "BORDER")
  nb.bg:SetPoint("TOPLEFT", 1, -1)
  nb.bg:SetPoint("BOTTOMRIGHT", -1, 1)
  local nbHover = nb:CreateTexture(nil, "HIGHLIGHT")
  nbHover:SetAllPoints(nb.bg)
  nbHover:SetColorTexture(1, 1, 1, 0.10)
  nb.text = nb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nb.text:SetPoint("CENTER", 0, 0)
  nb:SetScript("PreClick", notePending)
  nb:SetScript("OnEnter", function(self)
    local it = self.item
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if it then
      tipQuiet = true
      GameTooltip:SetBagItem(it.bag, it.slot)
      tipQuiet = false
      GameTooltip:AddLine(" ")
      GameTooltip:AddLine("Click to disenchant this — the top Safe row.", 0.4, 1, 0.4)
    else
      GameTooltip:SetText("Disenchant next", 1, 1, 1)
      GameTooltip:AddLine("Disenchants the top row of Safe to disenchant, one item per click. Nothing to do right now.", 0.6, 0.6, 0.6, true)
    end
    local key = keyLabel(db().nextKey)
    GameTooltip:AddLine(key and ("Key: " .. key .. " does the same while this tab is open.")
      or "Set a key for this in Settings, or with /de key.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  nb:SetScript("OnLeave", tipHide)
  win.next = nb

  -- The Run Split tab's bottom row, swapped in for Rescan/To chat by SetTab.
  local newRun = flatButton(f, "New run", 70)
  newRun:SetPoint("BOTTOMLEFT", 6, 6)
  newRun:SetScript("OnClick", function()
    local archived = startRun()
    pr((archived and "previous run archived; new" or "run")
      .. " marker set — the Run Split tab now counts from this moment.")
    DE.Refresh()
  end)
  simpleTip(newRun, "Start a new run",
    "Saves the run so far to the History tab, then moves the marker to now. Earlier disenchants stay in /de audit but stop counting toward this run's split.")
  newRun:Hide()

  local announce = flatButton(f, "Announce", 78)
  announce:SetPoint("LEFT", newRun, "RIGHT", 4, 0)
  announce:SetScript("OnClick", function() DE.Split("party") end)
  simpleTip(announce, "Announce the split",
    "Posts this run's totals, shares and estimated value to party or raid chat. Only ever on this click.")
  announce:Hide()
  win.newRun, win.announce = newRun, announce

  -- Resize grip and responsive rows, following Summon's compact panel. The
  -- secure actions do not change here; only the visible geometry does.
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(14, 14)
  grip:SetPoint("BOTTOMRIGHT", 0, 0)
  grip:SetFrameLevel(f:GetFrameLevel() + 30)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
  grip:SetScript("OnMouseUp", function()
    f:StopMovingOrSizing()
    db().panel.w, db().panel.h = math.floor(f:GetWidth() + 0.5), math.floor(f:GetHeight() + 0.5)
  end)
  local function resizeContent(self) content:SetWidth(math.max(1, self:GetWidth() - 42)) end
  f:SetScript("OnSizeChanged", resizeContent)
  resizeContent(f)

  -- Sweeps the casting row's fill each frame; a no-op the rest of the time.
  f:SetScript("OnUpdate", function()
    local row, c = win.castingRow, DE.cast
    if not (row and c and row:IsShown()) then return end
    local prog = math.min((GetTime() - c.startTime) / (c.duration > 0 and c.duration or 1), 1)
    row.castFill:SetWidth(math.max(prog * rowWidth(), 0.01))
  end)

  -- CreateFrame hands back a *shown* frame, so without this the first /de would
  -- toggle the window straight to hidden and OnShow would never fire.
  f:Hide()
  return win
end

function DE.Toggle()
  if InCombatLockdown() then
    pendingToggle = not pendingToggle
    pendingTab, pendingShow = nil, false
    pr(pendingToggle and "window will toggle when combat ends." or "pending window toggle cancelled.")
    return
  end
  local f = ensureWindow()
  if f:IsShown() then f:Hide() else f:Show() end
end

function DE.ShowTab(tab)
  if InCombatLockdown() then
    pendingTab, pendingShow, pendingToggle = tab, true, false
    pr("tab will open when combat ends.")
    return
  end
  DE.SetTab(tab)
  win:Show()
end

function DE.SetTab(tab)
  local f = ensureWindow()
  if tab == "run" then tab = "split" end -- compatibility with older callers
  if not TAB_ID[tab] then tab = "de" end
  f.tab = tab
  f:SelectTabChrome(TAB_ID[tab])
  local list = tab == "de" or tab == "trash"
  f.rescan:SetShown(list)
  f.report:SetShown(list)
  f.search:SetShown(list)
  -- The filter stretches into the corner the Next button leaves free.
  -- In combat the button can't be hidden, so it keeps its corner until after.
  local corner = tab == "de" or (InCombatLockdown() and f.next:IsShown())
  f.search:SetPoint("BOTTOMRIGHT", corner and -164 or -24, 7)
  f.newRun:SetShown(tab == "split")
  f.announce:SetShown(tab == "split")
  f.opts:SetShown(tab == "options")
  applyNextKey()
  DE.Resort()
end

--------------------------------------------------------------------------------
-- Cast progress. While a Disenchant this addon started is casting, DE.cast
-- holds which bag slot and the timing; Scan keeps that (locked) slot in the
-- list, Refresh flags its row, and the window's OnUpdate sweeps the row's fill.
-- Timing comes from UnitCastingInfo, so haste and pushback are honoured.
--------------------------------------------------------------------------------
--- @param update true when re-reading the times mid-cast (spell pushback)
function DE.CastStarted(update)
  if update and not DE.cast then return end
  local startMS, endMS
  if UnitCastingInfo then
    local ok, _, _, _, s, e = pcall(UnitCastingInfo, "player")
    if ok then startMS, endMS = s, e end
  end
  local c = DE.cast
  if not update then
    local it = (GetTime() - (DE._pendingAt or 0) < 3) and DE._pending or nil
    if not it then return end -- a Disenchant this addon didn't start; not ours to paint
    c = { itemID = it.itemID, bag = it.bag, slot = it.slot, link = it.link }
    DE.cast = c
  end
  c.startTime = startMS and (startMS / 1000) or GetTime()
  c.duration = (startMS and endMS and endMS > startMS) and ((endMS - startMS) / 1000) or 3
  DE.Refresh()
end

--- The cast ended — completed, interrupted or cancelled alike. The row either
--- vanishes with its item (success) or snaps back to normal (anything else).
function DE.CastFinished()
  if not DE.cast then return end
  DE.cast = nil
  DE.Refresh()
end

--- Everything needed to work out why a click didn't cast. Lives down here, not
--- up with the other chat commands, because it reads `win` — a local declared
--- with the UI, which anything defined above it would only see as a nil global.
function DE.Debug()
  ensureWindow():Show() -- the row list only exists once the window has drawn
  DE.Refresh()
  local version, build, _, iface = GetBuildInfo()
  pr(("client %s (%s), interface %s"):format(tostring(version), tostring(build), tostring(iface)))
  pr(("spell name resolves to |cffffd100%s|r; known=%s; Enchanting=%s; mode=%s")
    :format(deName(), tostring(knowsDisenchant()), tostring(enchantingSkill()),
      tostring(db().clickMode)))
  local safe = DE.Scan()
  if safe[1] then
    pr(("first safe row: %s at bag %d slot %d (bag 0 holds %d slots)"):format(
      safe[1].link, safe[1].bag, safe[1].slot, C.GetContainerNumSlots(0) or -1))
  end
  local row = win.rows[1]
  if not row then pr("no rows built \226\128\148 is the list empty?") return end
  pr(("row 1 = %s, tier=%s, enabled=%s, mouse=%s"):format(
    row.item and row.item.link or "empty", row.item and row.item.tier or "?",
    tostring(row:IsEnabled()), tostring(row:IsMouseEnabled())))
  -- If the template didn't attach, OnClick is nil and the button is just a
  -- button — which looks exactly like a blocked action from the outside.
  pr(("secure: protected=%s onclick=%s handler=%s canTargetItem=%s"):format(
    tostring(row:IsProtected()), tostring(row:GetScript("OnClick") ~= nil),
    tostring(SecureActionButton_OnClick ~= nil),
    tostring(SpellCanTargetItem ~= nil)))
  for _, name in ipairs({ "type", "type1", "typeLeftButton", "spell", "spell1",
                          "macrotext", "macrotext1", "target-bag1", "target-slot1",
                          "ctrl-type1", "ctrl-target-slot1" }) do
    local v = row:GetAttribute(name)
    if v then print(("    %s = %s"):format(name, tostring(v):gsub("\n", " | "))) end
  end
  DE.trace = not DE.trace
  pr("click tracing " .. (DE.trace and "|cff33cc44ON|r \226\128\148 click a green row now."
    or "|cffff5555OFF|r."))
end

--------------------------------------------------------------------------------
-- Keep list.
--------------------------------------------------------------------------------
--- The padlock. `it` is a scanned item record. Locking writes this exact
--- variant; unlocking removes whatever was protecting the row, including a
--- bare-id entry that covered every version.
function DE.ToggleKeep(it)
  local keep = db().keep
  local label = it.link or ("#" .. tostring(it.itemID))
  local kept, everyVersion = keptAs(it)
  if kept then
    keep.items[kept] = nil
    pr(label .. " taken off your keep list."
      .. (everyVersion and " That entry covered every version of this item — padlock any you still want kept." or ""))
  else
    -- The link is stored as the value so /de keeps can name the variant.
    keep.items[keyOf(it)] = it.link or true
    allowed[keyOf(it)] = nil
    pr(label .. " will never be disenchanted.")
  end
  DE.Refresh()
end

function DE.AddKeep(spec)
  if not spec or spec == "" then pr("usage: /de keep <#itemid|[item link]|name:text>") return end
  local keep = db().keep
  local id = spec:match("^#?(%d+)$")
  local link = spec:match("|c[^|]*|Hitem:.-|h.-|h|r") or spec:match("|Hitem:.-|h.-|h")
  if id then
    keep.items[tonumber(id)] = true
    pr((GetItemInfo(tonumber(id)) or ("#" .. id)) .. " added to the keep list — every version of it.")
  elseif link then
    -- A shift-clicked link names one exact variant.
    local linkID = tonumber(link:match("item:(%d+)"))
    if not linkID then pr("couldn't read an item id from that link.") return end
    keep.items[itemKey(link, linkID)] = link
    pr(link .. " added to the keep list.")
  else
    local text = spec:match("^name:(.+)$") or spec
    keep.names[#keep.names + 1] = text
    pr(('anything matching "%s" added to the keep list.'):format(text))
  end
  DE.Refresh()
end

-- Item entries sorted by item id (bare ids before their variants), then the
-- name patterns in entry order — Keeps and DeleteKeep must agree on this
-- numbering, so both build it here.
local function keepIDs()
  local ids = {}
  for id in pairs(db().keep.items) do ids[#ids + 1] = id end
  local function base(key) return tonumber(tostring(key):match("^%d+")) or 0 end
  table.sort(ids, function(a, b)
    local ba, bb = base(a), base(b)
    if ba ~= bb then return ba < bb end
    if type(a) ~= type(b) then return type(a) == "number" end
    return tostring(a) < tostring(b)
  end)
  return ids
end

function DE.Keeps()
  local keep = db().keep
  local ids = keepIDs()
  if #ids + #keep.names == 0 then pr("keep list is empty.") return end
  pr("keep list:")
  local i = 0
  for _, id in ipairs(ids) do
    i = i + 1
    local saved = keep.items[id]
    if type(id) == "number" then
      print(("    %d. %s  |cff888888every version|r"):format(i, (select(2, GetItemInfo(id))) or ("#" .. id)))
    else
      print(("    %d. %s"):format(i, type(saved) == "string" and saved or ("#" .. id)))
    end
  end
  for _, name in ipairs(keep.names) do
    i = i + 1
    print(('    %d. name: "%s"'):format(i, name))
  end
  print("    |cff888888/de keep del <n> removes one.|r")
end

function DE.DeleteKeep(n)
  local keep = db().keep
  local ids = keepIDs()
  n = tonumber(n)
  if not n or n < 1 or n > (#ids + #keep.names) then pr("no keep entry " .. tostring(n) .. ".") return end
  if n <= #ids then
    keep.items[ids[n]] = nil
  else
    table.remove(keep.names, n - #ids)
  end
  pr("keep entry " .. n .. " removed.")
  DE.Refresh()
end

--------------------------------------------------------------------------------
-- The learned list: item ids the server refused with "cannot be disenchanted".
-- Normally sound, but the attribution is a guess (the error that lands within
-- a few seconds of a click), so give it an escape hatch.
--------------------------------------------------------------------------------
function DE.Learned(clear)
  local d = db()
  local ids = {}
  for id in pairs(d.learned) do ids[#ids + 1] = id end
  table.sort(ids)
  if clear then
    d.learned = {}
    pr(#ids == 0 and "the learned list was already empty."
      or ("forgot %d refused item%s — they'll be offered again."):format(#ids, #ids == 1 and "" or "s"))
    DE.Refresh()
    return
  end
  if #ids == 0 then pr("the server hasn't refused anything yet.") return end
  pr("the server said these can't be disenchanted:")
  for _, id in ipairs(ids) do
    print(("    %s"):format((select(2, GetItemInfo(id))) or ("#" .. id)))
  end
  print("    |cff888888/de learned clear forgets them all.|r")
end

--------------------------------------------------------------------------------
-- LibDataBroker feed, for Titan Panel and every other LDB display (Bazooka,
-- ChocolateBar, ...). Nothing is bundled: the object is registered only if
-- some other addon has already put LibStub + LDB in the world — Titan ships
-- its own copy — and the addon behaves identically without it.
--------------------------------------------------------------------------------
local broker

function DE.InitBroker()
  if broker then return end
  local ldb = LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibDataBroker-1.1", true)
  if not ldb then return end
  broker = ldb:NewDataObject("Disenchanter", {
    type = "data source",
    label = "Disenchanter",
    version = VERSION,
    icon = "Interface\\Icons\\Spell_Holy_RemoveCurse",
    text = "…",
    OnClick = function(_, button)
      if button == "RightButton" then DE.Report() else DE.Toggle() end
    end,
    OnTooltipShow = function(tt)
      local safe, confirm, blocked = DE.Scan()
      tt:AddLine("Disenchanter")
      tt:AddDoubleLine("Safe to disenchant", #safe, 0.2, 0.8, 0.27, 1, 1, 1)
      tt:AddDoubleLine("Check first", #confirm, 1, 0.82, 0, 1, 1, 1)
      tt:AddDoubleLine("Protected", #blocked, 1, 0.33, 0.33, 1, 1, 1)
      local first = true
      for link, count in pairs(DE.tally) do
        if first then tt:AddLine(" "); tt:AddLine("Disenchanted this session:"); first = false end
        tt:AddDoubleLine(link, "x" .. count, 1, 1, 1, 0.8, 0.8, 0.8)
      end
      tt:AddLine(" ")
      tt:AddLine("|cff888888Click to open the window — right-click for a chat report.|r")
    end,
  })
  DE.UpdateBroker()
end

--- Refresh the panel text: green safe count, amber check-first count. Refresh
--- passes the counts it just scanned; with no arguments we scan ourselves.
function DE.UpdateBroker(nSafe, nConfirm)
  if not broker then return end
  if not nSafe then
    local safe, confirm = DE.Scan()
    nSafe, nConfirm = #safe, #confirm
  end
  broker.text = ("|cff33cc44%d|r |cffffd100%d|r"):format(nSafe, nConfirm)
end

--------------------------------------------------------------------------------
-- Events.
--------------------------------------------------------------------------------
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_LOGOUT") -- nothing to do but stamp lastSeen one last time
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("ITEM_LOCK_CHANGED")
ev:RegisterEvent("GET_ITEM_INFO_RECEIVED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("UI_ERROR_MESSAGE")
ev:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
ev:RegisterEvent("UNIT_SPELLCAST_START")
ev:RegisterEvent("UNIT_SPELLCAST_DELAYED")
ev:RegisterEvent("UNIT_SPELLCAST_STOP")
ev:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
ev:RegisterEvent("UNIT_SPELLCAST_FAILED")
ev:RegisterEvent("CHAT_MSG_LOOT")
ev:RegisterEvent("GROUP_ROSTER_UPDATE") -- the Run Split tab's shares and Announce state

-- Coalesce the burst of BAG_UPDATEs a disenchant produces into one rebuild.
-- Rows are already disarmed by the time this is queued, so the short wait is
-- only ever a moment of dead clicks, never a stale target.
local pending
local function queueRefresh()
  tipIndex = nil
  if pending then return end
  pending = true
  C_Timer.After(0.1, function()
    pending = nil
    DE.Refresh() -- updates the broker itself when the window is up
    if not (win and win:IsShown()) then DE.UpdateBroker() end
  end)
end

ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
  -- The session heartbeat: see resumeSession.
  if sessionLive then db().lastSeen = time() end

  if event == "PLAYER_LOGIN" then
    resumeSession()
    ensureWindow()
    DE.InitBroker()
    hookTooltips()
    if not knowsDisenchant() then
      -- Still perfectly usable as a "what would this give me" viewer, so this
      -- is a note, not a refusal to load.
      pr("loaded. You don't know Disenchant on this character — |cffffd100/de|r still shows what's in your bags.")
    end

  elseif event == "BAG_UPDATE" then
    finishPendingTrash()
    -- Disarm immediately: between an item moving and the rebuild landing, a
    -- stale row would point at whatever is now in that slot.
    disarmAll()
    queueRefresh()

  elseif event == "ITEM_LOCK_CHANGED" then
    -- A drag/split locks the slot before BAG_UPDATE announces its new contents.
    -- Disarm at the beginning of the move, not only after it completes.
    disarmAll()
    queueRefresh()

  elseif event == "BAG_UPDATE_DELAYED" or event == "GET_ITEM_INFO_RECEIVED" then
    queueRefresh()

  elseif event == "PLAYER_REGEN_DISABLED" then
    -- The rows usually can't be disarmed here: on the clients this was built
    -- against lockdown is already active when the event fires, so SetAttribute
    -- would be rejected. Harmless — the macro carries [nocombat], and the
    -- game refuses to cast Disenchant in combat anyway — so just grey the
    -- list. Where lockdown has not started yet,
    -- take the chance: disarm everything and release the next-item key.
    if not InCombatLockdown() then
      disarmAll()
      if win and ClearOverrideBindings then
        ClearOverrideBindings(win)
        keyDirty = true -- PLAYER_REGEN_ENABLED binds it again
      end
    end
    if win and win:IsShown() then
      win.content:SetAlpha(0.35)
      win.status:SetText(statusText({}, {}, {}))
    end

  elseif event == "PLAYER_REGEN_ENABLED" then
    if pendingShow and pendingTab then
      local tab = pendingTab
      pendingTab, pendingShow = nil, false
      DE.ShowTab(tab)
    elseif pendingToggle then
      pendingToggle = false
      DE.Toggle()
    end
    if keyDirty then applyNextKey() end
    queueRefresh()

  elseif event == "GROUP_ROSTER_UPDATE" then
    queueRefresh()

  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if a1 == "player" and a3 == DE_SPELL then
      lastDE = GetTime()
      -- Grab the consumed item's link before CastFinished clears DE.cast, so
      -- the loot line that follows can be written down as "src → out".
      lastDESource = (DE.cast and DE.cast.link) or (DE._pending and DE._pending.link) or nil
      lastDEOwn = DE.cast and DE.cast.link or nil
      DE.CastFinished()
    end

  elseif event == "UNIT_SPELLCAST_START" then
    if a1 == "player" and a3 == DE_SPELL then DE.CastStarted() end

  elseif event == "UNIT_SPELLCAST_DELAYED" then
    if a1 == "player" and a3 == DE_SPELL then DE.CastStarted(true) end

  elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_INTERRUPTED"
      or event == "UNIT_SPELLCAST_FAILED" then
    -- STOP also follows a success, but by then SUCCEEDED has already cleared
    -- DE.cast, so this only catches casts that died early. FAILED with no
    -- START (e.g. "can't be disenchanted") is ignored the same way.
    if a1 == "player" and a3 == DE_SPELL then DE.CastFinished() end

  elseif event == "CHAT_MSG_LOOT" then
    noteLoot(a1 or "")

  elseif event == "UI_ERROR_MESSAGE" then
    -- a1 is an error id on modern clients and the message on older ones.
    local msg = type(a2) == "string" and a2 or (type(a1) == "string" and a1 or nil)
    local it = DE._pending
    if msg and it and (GetTime() - (DE._pendingAt or 0)) < 3 then
      if SPELL_FAILED_CANT_BE_DISENCHANTED and msg == SPELL_FAILED_CANT_BE_DISENCHANTED then
        db().learned[it.itemID] = true
        DE._pending = nil
        pr(("%s can't be disenchanted \226\128\148 remembered, it won't be offered again."):format(it.link))
        queueRefresh()
      elseif SPELL_FAILED_CANT_BE_DISENCHANTED_SKILL and msg == SPELL_FAILED_CANT_BE_DISENCHANTED_SKILL then
        DE._pending = nil
        pr(("your Enchanting skill is too low for %s."):format(it.link))
      end
    end
  end
end)

--------------------------------------------------------------------------------
-- Slash command.
--------------------------------------------------------------------------------
local CONFIRM_WORD = { green = 2, uncommon = 2, blue = 3, rare = 3, epic = 4, purple = 4 }

function DE.Command(rest)
  rest = (rest or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, args = rest:match("^(%S*)%s*(.-)$")
  cmd = (cmd or ""):lower()

  if cmd == "" then
    DE.Toggle()
  elseif cmd == "trash" or cmd == "junk" then
    DE.ShowTab("trash")
  elseif cmd == "run" or cmd == "splitview" then
    DE.ShowTab("split")
  elseif cmd == "history" and args == "" then
    DE.ShowTab("history")
  elseif cmd == "scan" or cmd == "list" then
    DE.Report()
  elseif cmd == "keep" then
    local first, rest2 = args:match("^(%S+)%s*(.-)$")
    if first and (first:lower() == "del" or first:lower() == "delete") then
      DE.DeleteKeep(rest2)
    else
      DE.AddKeep(args)
    end
  elseif cmd == "keeps" then
    DE.Keeps()
  elseif cmd == "value" then
    local g = tonumber(args)
    if not g then pr("usage: /de value <gold> (0 turns the value guard off)") return end
    cfg().valueGold = math.max(0, g)
    pr(g > 0 and ("BoEs worth more than %s now need a Ctrl-click."):format(money(g * 10000))
      or "value guard off.")
    DE.Refresh()
  elseif cmd == "ilvl" then
    local n = tonumber(args)
    if not n then pr("usage: /de ilvl <n> (0 turns the item-level cap off)") return end
    cfg().ilvlCap = math.max(0, n)
    pr(n > 0 and ("item level over %d now needs a Ctrl-click."):format(n) or "item-level cap off.")
    DE.Refresh()
  elseif cmd == "confirm" then
    local q = CONFIRM_WORD[args:lower()]
    if not q then pr("usage: /de confirm <green|blue|epic>") return end
    cfg().confirmAbove = q
    pr("plain-click up to " .. (CONFIRM_LABEL[q] or "?") .. "; anything better needs Ctrl.")
    DE.Refresh()
  elseif cmd == "guard" then
    if args == "" then
      pr("guards" .. (DB.GetChar(GUARDS).own and ", this character's own" or "")
        .. " (|cffffd100/de guard <name>|r toggles one):")
      for _, g in ipairs(GUARDS) do
        print(("    %-9s %s  %s"):format(g.key,
          cfg().guards[g.key] and "|cff33cc44on |r" or "|cffff5555off|r", g.label))
      end
      return
    end
    local key = args:lower()
    local known = false
    for _, g in ipairs(GUARDS) do if g.key == key then known = true end end
    if not known then pr("no guard called '" .. key .. "'. |cffffd100/de guard|r lists them.") return end
    local guards = cfg().guards
    guards[key] = not guards[key]
    pr(("guard %s is now %s."):format(key, guards[key] and "|cff33cc44on|r" or "|cffff5555off|r"))
    DE.Refresh()
  elseif cmd == "loss" then
    local n = tonumber(args)
    if not n then pr("usage: /de loss <silver> — how much a disenchant may lose before the loss guard asks for Ctrl") return end
    cfg().lossSilver = math.max(0, n)
    pr(("the loss guard now asks for a Ctrl-click when disenchanting loses more than %s.%s"):format(
      money(cfg().lossSilver * 100),
      cfg().guards.loss and "" or " It is switched off — |cffffd100/de guard loss|r turns it on."))
    DE.Refresh()
  elseif cmd == "key" then
    if args == "" then
      local key = db().nextKey
      pr(key and ("next-item key: |cffffd100%s|r. |cffffd100/de key none|r clears it."):format(key)
        or "no next-item key set. |cffffd100/de key <key>|r sets one, e.g. /de key F or /de key MOUSEWHEELDOWN.")
    else
      DE.SetNextKey(args)
    end
  elseif cmd == "tooltip" or cmd == "tooltips" then
    db().tooltips = not db().tooltips
    pr("disenchant info in item tooltips " .. (db().tooltips and "|cff33cc44on|r." or "|cffff5555off|r."))
    DE.Refresh()
  elseif cmd == "char" then
    DE.SetCharSettings(not DB.GetChar(GUARDS).own)
  elseif cmd == "yields" then
    DE.Yields(args)
  elseif cmd == "learned" then
    DE.Learned(args:lower() == "clear")
  elseif cmd == "tally" then
    DE.Tally()
  elseif cmd == "audit" then
    DE.Audit(args)
  elseif cmd == "split" then
    DE.Split(args)
  elseif cmd == "runs" or cmd == "history" then
    DE.RunHistory(args)
  elseif cmd == "profit" then
    db().sortProfit = not db().sortProfit
    pr("estimated-profit sorting " .. (db().sortProfit and "|cff33cc44on|r." or "|cffff5555off|r."))
    DE.Resort()
  elseif cmd == "debug" then
    DE.Debug()
  elseif cmd == "mode" then
    local d = db()
    d.clickMode = (d.clickMode == "macro") and "spell" or "macro"
    pr("click mode: |cffffd100" .. d.clickMode .. "|r")
    DE.Refresh()
  else
    pr("commands: (no args) | trash | run | history | scan | keep <#id|[link]|name:text> | keep del <n> | keeps | value <gold> | loss <silver> | ilvl <n> | confirm <green|blue|epic> | guard [name] | char | key [key|none] | tooltip | yields [clear] | learned [clear] | tally | audit [n|clear] | split [start|say|party|raid] | runs [name <text>|end|clear] | profit | mode | debug")
  end
end

SLASH_DISENCHANTER1 = "/de"
SLASH_DISENCHANTER2 = "/disenchanter"
SlashCmdList.DISENCHANTER = function(msg) DE.Command(msg) end

DE._verdict = verdict
DE._tooltip = tooltipLines
DE._recordYield = recordYield
DE._itemKey = itemKey
DE._resumeSession = resumeSession
DE._trashVerdict = trashVerdict
DE._expectedDisenchantValue = expectedDisenchantValue
DE._db = db
DE._noteLoot = noteLoot
DE._deleteTrash = deleteTrash
DE._finishPendingTrash = finishPendingTrash
DE._arm = arm
DE._armCancel = armCancel
DE._window = function() return win end
DE._event = function(...) return ev:GetScript("OnEvent")(ev, ...) end
