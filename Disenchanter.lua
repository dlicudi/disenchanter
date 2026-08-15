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

     DisenchanterDB = {
       keep    = { items = { [12345] = true }, names = { "heirloom", ... } },
       guards  = { quest = true, use = true, set = true, ... },  -- see GUARDS
       confirmAbove = 2,   -- quality above this needs a Ctrl-click (2 = green)
       valueGold    = 10,  -- BoEs worth more than this need a Ctrl-click
       ilvlCap      = 0,   -- 0 = off; above this needs a Ctrl-click
       learned = { [12345] = true },  -- server told us these can't be DE'd
       collapsed = { safe = false, confirm = false, blocked = false },
     }

  Safety: the addon never casts anything on its own. Each row is a secure
  button carrying a plain `/cast Disenchant` + `/use <bag> <slot>` macro, so a
  cast only ever happens on YOUR click, on the row YOU clicked — Blizzard's
  own protected-call rules make anything else impossible. The moment your bags
  change every row is disarmed until the list has been rebuilt, so a row can
  never fire at an item that has since moved into that slot.

  If a LibDataBroker display is installed (Titan Panel, Bazooka, ...) a
  "Disenchanter" plugin appears showing the safe / check-first counts; click
  opens the window, right-click prints the chat report. No libraries are
  bundled — the object registers only when another addon provides LDB, and
  everything else works the same without it.

  Commands:
     /de                      open the window
     /de scan                 print the verdicts to chat
     /de keep <#id|name:text> never disenchant this
     /de keep del <n>         drop keep-list entry n
     /de keeps                list the keep list
     /de value <gold>         BoE value that needs a Ctrl-click (0 = off)
     /de ilvl <n>             item level that needs a Ctrl-click (0 = off)
     /de confirm <green|blue|epic>  quality above which a Ctrl-click is needed
     /de guard <name>         toggle a guard (no name = list them)
     /de tally                what you've disenchanted this session
]]

local DE = {}
Disenchanter = DE -- global, mostly for /dump poking

local C = C_Container
local DE_SPELL   = 13262 -- Disenchant
local ENCH_SPELL = 7411  -- Enchanting (for the skill-line name)

local function pr(msg) print("|cffa335eeDisenchanter:|r " .. msg) end

--- The localised spell name for the macro. The Anniversary client rides the
--- modern engine, where GetSpellInfo has variously returned a name, returned a
--- table, and stopped existing — so try every shape and fall back to the enUS
--- name rather than letting a nil reach string.format.
local function deName()
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, DE_SPELL)
    if ok and type(info) == "table" and type(info.name) == "string" then return info.name end
  end
  if GetSpellInfo then
    local ok, a = pcall(GetSpellInfo, DE_SPELL)
    if ok then
      if type(a) == "string" then return a end
      if type(a) == "table" and type(a.name) == "string" then return a.name end
    end
  end
  return "Disenchant"
end

--------------------------------------------------------------------------------
-- What disenchanting an item is likely to give you, and what skill it needs.
-- Bands are {maxItemLevel, requiredSkill, "likely mats"} for one quality; the
-- roll inside a band is dust vs essence vs shard, so all three are listed.
-- Approximate on purpose — it's a hint for "is this worth my time", not a
-- promise. TBC (2.5.x) tables.
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
local function useContainerItem(bag, slot)
  if C and C.UseContainerItem then return C.UseContainerItem(bag, slot) end
  if UseContainerItem then return UseContainerItem(bag, slot) end
end

--- Your Enchanting rank, or nil if we can't see it (collapsed skill headers).
local function enchantingSkill()
  local want = (GetSpellInfo(ENCH_SPELL)) or "Enchanting"
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
    local link = GetInventoryItemLink("player", s)
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
-- Session tally: what the last few casts actually produced. Loot lines that
-- land within a couple of seconds of a Disenchant completing are attributed to
-- it, which is imprecise if you're looting a mob at the same instant and
-- perfectly good otherwise.
--------------------------------------------------------------------------------
DE.tally = {}
local lastDE = 0

local function noteLoot(msg)
  if GetTime() - lastDE > 3 then return end
  local link, count = msg:match("(|c%x+|Hitem:.-|h.-|h|r)%s*x?(%d*)")
  if not link then return end
  DE.tally[link] = (DE.tally[link] or 0) + (tonumber(count) or 1)
end

function DE.Tally()
  local n = 0
  for link, count in pairs(DE.tally) do
    n = n + 1
    print(("    %s x%d"):format(link, count))
  end
  if n == 0 then pr("nothing disenchanted this session yet.") else pr("this session:") end
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

local function isCollapsed(key) return db().collapsed[key] == true end

-- SecureButton_GetModifiedAttribute looks up "<modifier>type<button>" and falls
-- back through progressively less specific names — but which string it uses for
-- <button> ("", "1" or "LeftButton") has moved around between client versions.
-- Writing all three costs nothing and takes the guesswork out of it.
-- Left-click only. Deliberately no unsuffixed ("type") variant: the rows are
-- registered for any button so the secure handler sees the down event, and a
-- bare "type" would answer a right-click too.
local CLICK_SUFFIX = { "1", "LeftButton" }

local function setAction(row, prefix, atype, value)
  for _, sfx in ipairs(CLICK_SUFFIX) do
    row:SetAttribute(prefix .. "type" .. sfx, atype)
    row:SetAttribute(prefix .. "macrotext" .. sfx, atype == "macro" and value or nil)
    row:SetAttribute(prefix .. "spell" .. sfx, atype == "spell" and value or nil)
  end
end

--- Point a row at a bag slot, or at nothing. `tier` decides which click fires
--- it: safe rows take a plain left-click, "check first" rows only fire with
--- Ctrl held, protected rows are never armed at all.
---
--- The Ctrl gate works by only ever writing "ctrl-"-prefixed attributes: with no
--- modifier held the lookup finds nothing and the click is a genuine no-op.
---
--- Two ways to fire, swappable with /de mode:
---   "macro" (default) — one `/cast` + `/use` macrotext, all inside the secure
---     handler. The conventional approach and the one to prefer.
---   "spell"           — the secure button only casts Disenchant, leaving it on
---     the cursor for PostClick to apply with UseContainerItem (not protected).
---     Kept as a second path in case a patch breaks macrotext.
local function arm(row, tier, bag, slot)
  setAction(row, "", nil, nil)
  setAction(row, "ctrl-", nil, nil)
  row.deBag, row.deSlot, row.deTier = nil, nil, nil
  if not (bag and slot and tier ~= "blocked") then return end
  local prefix = (tier == "safe") and "" or "ctrl-"
  if db().clickMode == "macro" then
    setAction(row, prefix, "macro", ("/cast %s\n/use %d %d"):format(deName(), bag, slot))
  else
    setAction(row, prefix, "spell", deName())
  end
  row.deBag, row.deSlot, row.deTier = bag, slot, tier
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
    pr(("%s allowed for this session — Ctrl-click to disenchant it."):format(it.link))
    DE.Refresh()
  end)
  row.allow:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Ignore the guard for this session", 1, 1, 1)
    GameTooltip:AddLine("The row moves to Check first; a Ctrl-click will then disenchant it. Forgotten on logout.", 0.6, 0.6, 0.6, true)
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
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetBagItem(it.bag, it.slot)
    GameTooltip:AddLine(" ")
    if it.yield then GameTooltip:AddLine("Disenchants into: " .. it.yield, 0.6, 0.85, 1, true) end
    if it.value then
      GameTooltip:AddLine(("Worth %s%s"):format(money(it.value),
        it.valueSrc == "ah" and " on the AH" or " to a vendor"), 0.9, 0.9, 0.6)
    end
    if it.tier == "safe" then
      GameTooltip:AddLine("Click to disenchant.", 0.4, 1, 0.4)
    elseif it.tier == "confirm" then
      GameTooltip:AddLine("Held back: " .. (it.reason or "?"), 1, 0.82, 0)
      GameTooltip:AddLine("Ctrl-click to disenchant anyway.", 1, 0.82, 0)
    else
      GameTooltip:AddLine("Protected: " .. (it.reason or "?"), 1, 0.4, 0.4, true)
      GameTooltip:AddLine(it.permanent and "Use the padlock to take it off your keep list."
        or "Press Allow to override for this session.", 0.6, 0.6, 0.6, true)
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
    if not it then return end
    local now = C.GetContainerItemInfo(it.bag, it.slot)
    DE._pending = (now and now.itemID == it.itemID) and it or nil
    DE._pendingAt = GetTime()
  end)

  -- PostClick runs straight after the secure handler. In "spell" mode that's
  -- where the job is finished: the secure half has put Disenchant on the cursor
  -- and UseContainerItem — which needs no secure context — applies it to the
  -- slot this row was armed for. The SpellIsTargeting() gate means we only ever
  -- complete a cast the click itself started.
  row:SetScript("PostClick", function(self)
    -- The tier gate is re-checked here, not just in the attributes, so a plain
    -- click on a Ctrl-only row can't be completed by this half either.
    local gated = self.deBag and (self.deTier == "safe" or IsControlKeyDown())
    local targeting = SpellIsTargeting and SpellIsTargeting()
    -- Only "spell" mode needs finishing off: the secure half has put Disenchant
    -- on the cursor and UseContainerItem, which isn't protected, applies it.
    -- In "macro" mode the /use line has already done this. The targeting gate
    -- means we only ever complete a cast this very click started — and it makes
    -- the handler harmless on the click edge the secure handler ignored.
    local applied = false
    if gated and targeting then
      useContainerItem(self.deBag, self.deSlot)
      applied = true
    end
    if DE.trace then
      pr(("POST mode=%s targeting=%s applied=%s"):format(
        db().clickMode or "macro", tostring(targeting), tostring(applied)))
    end
  end)

  win.rows[i] = row
  return row
end

local function statusText(safe, confirm, blocked)
  if not knowsDisenchant() then
    return "|cffff5555You don't know Disenchant.|r Rows are listed but nothing will cast."
  end
  if InCombatLockdown() then
    return "|cffff5555In combat|r — the list is frozen until you're out."
  end
  local skill = enchantingSkill()
  return ("|cff33cc44%d safe|r, |cffffd100%d to check|r, |cffff5555%d protected|r%s")
    :format(#safe, #confirm, #blocked, skill and ("   |cff888888Enchanting " .. skill .. "|r") or "")
end

function DE.Refresh()
  if not (win and win:IsShown()) then return end
  if InCombatLockdown() then
    win.status:SetText(statusText({}, {}, {}))
    return -- SetAttribute is forbidden in combat; PLAYER_REGEN_ENABLED redraws
  end
  local safe, confirm, blocked = DE.Scan()
  local lists = { safe = safe, confirm = confirm, blocked = blocked }

  win.castingRow = nil
  local hi, ri, y = 0, 0, 0
  for _, b in ipairs(BUCKETS) do
    local list = lists[b.key]
    hi = hi + 1
    local head = headerRow(hi)
    head.key = b.key
    head.toggle:SetTexture(isCollapsed(b.key) and PLUS or MINUS)
    head.text:SetText(("%s%s|r  |cff888888(%d)|r"):format(b.color, b.title, #list))
    head:ClearAllPoints(); head:SetPoint("TOPLEFT", 0, y)
    head:Show()
    y = y - HEAD_H

    if not isCollapsed(b.key) then
      for _, it in ipairs(list) do
        ri = ri + 1
        local row = itemRow(ri)
        row.item = it
        row.icon:SetTexture(it.icon or FALLBACK_ICON)
        row.icon:SetDesaturated(it.tier == "blocked")
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
        row.castFill:SetShown(it.casting and true or false)
        if it.casting then win.castingRow = row end
        row.lock:SetNormalTexture(db().keep.items[it.itemID] and LOCKED or UNLOCKED)
        row.allow:SetShown(it.tier == "blocked" and not it.permanent)
        -- A casting row is never armed: its item is locked, so a second click
        -- could only produce an error mid-cast.
        arm(row, it.casting and "blocked" or it.tier, it.bag, it.slot)
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
end

--------------------------------------------------------------------------------
-- Options drawer: the guard toggles and the three thresholds, folded away by
-- default because you set them once and forget them.
--------------------------------------------------------------------------------
local function ensureOptions(parent)
  local o = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
  o:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -70)
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
    eb:SetScript("OnEnterPressed", function(self)
      set(tonumber(self:GetText()) or 0)
      self:ClearFocus()
      DE.Refresh()
    end)
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
  win.hint:SetText("Click a green row to disenchant it \226\128\148 Ctrl-click an amber one.")

  local inset = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
  inset:SetPoint("TOPLEFT", 12, -62)
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
    c = { itemID = it.itemID, bag = it.bag, slot = it.slot }
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
  pr(("secure: protected=%s onclick=%s handler=%s useContainerItem=%s"):format(
    tostring(row:IsProtected()), tostring(row:GetScript("OnClick") ~= nil),
    tostring(SecureActionButton_OnClick ~= nil),
    tostring((C and C.UseContainerItem ~= nil) or UseContainerItem ~= nil)))
  for _, name in ipairs({ "type", "type1", "typeLeftButton", "spell", "spell1",
                          "macrotext", "macrotext1", "ctrl-type1" }) do
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

function DE.Keeps()
  local keep = db().keep
  local i = 0
  local rows = {}
  for id in pairs(keep.items) do
    i = i + 1
    rows[i] = { n = i, text = (select(2, GetItemInfo(id))) or ("#" .. id) }
  end
  for _, name in ipairs(keep.names) do
    i = i + 1
    rows[i] = { n = i, text = ('name: "%s"'):format(name) }
  end
  if i == 0 then pr("keep list is empty.") return end
  pr("keep list:")
  for _, r in ipairs(rows) do print(("    %d. %s"):format(r.n, r.text)) end
  print("    |cff888888/de keep del <n> removes one.|r")
end

function DE.DeleteKeep(n)
  local keep = db().keep
  local ids = {}
  for id in pairs(keep.items) do ids[#ids + 1] = id end
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

--- Refresh the panel text: green safe count, amber check-first count.
function DE.UpdateBroker()
  if not broker then return end
  local safe, confirm = DE.Scan()
  broker.text = ("|cff33cc44%d|r |cffffd100%d|r"):format(#safe, #confirm)
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

-- Coalesce the burst of BAG_UPDATEs a disenchant produces into one rebuild.
local pending
local function queueRefresh()
  if pending then return end
  pending = true
  C_Timer.After(0.1, function() pending = nil; DE.Refresh(); DE.UpdateBroker() end)
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
    disarmAll()
    if win and win:IsShown() then win.status:SetText(statusText({}, {}, {})) end

  elseif event == "PLAYER_REGEN_ENABLED" then
    queueRefresh()

  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if a1 == "player" and a3 == DE_SPELL then
      lastDE = GetTime()
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
    pr(("BoEs worth more than %s now need a Ctrl-click."):format(money(g * 10000)))
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
  elseif cmd == "tally" then
    DE.Tally()
  elseif cmd == "debug" then
    DE.Debug()
  elseif cmd == "mode" then
    local d = db()
    d.clickMode = (d.clickMode == "macro") and "spell" or "macro"
    pr("click mode: |cffffd100" .. d.clickMode .. "|r")
    DE.Refresh()
  else
    pr("commands: (no args) | scan | keep <#id|name:text> | keep del <n> | keeps | value <gold> | ilvl <n> | confirm <green|blue|epic> | guard [name] | tally | debug")
  end
end

SLASH_DISENCHANTER1 = "/de"
SLASH_DISENCHANTER2 = "/disenchanter"
SlashCmdList.DISENCHANTER = function(msg) DE.Command(msg) end
