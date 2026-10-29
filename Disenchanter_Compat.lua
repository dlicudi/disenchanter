-- Client API normalization. Keep version differences out of the safety-critical
-- scan and click code in Disenchanter.lua.
DisenchanterCompat = DisenchanterCompat or {}
local A = DisenchanterCompat

local modern = C_Container
A.Container = {}

function A.Container.GetContainerNumSlots(bag)
  if modern and modern.GetContainerNumSlots then return modern.GetContainerNumSlots(bag) end
  if GetContainerNumSlots then return GetContainerNumSlots(bag) end
  return 0
end

function A.Container.GetContainerItemInfo(bag, slot)
  if modern and modern.GetContainerItemInfo then return modern.GetContainerItemInfo(bag, slot) end
  if not GetContainerItemInfo then return nil end
  local icon, count, locked, quality, readable, lootable, link, filtered,
    noValue, itemID, bound = GetContainerItemInfo(bag, slot)
  if not icon and not itemID then return nil end
  if not itemID and link then itemID = tonumber(link:match("item:(%d+)")) end
  return {
    iconFileID = icon, stackCount = count, isLocked = locked,
    quality = quality, isReadable = readable, hasLoot = lootable,
    hyperlink = link, isFiltered = filtered, hasNoValue = noValue,
    itemID = itemID, isBound = bound,
  }
end

function A.Container.PickupContainerItem(bag, slot)
  if modern and modern.PickupContainerItem then modern.PickupContainerItem(bag, slot); return true end
  if PickupContainerItem then PickupContainerItem(bag, slot); return true end
  return false
end
