--[[
  Disenchanter — a faster, safer way to work through a bag of greens.

  One window lists every disenchantable item in your bags, sorted into three
  buckets by what the guards think of it:

     Safe        left-click the row and it disenchants.
     Check first Ctrl-click required — blues/epics, valuable BoEs, ilvl over
                 your cap. The extra modifier is the whole point.
     Protected   no click does anything: keep list, quest items, relics, set
                 pieces, Use: effects, gear that beats what you're wearing,
                 anything Pawn calls an upgrade, anything in an ItemRack set.
                 Press Allow on a row to drop it to "check first" for this
                 session, or the padlock to protect it forever.

  A second tab, Trash, is the same idea pointed at deletion: the grey and white
  junk you'd destroy to free a slot when the bags are full. Sorted lowest
  vendor value first, so the top row is always the cheapest thing to lose.
  Click deletes a grey; whites need a Ctrl-click; the keep list, quest guard
  and value guard protect the rest. Deleting works off the cursor, so it needs
  no free bag slot and no vendor — which is the point.

  A third tab, Run, is the audit on screen for dungeon and raid nights: the
  materials produced since the run marker with the per-member split, and the
  drop log (what → what, when, where). It reads the audit, never your bags, so
  shards you walked in with are invisible to it. "New run" moves the marker;
  "Announce" posts the split to party/raid — the only time it ever speaks.

     DisenchanterDB = {
       keep    = { items = { [12345] = true }, names = { "heirloom", ... } },
       guards  = { quest = true, use = true, set = true, ... },  -- see GUARDS
       confirmAbove = 2,   -- quality above this needs a Ctrl-click (2 = green)
       valueGold    = 10,  -- BoEs worth more than this need a Ctrl-click
       ilvlCap      = 0,   -- 0 = off; above this needs a Ctrl-click
       learned = { [12345] = true },  -- server told us these can't be DE'd
       audit = { { t, zone, src, out, n, grp }, ... },  -- newest last, capped
       splitStart = 1755400000,       -- /de split start marker (epoch)
       collapsed = { safe = false, confirm = false, blocked = false },
     }

  Safety: the addon never casts anything on its own. Each row is a secure
  button that casts Disenchant on YOUR click, on the row YOU clicked —
  Blizzard's own protected-call rules make anything else impossible. The item
  is named by the row's `target-bag` / `target-slot` attributes, which the
  secure handler only applies if the cast actually put Disenchant on the
  cursor (SpellCanTargetItem) — so a click whose cast didn't start, because
  you don't know the spell, you're mid-cast, or you're dead, never uses,
  equips, sells or mails the item. The moment your bags change every row is
  disarmed until the list has been rebuilt, so a row can never fire at an
  item that has since moved into that slot.

  If a LibDataBroker display is installed (Titan Panel, Bazooka, ...) a
  "Disenchanter" plugin appears showing the safe / check-first counts; click
  opens the window, right-click prints the chat report. No libraries are
  bundled — the object registers only when another addon provides LDB, and
  everything else works the same without it.

  Commands:
     /de                      open the window
     /de trash                open the window on the Trash tab
     /de run                  open the window on the Run tab
     /de scan                 print the verdicts to chat
     /de keep <#id|name:text> never disenchant this
     /de keep del <n>         drop keep-list entry n
     /de keeps                list the keep list
     /de value <gold>         BoE value that needs a Ctrl-click (0 = off)
     /de ilvl <n>             item level that needs a Ctrl-click (0 = off)
     /de confirm <green|blue|epic>  quality above which a Ctrl-click is needed
     /de guard <name>         toggle a guard (no name = list them)
     /de learned [clear]      items the server refused; clear forgets them
     /de tally                what you've disenchanted this session
     /de audit [n|clear]      the log: what → what, when, where, group size
     /de split [start|say|party|raid]  divide shards since the marker
     /de mode                 swap macro / spell click plumbing (see README)
     /de debug                dump click state and toggle per-click tracing
]]

local DE = {}
Disenchanter = DE -- global, mostly for /dump poking

local C = C_Container

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

--------------------------------------------------------------------------------
-- What disenchanting an item is likely to give you, and what skill it needs.
-- Bands are {maxItemLevel, requiredSkill, "likely mats"} for one quality; the
-- roll inside a band is dust vs essence vs shard, so all three are listed.
-- Approximate on purpose — it's a hint for "is this worth my time", not a
-- promise. TBC (2.5.x) tables; Era swaps in the vanilla ones below.
--------------------------------------------------------------------------------
local YIELD = {
  [2] = { -- Uncommon
    { 15,  1,   "Strange Dust / Lesser Magic Essence" },
    { 20,  1,   "Strange Dust / Greater Magic Essence / Small Glimmering Shard" },
    { 25,  25,  "Strange Dust / Lesser Astral Essence / Small Glimmering Shard" },
    { 30,  50,  "Soul Dust / Greater Astral Essence / Large Glimmering Shard" },
    { 35,  75,  "Soul Dust / Lesser Mystic Essence / Small Glowing Shard" },
    { 40,  100, "Vision Dust / Greater Mystic Essence / Large Glowing Shard" },
    { 45,  125, "Vision Dust / Lesser Nether Essence / Small Radiant Shard" },
    { 50,  150, "Dream Dust / Greater Nether Essence / Large Radiant Shard" },
    { 55,  175, "Dream Dust / Lesser Eternal Essence / Small Brilliant Shard" },
    { 60,  200, "Illusion Dust / Greater Eternal Essence / Large Brilliant Shard" },
    { 65,  225, "Arcane Dust / Lesser Planar Essence / Small Prismatic Shard" },
    { 99,  275, "Arcane Dust / Greater Planar Essence / Small Prismatic Shard" },
    { 200, 325, "Arcane Dust / Small Prismatic Shard" },
  },
  [3] = { -- Rare
    { 25,  1,   "Small Glimmering Shard" },
    { 30,  50,  "Large Glimmering Shard" },
    { 35,  75,  "Small Glowing Shard" },
    { 40,  100, "Large Glowing Shard" },
    { 45,  125, "Small Radiant Shard" },
    { 50,  150, "Large Radiant Shard" },
    { 55,  175, "Small Brilliant Shard" },
    { 60,  200, "Large Brilliant Shard (rarely Nexus Crystal)" },
    { 65,  225, "Small Prismatic Shard" },
    { 99,  275, "Large Prismatic Shard" },
    { 200, 325, "Large Prismatic Shard (rarely Void Crystal)" },
  },
  [4] = { -- Epic
    { 45,  225, "Small Brilliant Shard" },
    { 50,  225, "Large Brilliant Shard" },
    { 60,  225, "Nexus Crystal" },
    { 95,  300, "Void Crystal" },
    { 200, 375, "Void Crystal" },
  },
}

-- Era (vanilla) rules: Disenchant has no skill gate at all, and the mats stop
-- at the ilvl-60 tier -- no Arcane Dust, no Prismatic/Void. Detected by project
-- id so the same file ships to both clients.
if WOW_PROJECT_ID == (WOW_PROJECT_CLASSIC or 2) then
  YIELD = {
    [2] = { -- Uncommon
      { 15,  1, "Strange Dust / Lesser Magic Essence" },
      { 20,  1, "Strange Dust / Greater Magic Essence / Small Glimmering Shard" },
      { 25,  1, "Strange Dust / Lesser Astral Essence / Small Glimmering Shard" },
      { 30,  1, "Soul Dust / Greater Astral Essence / Large Glimmering Shard" },
      { 35,  1, "Soul Dust / Lesser Mystic Essence / Small Glowing Shard" },
      { 40,  1, "Vision Dust / Greater Mystic Essence / Large Glowing Shard" },
      { 45,  1, "Vision Dust / Lesser Nether Essence / Small Radiant Shard" },
      { 50,  1, "Dream Dust / Greater Nether Essence / Large Radiant Shard" },
      { 55,  1, "Dream Dust / Lesser Eternal Essence / Small Brilliant Shard" },
      { 200, 1, "Illusion Dust / Greater Eternal Essence / Large Brilliant Shard" },
    },
    [3] = { -- Rare
      { 25,  1, "Small Glimmering Shard" },
      { 30,  1, "Large Glimmering Shard" },
      { 35,  1, "Small Glowing Shard" },
      { 40,  1, "Large Glowing Shard" },
      { 45,  1, "Small Radiant Shard" },
      { 50,  1, "Large Radiant Shard" },
      { 55,  1, "Small Brilliant Shard" },
      { 200, 1, "Large Brilliant Shard (rarely Nexus Crystal)" },
    },
    [4] = { -- Epic
      { 45,  1, "Small Brilliant Shard" },
      { 50,  1, "Large Brilliant Shard" },
      { 200, 1, "Nexus Crystal" },
    },
  }
end

local function yieldFor(quality, ilvl)
  local bands = YIELD[quality]
  if not bands then return nil, nil end
  for _, b in ipairs(bands) do
    if ilvl <= b[1] then return b[3], b[2] end
  end
  local last = bands[#bands]
  return last[3], last[2]
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
local GUARDS = {
  { key = "quest",    hard = true,  label = "Quest items" },
  { key = "relic",    hard = true,  label = "Relics (idol / libram / totem)" },
  { key = "set",      hard = true,  label = "Item-set pieces" },
  { key = "use",      hard = true,  label = "Items with a Use: effect" },
  { key = "upgrade",  hard = true,  label = "Beats my equipped item" },
  { key = "pawn",     hard = true,  label = "Pawn calls it an upgrade" },
  { key = "itemrack", hard = true,  label = "In an ItemRack set" },
  { key = "boe",      hard = false, label = "Any bind-on-equip item" },
  { key = "value",    hard = false, label = "Valuable BoEs (see /de value)" },
}

local function db()
  DisenchanterDB = DisenchanterDB or {}
  local d = DisenchanterDB
  d.keep = d.keep or {}
  d.keep.items = d.keep.items or {}
  d.keep.names = d.keep.names or {}
  d.learned = d.learned or {}
  d.audit = d.audit or {}
  d.collapsed = d.collapsed or {}
  if d.confirmAbove == nil then d.confirmAbove = 2 end
  if d.valueGold == nil then d.valueGold = 10 end
  if d.ilvlCap == nil then d.ilvlCap = 0 end
  -- "spell" was a stopgap while the dead-click was being tracked down; the real
  -- cause was click registration, so put everyone back on the macro path once.
  if d.clickModeVersion ~= 2 then d.clickMode, d.clickModeVersion = "macro", 2 end
  if d.guards == nil then
    d.guards = {}
    for _, g in ipairs(GUARDS) do d.guards[g.key] = (g.key ~= "boe") end
  end
  return d
end

-- Overrides live for the session only. Protecting something is permanent (it
-- goes on the keep list); un-protecting it is deliberately not, so a guard you
-- waved past today is back tomorrow.
local allowed = {}

--------------------------------------------------------------------------------
-- Odds and ends the guards lean on.
--------------------------------------------------------------------------------
local function money(copper) return GetCoinTextureString(copper or 0) end

--- C_Container is a backport; fall back to the old global if this build predates
--- the container API gaining UseContainerItem.
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
  local d = db()
  local g = d.guards

  if d.keep.items[it.itemID] then return "blocked", "on your keep list", true end
  for _, n in ipairs(d.keep.names) do
    if n ~= "" and it.name:lower():find(n:lower(), 1, true) then
      return "blocked", 'keep list: "' .. n .. '"', true
    end
  end
  if d.learned[it.itemID] then return "blocked", "the server says this can't be disenchanted", true end
  if it.skillNeeded and skill and skill < it.skillNeeded then
    return "blocked", ("needs Enchanting %d (you have %d)"):format(it.skillNeeded, skill), true
  end

  if not allowed[it.itemID] then
    if g.quest and it.isQuest then return "blocked", "quest item" end
    if g.relic and it.isRelic then return "blocked", "relic — idol / libram / totem" end
    if g.set and it.setID then return "blocked", "part of an item set" end
    if g.use and it.useSpell then return "blocked", "has a Use: effect (" .. it.useSpell .. ")" end
    if g.upgrade and it.beats then return "blocked", "out-levels your equipped " .. it.beats end
    if g.pawn and it.pawnUpgrade then return "blocked", "Pawn rates this an upgrade" end
    if g.itemrack and it.rackSet then return "blocked", "in your ItemRack set '" .. it.rackSet .. "'" end
  end

  if g.boe and it.boe then return "confirm", "bind-on-equip" end
  if g.value and it.boe and it.value and it.value >= d.valueGold * 10000 then
    return "confirm", ("worth %s%s"):format(money(it.value), it.valueSrc == "ah" and " on the AH" or " to a vendor")
  end
  if it.quality > d.confirmAbove then
    return "confirm", (QUALITY_NAME[it.quality] or "high") .. " quality"
  end
  if d.ilvlCap > 0 and it.ilvl > d.ilvlCap then
    return "confirm", ("item level %d, over your cap of %d"):format(it.ilvl, d.ilvlCap)
  end
  return "safe", nil
end

--------------------------------------------------------------------------------
-- Scan the bags.
--------------------------------------------------------------------------------
--- @return safe, confirm, blocked  three arrays of item records
function DE.Scan()
  local safe, confirm, blocked = {}, {}, {}
  local rack = db().guards.itemrack and itemRackIndex() or {}
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
          local it = {
            bag = bag, slot = slot, itemID = info.itemID,
            name = name, link = info.hyperlink or link, icon = info.iconFileID,
            quality = quality, ilvl = ilvl, count = info.stackCount or 1,
            yield = yield, skillNeeded = skillNeeded,
            value = value, valueSrc = valueSrc,
            boe = (bindType == 2) and not info.isBound,
            setID = setID,
            isRelic = (classID == 4 and RELIC_SUB[subID]) or invType == "INVTYPE_RELIC",
            isQuest = isQuestItem(bag, slot, info.itemID),
            useSpell = (GetItemSpell and GetItemSpell(info.itemID)) or nil,
            rackSet = rack[info.itemID],
            casting = casting or nil,
          }
          it.beats = db().guards.upgrade and beatsEquipped(invType, ilvl, classID, subID) or nil
          it.pawnUpgrade = db().guards.pawn and pawnSaysUpgrade(it.link) or false

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
  local d = db()
  if d.keep.items[it.itemID] then return "blocked", "on your keep list", true end
  for _, n in ipairs(d.keep.names) do
    if n ~= "" and it.name:lower():find(n:lower(), 1, true) then
      return "blocked", 'keep list: "' .. n .. '"', true
    end
  end
  if not allowed[it.itemID] then
    if d.guards.quest and it.isQuest then return "blocked", "quest item" end
    -- The value guard bites harder here than on the disenchant tab: deleting
    -- a stack of cloth is pure loss, so a valuable stack is Protected, not
    -- merely Ctrl-gated. Allow drops it to "check first" as usual.
    if d.guards.value and it.value and it.value >= d.valueGold * 10000 then
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
            name = name, link = info.hyperlink or link, icon = info.iconFileID,
            quality = quality, count = count,
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

--------------------------------------------------------------------------------
-- Chat report.
--------------------------------------------------------------------------------
local function qcolor(q)
  local c = ITEM_QUALITY_COLORS[q]
  return c and c.hex or "|cffffffff"
end

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
local sessionStart = time() -- fallback split marker: since login
local AUDIT_MAX = 300

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
  local link, count = msg:match("(|c%x+|Hitem:.-|h.-|h|r)%s*x?(%d*)")
  if not link then return end
  local n = tonumber(count) or 1
  DE.tally[link] = (DE.tally[link] or 0) + n
  auditAppend(lastDESource, link, n)
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
--- nobody's shard. Shared by /de split and the window's Run tab, so the two
--- can never disagree.
local function runTotals(since)
  local totals, order, drops = {}, {}, 0
  for _, e in ipairs(db().audit) do
    if e.t >= since and not e.del then
      drops = drops + 1
      if not totals[e.out] then order[#order + 1] = e.out end
      totals[e.out] = (totals[e.out] or 0) + e.n
    end
  end
  return totals, order, drops
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

--- /de split [start|say|party|raid]
--- Totals the audit from the split marker (or login) and divides by the
--- current group. Printing to a chat channel only ever happens on the explicit
--- say/party/raid argument — the addon never speaks on its own.
function DE.Split(args)
  local d = db()
  args = args:lower()
  if args == "start" then
    d.splitStart = time()
    pr("split marker set — |cffffd100/de split|r now totals everything from this moment.")
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

  if channel then
    for _, line in ipairs(lines) do SendChatMessage(line, channel) end
  else
    pr(lines[1])
    for i = 2, #lines do print("    " .. lines[i]) end
    if k > 1 then print("    |cff888888/de split party announces this to the group.|r") end
  end
end

--------------------------------------------------------------------------------
-- Chrome, borrowed wholesale from Mail Mule so the two addons look related.
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
local WIN_W, WIN_H = 380, 460
local ROW_W  = 320
local ROW_H  = 30
local HEAD_H = 22
local LIST_H = 300

local BUCKETS = {
  { key = "safe",    title = "Safe to disenchant",  color = "|cff33cc44" },
  { key = "confirm", title = "Check first",         color = "|cffffd100" },
  { key = "blocked", title = "Protected",           color = "|cffff5555" },
}

-- The Trash tab's buckets. `key` picks the list out of the scan; `col` keeps
-- its collapse state separate from the disenchant tab's.
local TRASH_BUCKETS = {
  { key = "safe",    col = "tsafe",    title = "Junk — click deletes it", color = "|cff33cc44" },
  { key = "confirm", col = "tconfirm", title = "Check first",             color = "|cffffd100" },
  { key = "blocked", col = "tblocked", title = "Protected",               color = "|cffff5555" },
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
---   "macro" (default) — a `/cast Disenchant` macrotext.
---   "spell"           — the `spell` attribute. Kept in case a patch breaks
---     macrotext.
local function arm(row, tier, bag, slot)
  setAction(row, "", nil, nil, nil, nil)
  setAction(row, "ctrl-", nil, nil, nil, nil)
  row.deBag, row.deSlot, row.deTier = nil, nil, nil
  row.trashBag, row.trashSlot = nil, nil
  if not (bag and slot and tier ~= "blocked") then return end
  local prefix = (tier == "safe") and "" or "ctrl-"
  if db().clickMode == "macro" then
    setAction(row, prefix, "macro", "/cast " .. deName(), bag, slot)
  else
    setAction(row, prefix, "spell", deName(), bag, slot)
  end
  row.deBag, row.deSlot, row.deTier = bag, slot, tier
end

--- Trash rows carry no secure action at all — deleting an item isn't a
--- protected call, so the plain PostClick handler does the whole job. arm()
--- runs first to strip any disenchant macro the row kept from the other tab,
--- and to clear the trash fields on a disarm.
local function armTrash(row, tier, bag, slot)
  arm(row, "blocked")
  if tier ~= "blocked" then row.trashBag, row.trashSlot = bag, slot end
end

--- Disarm every row right now. Called the instant bags change, so a row can
--- never fire at whatever slid into its slot before the rebuild lands.
local function disarmAll()
  if not win or InCombatLockdown() then return end
  for _, row in ipairs(win.rows) do arm(row, "blocked") end
end

local function headerRow(i)
  local row = win.heads[i]
  if row then return row end
  row = CreateFrame("Button", nil, win.content)
  row:SetSize(ROW_W, HEAD_H)
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  row.toggle = row:CreateTexture(nil, "ARTWORK")
  row.toggle:SetSize(14, 14)
  row.toggle:SetPoint("LEFT", 0, 0)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.text:SetPoint("LEFT", row.toggle, "RIGHT", 4, 0)
  row:SetScript("OnClick", function(self)
    local col = db().collapsed
    col[self.key] = (not col[self.key]) or nil
    DE.Refresh()
  end)
  win.heads[i] = row
  return row
end

local function itemRow(i)
  local row = win.rows[i]
  if row then return row end
  row = CreateFrame("Button", "DisenchanterRow" .. i, win.content, "SecureActionButtonTemplate")
  row:SetSize(ROW_W, ROW_H)
  -- Both edges, not just "LeftButtonUp". This client's secure handler acts on
  -- whichever edge ActionButtonUseKeyDown selects and returns silently on the
  -- other, so registering one edge can leave the button doing nothing at all.
  -- Every working secure button ships this way (Leatrix_Plus, Broker_Everything).
  row:RegisterForClicks("AnyUp", "AnyDown")
  row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

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
  row.icon:SetPoint("LEFT", 2, 0)
  row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- shave the icon's baked border

  -- The padlock: closed means the item is on your keep list forever, open means
  -- click to put it there. Blocked-by-a-guard rows also get an Allow button.
  row.lock = CreateFrame("Button", nil, row)
  row.lock:SetSize(16, 16)
  row.lock:SetPoint("RIGHT", -2, 0)
  row.lock:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
  row.lock:SetScript("OnClick", function(self)
    local it = self:GetParent().item
    if not it then return end
    DE.ToggleKeep(it.itemID, it.link)
  end)
  row.lock:SetScript("OnEnter", function(self)
    local it = self:GetParent().item
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(it and db().keep.items[it.itemID]
      and "On your keep list — click to remove"
      or "Click to never disenchant this item", 1, 1, 1)
    GameTooltip:Show()
  end)
  row.lock:SetScript("OnLeave", tipHide)

  row.allow = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  row.allow:SetSize(46, 18)
  row.allow:SetPoint("RIGHT", row.lock, "LEFT", -3, 0)
  row.allow:SetText("Allow")
  row.allow:SetScript("OnClick", function(self)
    local it = self:GetParent().item
    if not it then return end
    allowed[it.itemID] = true
    pr(("%s allowed for this session — Ctrl-click to %s it."):format(it.link,
      it.trash and "delete" or "disenchant"))
    DE.Refresh()
  end)
  row.allow:SetScript("OnEnter", function(self)
    local it = self:GetParent().item
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Ignore the guard for this session", 1, 1, 1)
    GameTooltip:AddLine(("The row moves to Check first; a Ctrl-click will then %s it. Forgotten on logout.")
      :format(it and it.trash and "delete" or "disenchant"), 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  row.allow:SetScript("OnLeave", tipHide)

  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 5, -1)
  row.name:SetPoint("RIGHT", row.allow, "LEFT", -4, 0)
  row.name:SetJustifyH("LEFT")
  row.name:SetWordWrap(false)

  row.note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.note:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -1)
  row.note:SetPoint("RIGHT", row.allow, "LEFT", -4, 0)
  row.note:SetJustifyH("LEFT")
  row.note:SetWordWrap(false)

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
    GameTooltip:SetBagItem(it.bag, it.slot)
    GameTooltip:AddLine(" ")
    if it.yield then GameTooltip:AddLine("Disenchants into: " .. it.yield, 0.6, 0.85, 1, true) end
    if it.value then
      GameTooltip:AddLine(("Worth %s%s"):format(money(it.value),
        it.valueSrc == "ah" and " on the AH" or " to a vendor"), 0.9, 0.9, 0.6)
    end
    if it.tier == "blocked" then
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

  -- PreClick can't cancel a secure action, but it can tell us what we were
  -- aiming at — which is what turns "Item cannot be disenchanted" into a
  -- permanent note against that item id.
  row:SetScript("PreClick", function(self, button)
    local it = self.item
    if DE.trace then
      pr(("PRE  button=%s ctrl=%s item=%s tier=%s type=%s"):format(
        tostring(button), tostring(IsControlKeyDown()),
        it and it.link or "nil", it and it.tier or "nil",
        tostring(self:GetAttribute("type"))))
    end
    if not (it and it.bag) then return end
    local now = C.GetContainerItemInfo(it.bag, it.slot)
    DE._pending = (now and now.itemID == it.itemID) and it or nil
    DE._pendingAt = GetTime()
  end)

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
      local now = C.GetContainerItemInfo(self.trashBag, self.trashSlot)
      if not (now and now.itemID == it.itemID) then return end
      ClearCursor() -- drop anything already held back into its slot first
      if C and C.PickupContainerItem then C.PickupContainerItem(self.trashBag, self.trashSlot)
      elseif PickupContainerItem then PickupContainerItem(self.trashBag, self.trashSlot)
      else return end
      if CursorHasItem and not CursorHasItem() then return end
      if not DeleteCursorItem then ClearCursor() return end
      DeleteCursorItem()
      auditAppend(it.link, "deleted", it.count, true)
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

local function statusText(safe, confirm, blocked)
  if InCombatLockdown() then
    return "|cffff5555In combat|r — the list is frozen until you're out."
  end
  -- The trash tab needs no profession at all, so its branch comes before the
  -- "you don't know Disenchant" complaint.
  if win and win.tab == "trash" then
    local n = #safe + #confirm
    return ("|cff33cc44%d junk|r, |cffffd100%d to check|r, |cffff5555%d protected|r%s")
      :format(#safe, #confirm, #blocked,
        n > 0 and ("   |cff888888%d bag slot%s to reclaim|r"):format(n, n == 1 and "" or "s") or "")
  end
  if not knowsDisenchant() then
    return "|cffff5555You don't know Disenchant.|r Rows are listed but nothing will cast."
  end
  local skill = enchantingSkill()
  return ("|cff33cc44%d safe|r, |cffffd100%d to check|r, |cffff5555%d protected|r%s")
    :format(#safe, #confirm, #blocked, skill and ("   |cff888888Enchanting " .. skill .. "|r") or "")
end

function DE.Refresh()
  if not (win and win:IsShown()) then return end
  if InCombatLockdown() then
    win.content:SetAlpha(0.35) -- visibly frozen; SetAlpha is fine in lockdown
    win.status:SetText(statusText({}, {}, {}))
    return -- SetAttribute is forbidden in combat; PLAYER_REGEN_ENABLED redraws
  end
  win.content:SetAlpha(1)
  if win.tab == "run" then return DE.RefreshRun() end
  local trash = win.tab == "trash"
  local safe, confirm, blocked
  if trash then
    safe, confirm, blocked = DE.ScanTrash()
  else
    safe, confirm, blocked = DE.Scan()
  end
  local lists = { safe = safe, confirm = confirm, blocked = blocked }

  win.hint:SetText(trash
    and "Click a row to delete it forever — Ctrl-click a white item."
    or "Click a green row to disenchant it — Ctrl-click an amber one.")
  win.empty:SetText(trash and "No junk in your bags" or "Nothing disenchantable in your bags")

  win.castingRow = nil
  -- Without Disenchant a row has nothing safe to do: leave it unarmed rather
  -- than let a click raise "You don't know that spell" against the item.
  local canCast = trash or knowsDisenchant()
  local hi, ri, y = 0, 0, 0
  for _, b in ipairs(trash and TRASH_BUCKETS or BUCKETS) do
    local list = lists[b.key]
    local ck = b.col or b.key
    hi = hi + 1
    local head = headerRow(hi)
    head.key = ck
    head.toggle:SetTexture(isCollapsed(ck) and PLUS or MINUS)
    head.text:SetText(("%s%s|r  |cff888888(%d)|r"):format(b.color, b.title, #list))
    head:ClearAllPoints(); head:SetPoint("TOPLEFT", 0, y)
    head:Show()
    y = y - HEAD_H

    if not isCollapsed(ck) then
      for _, it in ipairs(list) do
        ri = ri + 1
        local row = itemRow(ri)
        row.item = it
        row.icon:SetTexture(it.icon or FALLBACK_ICON)
        row.icon:SetDesaturated(it.tier == "blocked")
        if trash then
          -- Vendor value where the disenchant tab shows ilvl — it's the sort
          -- key, and it's what deleting the row costs you.
          row.name:SetText(("%s%s|r%s  |cff888888%s|r"):format(
            qcolor(it.quality), it.name, it.count > 1 and (" x" .. it.count) or "",
            it.vendor > 0 and money(it.vendor) or "worthless"))
          if it.tier == "safe" then
            row.note:SetText("|cff777777click to delete — gone for good|r")
          else
            row.note:SetText((it.tier == "confirm" and "|cffbfa640Ctrl-click: " or "|cffbf5555")
              .. (it.reason or "") .. "|r")
          end
        else
          row.name:SetText(("%s%s|r%s  |cff888888i%d|r"):format(
            qcolor(it.quality), it.name, it.count > 1 and (" x" .. it.count) or "", it.ilvl))
          if it.casting then
            row.note:SetText("|cffb37ce8Disenchanting...|r")
          elseif it.tier == "safe" then
            row.note:SetText("|cff777777" .. (it.yield or "") .. "|r")
          else
            row.note:SetText((it.tier == "confirm" and "|cffbfa640Ctrl-click: " or "|cffbf5555")
              .. (it.reason or "") .. "|r")
          end
        end
        row.castFill:SetShown(it.casting and true or false)
        if it.casting then win.castingRow = row end
        row.lock:Show() -- the Run tab hides it
        row.lock:SetNormalTexture(db().keep.items[it.itemID] and LOCKED or UNLOCKED)
        row.allow:SetShown(it.tier == "blocked" and not it.permanent)
        if trash then
          armTrash(row, it.tier, it.bag, it.slot)
        else
          -- A casting row is never armed: its item is locked, so a second
          -- click could only produce an error mid-cast.
          arm(row, (it.casting or not canCast) and "blocked" or it.tier, it.bag, it.slot)
        end
        row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, y)
        row:Show()
        y = y - ROW_H
      end
    end
  end
  for i = hi + 1, #win.heads do win.heads[i]:Hide() end
  for i = ri + 1, #win.rows do
    arm(win.rows[i], "blocked")
    win.rows[i].item = nil
    win.rows[i]:Hide()
  end
  win.content:SetHeight(math.max(-y, 1))
  win.empty:SetShown(#safe + #confirm + #blocked == 0)
  win.status:SetText(statusText(safe, confirm, blocked))
  if win.opts and win.opts:IsShown() then DE.RefreshOptions() end
  -- The broker always shows disenchant counts; on the trash tab it rescans.
  if trash then DE.UpdateBroker() else DE.UpdateBroker(#safe, #confirm) end
end

--------------------------------------------------------------------------------
-- The Run tab: the audit, on screen instead of in chat. Everything shown is
-- since the run marker (or login), so the shards you walked in with never
-- appear — the numbers come from the audit log, not from your bags.
--------------------------------------------------------------------------------
local RUN_LOG_MAX = 40 -- rows drawn; the header still counts everything

local function iconOf(link)
  if not (link and GetItemInfoInstant) then return nil end
  local ok, icon = pcall(function() return select(5, GetItemInfoInstant(link)) end)
  return ok and icon or nil
end

function DE.RefreshRun()
  local d = db()
  local since = d.splitStart or sessionStart
  local sinceLabel = date("%H:%M", since) .. (d.splitStart and "" or " (login)")
  local totals, order, drops = runTotals(since)
  local members = roster()
  local k = #members

  win.hint:SetText("Counts from the run marker — earlier shards never appear.")
  win.empty:SetText("Nothing disenchanted since " .. sinceLabel)
  win.castingRow = nil
  win.announce:SetEnabled(k > 1)

  local hi, ri, y = 0, 0, 0
  local function head(key, text)
    hi = hi + 1
    local h = headerRow(hi)
    h.key = key
    h.toggle:SetTexture(isCollapsed(key) and PLUS or MINUS)
    h.text:SetText(text)
    h:ClearAllPoints(); h:SetPoint("TOPLEFT", 0, y)
    h:Show()
    y = y - HEAD_H
  end
  local function line(link, nameText, noteText)
    ri = ri + 1
    local row = itemRow(ri)
    row.item = { run = true, runLink = link }
    row.icon:SetTexture(iconOf(link) or FALLBACK_ICON)
    row.icon:SetDesaturated(false)
    row.name:SetText(nameText)
    row.note:SetText(noteText or "")
    row.castFill:Hide()
    row.lock:Hide()
    row.allow:Hide()
    arm(row, "blocked")
    row:ClearAllPoints(); row:SetPoint("TOPLEFT", 0, y)
    row:Show()
    y = y - ROW_H
  end

  head("runmats", ("|cff33cc44Materials this run|r  |cff888888(%d)|r"):format(#order))
  if not isCollapsed("runmats") then
    for _, out in ipairs(order) do
      local total = totals[out]
      local share
      if k > 1 then
        local each, spare = math.floor(total / k), total % k
        share = ("%d each for %d members%s"):format(each, k,
          spare > 0 and (", " .. spare .. " spare") or "")
      else
        share = "not in a group — totals only"
      end
      line(out, ("%s |cffffffffx%d|r"):format(out, total), "|cff777777" .. share .. "|r")
    end
  end

  -- Newest first: mid-run you're asking about the thing that just happened.
  local log = {}
  for i = #d.audit, 1, -1 do
    if d.audit[i].t >= since then log[#log + 1] = d.audit[i] end
  end
  head("runlog", ("|cffffd100Log|r  |cff888888(%d, newest first)|r"):format(#log))
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
      line(e.del and e.src or e.out, what,
        ("|cff777777%s   %s%s|r"):format(date("%H:%M", e.t), e.zone or "?",
          e.grp and ("  —  group of " .. e.grp) or ""))
    end
    if #log > RUN_LOG_MAX then
      line(nil, ("|cff888888… and %d earlier — /de audit %d shows them all|r")
        :format(#log - RUN_LOG_MAX, #log), "")
    end
  end

  for i = hi + 1, #win.heads do win.heads[i]:Hide() end
  for i = ri + 1, #win.rows do
    arm(win.rows[i], "blocked")
    win.rows[i].item = nil
    win.rows[i]:Hide()
  end
  win.content:SetHeight(math.max(-y, 1))
  win.empty:SetShown(#log == 0)
  win.status:SetText(("Run since |cffffd100%s|r — %d drop%s%s"):format(sinceLabel,
    drops, drops == 1 and "" or "s",
    k > 1 and (" — |cff33cc44split %d ways|r"):format(k) or "   |cff888888not in a group|r"))
  DE.UpdateBroker()
end

--------------------------------------------------------------------------------
-- Options drawer: the guard toggles and the three thresholds, folded away by
-- default because you set them once and forget them.
--------------------------------------------------------------------------------
local function ensureOptions(parent)
  local o = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  o:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -82)
  o:SetSize(WIN_W - 24, LIST_H)
  backdrop(o, 0.85)
  o:EnableMouse(true)
  o:Hide()
  o.checks = {}

  local y = -8
  for _, g in ipairs(GUARDS) do
    local cb = CreateFrame("CheckButton", "DisenchanterGuard" .. g.key, o, "UICheckButtonTemplate")
    cb:SetSize(22, 22)
    cb:SetPoint("TOPLEFT", 8, y)
    cb.key = g.key
    local label = _G[cb:GetName() .. "Text"]
    label:SetFontObject("GameFontHighlightSmall")
    label:SetText(("%s  |cff888888(%s)|r"):format(g.label, g.hard and "protect" or "confirm"))
    cb:SetScript("OnClick", function(self)
      db().guards[self.key] = self:GetChecked() and true or false
      DE.Refresh()
    end)
    o.checks[#o.checks + 1] = cb
    y = y - 22
  end

  local function numberBox(labelText, width, get, set)
    local fs = o:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("TOPLEFT", 12, y - 6)
    fs:SetText(labelText)
    local eb = CreateFrame("EditBox", nil, o, "InputBoxTemplate")
    eb:SetSize(width, 20)
    eb:SetPoint("LEFT", fs, "RIGHT", 12, 0)
    eb:SetAutoFocus(false)
    eb:SetNumeric(true)
    -- Committing lives in OnEditFocusLost so a typed value isn't silently
    -- dropped by clicking elsewhere. Enter just clears focus; Escape reverts
    -- the text first, so the commit that follows is a no-op.
    eb:SetScript("OnEditFocusLost", function(self)
      set(tonumber(self:GetText()) or 0)
      DE.Refresh()
    end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEscapePressed", function(self) self:SetText(tostring(get())); self:ClearFocus() end)
    y = y - 26
    return eb
  end

  o.valueBox = numberBox("Ctrl-click BoEs worth over (gold)", 50,
    function() return db().valueGold end,
    function(v) db().valueGold = math.max(0, v) end)
  o.ilvlBox = numberBox("Ctrl-click above item level (0 = off)", 50,
    function() return db().ilvlCap end,
    function(v) db().ilvlCap = math.max(0, v) end)

  o.quality = CreateFrame("Button", nil, o, "UIPanelButtonTemplate")
  o.quality:SetSize(WIN_W - 48, 22)
  o.quality:SetPoint("TOPLEFT", 12, y - 4)
  o.quality:SetScript("OnClick", function()
    local d = db()
    d.confirmAbove = (d.confirmAbove >= 4) and 2 or (d.confirmAbove + 1)
    DE.Refresh()
  end)
  o.quality:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Plain-click ceiling", 1, 0.82, 0)
    GameTooltip:AddLine("Anything better than this needs a Ctrl-click. Click to cycle.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  o.quality:SetScript("OnLeave", tipHide)

  local hint = o:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 12, 10)
  hint:SetPoint("BOTTOMRIGHT", -12, 10)
  hint:SetJustifyH("LEFT")
  hint:SetText("Keep list: |cffffd100/de keep #itemid|r or |cffffd100/de keep name:text|r, "
    .. "or the padlock on any row.")
  return o
end

function DE.RefreshOptions()
  local o = win and win.opts
  if not o then return end
  local d = db()
  for _, cb in ipairs(o.checks) do cb:SetChecked(d.guards[cb.key] and true or false) end
  o.valueBox:SetText(tostring(d.valueGold))
  o.ilvlBox:SetText(tostring(d.ilvlCap))
  o.quality:SetText("Plain-click up to: " .. (CONFIRM_LABEL[d.confirmAbove] or "?"))
end

--------------------------------------------------------------------------------
local function ensureWindow()
  if win then return win end
  local f = CreateFrame("Frame", "DisenchanterFrame", UIParent,
    BackdropTemplateMixin and "BackdropTemplate" or nil)
  f:SetSize(WIN_W, WIN_H)
  f:SetPoint("CENTER", 0, 60)
  f:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 8, right = 8, top = 8, bottom = 8 },
  })
  f:SetMovable(true)
  f:EnableMouse(true)
  f:SetClampedToScreen(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetFrameStrata("DIALOG")
  f:SetScript("OnShow", function() DE.Refresh() end)
  tinsert(UISpecialFrames, "DisenchanterFrame") -- Esc closes it

  local header = f:CreateTexture(nil, "ARTWORK")
  header:SetTexture("Interface\\DialogFrame\\UI-DialogBox-Header")
  header:SetSize(240, 60)
  header:SetPoint("TOP", 0, 12)
  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOP", header, "TOP", 0, -13)
  title:SetText("Disenchanter")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  win = f
  win.rows, win.heads = {}, {}

  win.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  win.status:SetPoint("TOPLEFT", 16, -30)
  win.status:SetPoint("TOPRIGHT", -16, -30)
  win.status:SetJustifyH("LEFT")

  win.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  win.hint:SetPoint("TOPLEFT", 16, -46)
  win.hint:SetPoint("TOPRIGHT", -16, -46)
  win.hint:SetJustifyH("LEFT")
  win.hint:SetWordWrap(false) -- a long hint truncates rather than spill into the tabs
  win.hint:SetText("Click a green row to disenchant it \226\128\148 Ctrl-click an amber one.")

  -- The two tabs. The active one is disabled: the greyed art reads as
  -- pressed-in, and a highlight font keeps its label legible.
  local function tabButton(label, w, tab)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(w, 20)
    b:SetText(label)
    b:SetDisabledFontObject(GameFontHighlightSmall)
    b:SetScript("OnClick", function() DE.SetTab(tab) end)
    return b
  end
  win.tab = "de"
  win.tabDE = tabButton("Disenchant", 90, "de")
  win.tabDE:SetPoint("TOPLEFT", 12, -60)
  win.tabDE:Disable()
  win.tabTrash = tabButton("Trash", 60, "trash")
  win.tabTrash:SetPoint("LEFT", win.tabDE, "RIGHT", 4, 0)
  win.tabRun = tabButton("Run", 50, "run")
  win.tabRun:SetPoint("LEFT", win.tabTrash, "RIGHT", 4, 0)

  local inset = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  inset:SetPoint("TOPLEFT", 12, -82)
  inset:SetSize(WIN_W - 24, LIST_H)
  backdrop(inset)
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

  -- The options drawer sits over the list, so it has to win on frame level.
  win.opts = ensureOptions(f)
  win.opts:SetFrameLevel(inset:GetFrameLevel() + 20)

  local function mk(label, w)
    local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    b:SetSize(w, 22)
    b:SetText(label)
    return b
  end
  local rescan = mk("Rescan", 80)
  rescan:SetPoint("BOTTOMLEFT", 14, 14)
  rescan:SetScript("OnClick", function() questCache = {}; DE.Refresh() end)

  local optBtn = mk("Options", 80)
  optBtn:SetPoint("LEFT", rescan, "RIGHT", 6, 0)
  optBtn:SetScript("OnClick", function()
    if win.opts:IsShown() then
      win.opts:Hide()
      DE.Refresh()
    else
      DE.RefreshOptions()
      win.opts:Show()
    end
  end)

  local report = mk("To chat", 80)
  report:SetPoint("BOTTOMRIGHT", -14, 14)
  report:SetScript("OnClick", function() DE.Report() end)
  win.rescan, win.optBtn, win.report = rescan, optBtn, report

  -- The Run tab's bottom row, swapped in for Rescan/Options/To chat by SetTab.
  local newRun = mk("New run", 80)
  newRun:SetPoint("BOTTOMLEFT", 14, 14)
  newRun:SetScript("OnClick", function()
    db().splitStart = time()
    pr("run marker set — the Run tab and /de split now count from this moment.")
    DE.Refresh()
  end)
  newRun:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Start a new run", 1, 1, 1)
    GameTooltip:AddLine("Moves the marker to now. Earlier disenchants stay in /de audit but stop counting toward this run's split.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  newRun:SetScript("OnLeave", tipHide)
  newRun:Hide()

  local announce = mk("Announce", 90)
  announce:SetPoint("LEFT", newRun, "RIGHT", 6, 0)
  announce:SetScript("OnClick", function() DE.Split("party") end)
  announce:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Announce the split", 1, 1, 1)
    GameTooltip:AddLine("Posts this run's totals and shares to party or raid chat. Only ever on this click.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
  end)
  announce:SetScript("OnLeave", tipHide)
  announce:Hide()
  win.newRun, win.announce = newRun, announce

  -- Sweeps the casting row's fill each frame; a no-op the rest of the time.
  f:SetScript("OnUpdate", function()
    local row, c = win.castingRow, DE.cast
    if not (row and c and row:IsShown()) then return end
    local prog = math.min((GetTime() - c.startTime) / (c.duration > 0 and c.duration or 1), 1)
    row.castFill:SetWidth(math.max(prog * ROW_W, 0.01))
  end)

  -- CreateFrame hands back a *shown* frame, so without this the first /de would
  -- toggle the window straight to hidden and OnShow would never fire.
  f:Hide()
  return win
end

function DE.Toggle()
  local f = ensureWindow()
  if f:IsShown() then f:Hide() else f:Show() end
end

function DE.SetTab(tab)
  local f = ensureWindow()
  f.tab = tab
  f.tabDE:SetEnabled(tab ~= "de")
  f.tabTrash:SetEnabled(tab ~= "trash")
  f.tabRun:SetEnabled(tab ~= "run")
  local run = tab == "run"
  f.rescan:SetShown(not run)
  f.optBtn:SetShown(not run)
  f.report:SetShown(not run)
  f.newRun:SetShown(run)
  f.announce:SetShown(run)
  if run and f.opts:IsShown() then f.opts:Hide() end
  DE.Refresh()
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
function DE.ToggleKeep(itemID, link)
  local keep = db().keep
  if keep.items[itemID] then
    keep.items[itemID] = nil
    pr((link or ("#" .. itemID)) .. " taken off your keep list.")
  else
    keep.items[itemID] = true
    allowed[itemID] = nil
    pr((link or ("#" .. itemID)) .. " will never be disenchanted.")
  end
  DE.Refresh()
end

function DE.AddKeep(spec)
  if not spec or spec == "" then pr("usage: /de keep <#itemid|name:text>") return end
  local keep = db().keep
  local id = spec:match("^#?(%d+)$")
  if id then
    keep.items[tonumber(id)] = true
    pr((GetItemInfo(tonumber(id)) or ("#" .. id)) .. " added to the keep list.")
  else
    local text = spec:match("^name:(.+)$") or spec
    keep.names[#keep.names + 1] = text
    pr(('anything matching "%s" added to the keep list.'):format(text))
  end
  DE.Refresh()
end

-- Item-id entries sorted ascending, then the name patterns in entry order —
-- Keeps and DeleteKeep must agree on this numbering, so both build it here.
local function keepIDs()
  local ids = {}
  for id in pairs(db().keep.items) do ids[#ids + 1] = id end
  table.sort(ids)
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
    print(("    %d. %s"):format(i, (select(2, GetItemInfo(id))) or ("#" .. id)))
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
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
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
ev:RegisterEvent("GROUP_ROSTER_UPDATE") -- the Run tab's "split N ways" and Announce state

-- Coalesce the burst of BAG_UPDATEs a disenchant produces into one rebuild.
local pending
local function queueRefresh()
  if pending then return end
  pending = true
  C_Timer.After(0.1, function()
    pending = nil
    DE.Refresh() -- updates the broker itself when the window is up
    if not (win and win:IsShown()) then DE.UpdateBroker() end
  end)
end

ev:SetScript("OnEvent", function(_, event, a1, a2, a3)
  if event == "PLAYER_LOGIN" then
    db()
    DE.InitBroker()
    if not knowsDisenchant() then
      -- Still perfectly usable as a "what would this give me" viewer, so this
      -- is a note, not a refusal to load.
      pr("loaded. You don't know Disenchant on this character — |cffffd100/de|r still shows what's in your bags.")
    end

  elseif event == "BAG_UPDATE" then
    -- Disarm immediately: between an item moving and the rebuild landing, a
    -- stale row would point at whatever is now in that slot.
    disarmAll()
    queueRefresh()

  elseif event == "BAG_UPDATE_DELAYED" or event == "GET_ITEM_INFO_RECEIVED" then
    queueRefresh()

  elseif event == "PLAYER_REGEN_DISABLED" then
    -- The rows can't be disarmed here: lockdown is already active by the time
    -- this event fires, so SetAttribute would be rejected. Harmless — the game
    -- refuses to cast Disenchant in combat — so just grey the list.
    if win and win:IsShown() then
      win.content:SetAlpha(0.35)
      win.status:SetText(statusText({}, {}, {}))
    end

  elseif event == "PLAYER_REGEN_ENABLED" or event == "GROUP_ROSTER_UPDATE" then
    queueRefresh()

  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if a1 == "player" and a3 == DE_SPELL then
      lastDE = GetTime()
      -- Grab the consumed item's link before CastFinished clears DE.cast, so
      -- the loot line that follows can be written down as "src → out".
      lastDESource = (DE.cast and DE.cast.link) or (DE._pending and DE._pending.link) or nil
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
    DE.SetTab("trash") -- runs ensureWindow, so `win` is set after it
    win:Show()
  elseif cmd == "run" then
    DE.SetTab("run")
    win:Show()
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
    db().valueGold = math.max(0, g)
    pr(g > 0 and ("BoEs worth more than %s now need a Ctrl-click."):format(money(g * 10000))
      or "value guard off.")
    DE.Refresh()
  elseif cmd == "ilvl" then
    local n = tonumber(args)
    if not n then pr("usage: /de ilvl <n> (0 turns the item-level cap off)") return end
    db().ilvlCap = math.max(0, n)
    pr(n > 0 and ("item level over %d now needs a Ctrl-click."):format(n) or "item-level cap off.")
    DE.Refresh()
  elseif cmd == "confirm" then
    local q = CONFIRM_WORD[args:lower()]
    if not q then pr("usage: /de confirm <green|blue|epic>") return end
    db().confirmAbove = q
    pr("plain-click up to " .. (CONFIRM_LABEL[q] or "?") .. "; anything better needs Ctrl.")
    DE.Refresh()
  elseif cmd == "guard" then
    if args == "" then
      pr("guards (|cffffd100/de guard <name>|r toggles one):")
      for _, g in ipairs(GUARDS) do
        print(("    %-9s %s  %s"):format(g.key,
          db().guards[g.key] and "|cff33cc44on |r" or "|cffff5555off|r", g.label))
      end
      return
    end
    local key = args:lower()
    local known = false
    for _, g in ipairs(GUARDS) do if g.key == key then known = true end end
    if not known then pr("no guard called '" .. key .. "'. |cffffd100/de guard|r lists them.") return end
    local d = db()
    d.guards[key] = not d.guards[key]
    pr(("guard %s is now %s."):format(key, d.guards[key] and "|cff33cc44on|r" or "|cffff5555off|r"))
    DE.Refresh()
  elseif cmd == "learned" then
    DE.Learned(args:lower() == "clear")
  elseif cmd == "tally" then
    DE.Tally()
  elseif cmd == "audit" then
    DE.Audit(args)
  elseif cmd == "split" then
    DE.Split(args)
  elseif cmd == "debug" then
    DE.Debug()
  elseif cmd == "mode" then
    local d = db()
    d.clickMode = (d.clickMode == "macro") and "spell" or "macro"
    pr("click mode: |cffffd100" .. d.clickMode .. "|r")
    DE.Refresh()
  else
    pr("commands: (no args) | trash | run | scan | keep <#id|name:text> | keep del <n> | keeps | value <gold> | ilvl <n> | confirm <green|blue|epic> | guard [name] | learned [clear] | tally | audit [n|clear] | split [start|say|party|raid] | mode | debug")
  end
end

SLASH_DISENCHANTER1 = "/de"
SLASH_DISENCHANTER2 = "/disenchanter"
SlashCmdList.DISENCHANTER = function(msg) DE.Command(msg) end
