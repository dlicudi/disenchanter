local function loadWith(env)
  for k, v in pairs(env) do _G[k] = v end
  DisenchanterCompat = nil
  dofile(arg[1])
  return DisenchanterCompat.Container
end

local modern = loadWith({
  C_Container = {
    GetContainerNumSlots = function() return 9 end,
    GetContainerItemInfo = function() return { itemID = 12 } end,
    PickupContainerItem = function() _G.picked = "modern" end,
  },
})
assert(modern.GetContainerNumSlots(0) == 9)
assert(modern.GetContainerItemInfo(0, 1).itemID == 12)
modern.PickupContainerItem(0, 1); assert(picked == "modern")

C_Container = nil
GetContainerNumSlots = function() return 7 end
GetContainerItemInfo = function()
  return 123, 4, false, 2, false, false, "|Hitem:55:0|h[x]|h", false, false, 55, true
end
PickupContainerItem = function() _G.picked = "legacy" end
local legacy = loadWith({})
local info = legacy.GetContainerItemInfo(0, 1)
assert(legacy.GetContainerNumSlots(0) == 7 and info.itemID == 55 and info.stackCount == 4 and info.isBound)
legacy.PickupContainerItem(0, 1); assert(picked == "legacy")
print("compatibility checks OK")
