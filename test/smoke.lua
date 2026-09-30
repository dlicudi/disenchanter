local steps, failed = 0, 0
local function step(name, fn)
  steps = steps + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end
local Frame = {}
Frame.__index = function(t, k) if type(k)=="string" and k:match("^%u") then return function() return t._make() end end end
local function stub()
  local f=setmetatable({_shown=true,_scripts={},_attr={}},Frame); f._make=stub
  f.SetScript=function(s,k,v)s._scripts[k]=v end; f.GetScript=function(s,k)return s._scripts[k] end
  f.Show=function(s)s._shown=true;if s._scripts.OnShow then s._scripts.OnShow(s) end end
  f.Hide=function(s)s._shown=false;if s._scripts.OnHide then s._scripts.OnHide(s) end end
  f.IsShown=function(s)return s._shown end; f.SetShown=function(s,v)if v then s:Show() else s:Hide() end end
  f.SetAttribute=function(s,k,v)s._attr[k]=v end; f.GetAttribute=function(s,k)return s._attr[k] end
  f.CreateFontString=function()return stub()end; f.CreateTexture=function()return stub()end
  f.GetWidth=function()return 380 end; f.GetHeight=function()return 460 end
  f.GetFrameLevel=function()return 1 end
  f.GetName=function(s)return s._name end
  return f
end
UIParent=stub(); GameTooltip=stub(); CreateFrame=function(_,name)local f=stub();f._name=name;if name then _G[name.."Text"]=stub()end;return f end; SlashCmdList={}; UISpecialFrames={}
tinsert,tremove=table.insert,table.remove
WOW_PROJECT_CLASSIC,WOW_PROJECT_ID=2,2; NUM_BAG_SLOTS=4
ITEM_QUALITY_COLORS=setmetatable({},{__index=function()return{hex="|cffffffff"}end})
GetTime=function()return 100 end; time=function()return 1000 end; date=function()return"00:00"end
GetCoinTextureString=function(v)return tostring(v)end; GetNumSkillLines=function()return 0 end
IsSpellKnown=function()return true end; InCombatLockdown=function()return _G.IN_COMBAT or false end
IsControlKeyDown=function()return false end; ClearCursor=function()end; LibStub=nil
C_Timer={After=function(_,fn)fn()end}; C_Container={GetContainerNumSlots=function()return 0 end,GetContainerItemInfo=function()return nil end}
dofile(arg[1]); local DE=Disenchanter; DE._event("PLAYER_LOGIN")
local function item(q) local x={itemID=1,name="Test",quality=2,ilvl=10,boe=true,value=10000};for k,v in pairs(q or{})do x[k]=v end;return x end
step("value zero disables disenchant guard",function()DisenchanterDB.valueGold=0;assert(DE._verdict(item(),nil)=="safe")end)
step("positive value threshold guards BoEs",function()DisenchanterDB.valueGold=1;assert(DE._verdict(item({value=20000}),nil)=="confirm")end)
step("value zero disables trash guard",function()DisenchanterDB.valueGold=0;assert(DE._trashVerdict(item({quality=1}))=="confirm")end)
step("slash toggles window",function()local w=DE._window();if w:IsShown()then w:Hide()end;DE.Command("");assert(w:IsShown());DE.Command("");assert(not w:IsShown())end)
step("combat toggle is deferred",function()local w=DE._window();IN_COMBAT=true;DE.Command("");assert(not w:IsShown());IN_COMBAT=false;DE._event("PLAYER_REGEN_ENABLED");assert(w:IsShown())end)
print(("%d steps, %d failed"):format(steps,failed));if failed>0 then os.exit(1)end
