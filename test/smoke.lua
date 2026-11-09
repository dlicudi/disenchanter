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
  f.NumLines=function()return 0 end
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
GetItemInfo=function(...)if ITEM_INFO then return ITEM_INFO(...) end end -- the addon captures this at load
C_Timer={After=function(delay,fn)if delay < 1 then fn() end end}; C_Container={GetContainerNumSlots=function()return 0 end,GetContainerItemInfo=function()return nil end}
dofile(arg[1]); dofile(arg[2]); dofile(arg[3]); dofile(arg[4]); local DE=Disenchanter; DE._event("PLAYER_LOGIN")
local function item(q) local x={itemID=1,name="Test",quality=2,ilvl=10,boe=true,value=10000};for k,v in pairs(q or{})do x[k]=v end;return x end
step("value zero disables disenchant guard",function()DisenchanterDB.valueGold=0;assert(DE._verdict(item(),nil)=="safe")end)
step("positive value threshold guards BoEs",function()DisenchanterDB.valueGold=1;assert(DE._verdict(item({value=20000}),nil)=="confirm")end)
step("guard precedence protects before confirming",function()
  DisenchanterDB.guards.quest=true;DisenchanterDB.confirmAbove=2
  local tier,reason=DE._verdict(item({quality=4,isQuest=true}),nil)
  assert(tier=="blocked" and reason=="quest item")
end)
step("quality and item-level confirmation gates work",function()
  local d=DE._db();d.guards.quest=false;d.valueGold=0;d.confirmAbove=2;d.ilvlCap=0
  assert(DE._verdict(item({quality=3}),nil)=="confirm")
  d.confirmAbove=4;d.ilvlCap=9;assert(DE._verdict(item({quality=2,ilvl=10}),nil)=="confirm")
end)
step("value zero disables trash guard",function()DisenchanterDB.valueGold=0;assert(DE._trashVerdict(item({quality=1}))=="confirm")end)
step("profit estimate requires and uses market prices",function()
  Auctionator={API={v1={GetAuctionPriceByItemID=function(_,id)return id and 100 or nil end}}}
  assert(DE._expectedDisenchantValue(2,20)>0)
  Auctionator=nil;assert(DE._expectedDisenchantValue(2,20)==nil)
end)
step("yield bands share display and pricing data",function()
  for quality,bands in pairs(DisenchanterData.bands) do
    assert(quality>=2 and quality<=4 and #bands>0)
    local previous=0
    for _,band in ipairs(bands) do
      assert(band[1]>previous and type(band[2])=="number" and type(band[3])=="string")
      assert(type(band[4])=="table" and type(band[4][1])=="number")
      previous=band[1]
    end
  end
end)
step("slash toggles window",function()local w=DE._window();if w:IsShown()then w:Hide()end;DE.Command("");assert(w:IsShown());DE.Command("");assert(not w:IsShown())end)
step("run and history commands select separate tabs",function()
  local w=DE._window();DE.Command("run");assert(w.tab=="split")
  DE.Command("history");assert(w.tab=="history");w:Hide()
end)
step("combat toggle is deferred",function()local w=DE._window();IN_COMBAT=true;DE.Command("");assert(not w:IsShown());IN_COMBAT=false;DE._event("PLAYER_REGEN_ENABLED");assert(w:IsShown())end)
step("bag events rebuild quickly, with no input blocker over the list",function()
  local w=DE._window();local timers={};local immediate=C_Timer.After
  C_Timer.After=function(delay,fn)timers[#timers+1]={delay,fn} end
  DE._event("ITEM_LOCK_CHANGED",0,1);DE._event("BAG_UPDATE",0);DE._event("BAG_UPDATE_DELAYED")
  assert(w.scanBlocker==nil and #timers==1 and timers[1][1]<=0.2) -- one short, coalesced rebuild
  timers[1][2]();DE._event("BAG_UPDATE",0);assert(#timers==2);timers[2][2]()
  C_Timer.After=immediate
end)
step("row order holds across bag updates and re-sorts on request",function()
  local w=DE._window();local d=DE._db()
  for k in pairs(d.guards) do d.guards[k]=false end
  d.valueGold=0;d.confirmAbove=4;d.ilvlCap=0;d.sortProfit=false;d.collapsed.safe=false
  local bags={{itemID=11},{itemID=13}}
  local numSlots,itemInfo=C_Container.GetContainerNumSlots,C_Container.GetContainerItemInfo
  C_Container.GetContainerNumSlots=function(bag)return bag==0 and 4 or 0 end
  C_Container.GetContainerItemInfo=function(bag,slot)return bag==0 and bags[slot] or nil end
  ITEM_INFO=function(id)return "Item"..id,"item:"..id,2,10,nil,nil,nil,nil,"INVTYPE_CHEST",nil,id*100,4,1,1 end
  local function shown()
    local names={}
    for _,row in ipairs(w.rows) do if row:IsShown() and row.item then names[#names+1]=row.item.name end end
    return table.concat(names," ")
  end
  DE.SetTab("disenchant");assert(shown()=="Item11 Item13",shown())
  bags[3]={itemID=12};DE._event("BAG_UPDATE",0)
  assert(shown()=="Item11 Item13 Item12",shown()) -- cheaper than Item13, but it joins the bottom
  assert(w.rows[3]._attr["target-slot1"]==3)     -- and its row is armed at its own slot
  bags[1]=nil;DE._event("BAG_UPDATE",0);assert(shown()=="Item13 Item12",shown())
  bags[2]=nil;DE._event("ITEM_LOCK_CHANGED",0,2);assert(shown()=="Item12",shown()) -- picked up...
  bags[2]={itemID=13};DE._event("BAG_UPDATE",0);assert(shown()=="Item13 Item12",shown()) -- ...and put back in place
  w.rescan:GetScript("OnClick")();assert(shown()=="Item12 Item13",shown())
  bags[4]={itemID=11};DE._event("BAG_UPDATE",0);assert(shown()=="Item12 Item13 Item11",shown())
  w:Hide();w:Show();assert(shown()=="Item11 Item12 Item13",shown()) -- reopening sorts afresh
  C_Container.GetContainerNumSlots,C_Container.GetContainerItemInfo,ITEM_INFO=numSlots,itemInfo,nil
  DE.Resort();assert(shown()=="")
end)
step("malformed saved variables are repaired",function()
  DisenchanterDB={keep="bad",learned=true,audit={{bad=true}},guards={quest="yes"},collapsed=3,panel=false,confirmAbove=99,valueGold="-2",ilvlCap="7"}
  local d=DE._db();assert(type(d.keep)=="table" and type(d.guards)=="table");assert(#d.audit==0);assert(d.confirmAbove==2 and d.valueGold==0 and d.ilvlCap==7)
  assert(d.guards.quest==true and d.guards.boe==false and d.schemaVersion==1)
  assert(d.collapsed.blocked==true and d.collapsed.tblocked==true)
end)
step("audit ignores unrelated loot",function()
  local material="|cffffffff|Hitem:10940:0|h[Strange Dust]|h|r"
  local unrelated="|cffffffff|Hitem:6948:0|h[Hearthstone]|h|r"
  LOOT_ITEM_SELF="You receive loot: %s."
  DE._event("UNIT_SPELLCAST_SUCCEEDED","player",nil,13262)
  DE._noteLoot("You receive loot: "..unrelated..".")
  assert(DE.tally[unrelated]==nil)
  DE._noteLoot("You receive loot: "..material.." x2.")
  assert(DE.tally[material]==2)
  local second="|cffffffff|Hitem:10939:0|h[Greater Magic Essence]|h|r"
  DE._noteLoot("You receive loot: "..second..".")
  assert(DE.tally[second]==nil)
end)
step("trash deletion is verified before audit",function()
  local current={itemID=77,stackCount=2};local deleted=false
  C_Container.GetContainerItemInfo=function()return current end
  C_Container.PickupContainerItem=function()end
  CursorHasItem=function()return true end
  DeleteCursorItem=function()deleted=true;current=nil end
  local before=#DE._db().audit
  local ok=DE._deleteTrash({itemID=77,count=2,link="item:77"},0,1)
  assert(ok and deleted and #DE._db().audit==before+1)
  current={itemID=78,stackCount=1};DeleteCursorItem=function()end
  before=#DE._db().audit
  ok=DE._deleteTrash({itemID=78,count=1,link="item:78"},0,1)
  assert(ok==nil and #DE._db().audit==before)
  current=nil;DE._finishPendingTrash();assert(#DE._db().audit==before+1)
end)
step("trash deletion rejects a different item instance",function()
  local current={itemID=90,stackCount=1,hyperlink="item:90:variant-b",isBound=true}
  C_Container.GetContainerItemInfo=function()return current end
  local picked=false;C_Container.PickupContainerItem=function()picked=true end
  local ok=DE._deleteTrash({itemID=90,count=1,link="item:90:variant-a",isBound=false},0,1)
  assert(ok==false and picked==false)
end)
step("item variants get distinct keys; plain items keep their numeric id",function()
  local magic="|cnIQ2:|Hitem:727::::::::12:1490:::1:12917::::::|h[Notched Shortsword of Magic]|h|r"
  local healing="|cnIQ2:|Hitem:727::::::::12:1490:::1:12918::::::|h[Notched Shortsword of Healing]|h|r"
  local km,kh=DE._itemKey(magic,727),DE._itemKey(healing,727)
  assert(type(km)=="string" and type(kh)=="string" and km~=kh)
  -- link level and unique id are per-copy noise, not identity
  assert(DE._itemKey("|cnIQ2:|Hitem:727:::::::99:9:1490:::1:12917::::::|h[x]|h|r",727)==km)
  -- classic suffix field
  local owl="|cff1eff00|Hitem:9775::::::758:873899392:23::::::::::|h[Bandit Cinch of the Owl]|h|r"
  local bear="|cff1eff00|Hitem:9775::::::759:873899392:23::::::::::|h[Bandit Cinch of the Bear]|h|r"
  assert(DE._itemKey(owl,9775)~=DE._itemKey(bear,9775))
  assert(DE._itemKey("|cffffffff|Hitem:10940::::::::23::::::::::|h[Strange Dust]|h|r",10940)==10940)
  assert(DE._itemKey("|cnIQ0:|Hitem:3379::::::::25:1490::1::1:28:5237:::::|h[Brocade Bracers]|h|r",3379)==3379)
  assert(DE._itemKey(nil,5)==5 and DE._itemKey("item:10940:0",10940)==10940)
end)
step("the padlock keeps one variant; a bare id keeps them all",function()
  local d=DE._db();d.keep.items={};d.keep.names={};d.guards.quest=false;d.valueGold=0;d.confirmAbove=4;d.ilvlCap=0
  local function sword(bonus,suffix)
    local link="|cnIQ2:|Hitem:727::::::::12:1490:::1:"..bonus.."::::::|h[Notched Shortsword of "..suffix.."]|h|r"
    return item({itemID=727,boe=false,link=link,key=DE._itemKey(link,727),name="Notched Shortsword of "..suffix})
  end
  local magic,healing=sword(12917,"Magic"),sword(12918,"Healing")
  DE.ToggleKeep(magic)
  assert(DE._verdict(magic,nil)=="blocked" and DE._verdict(healing,nil)=="safe")
  DE.Keeps() -- mixed number/string keys must sort without erroring
  d.keep.items[727]=true;DE.Keeps()
  local tier,reason=DE._verdict(healing,nil)
  assert(tier=="blocked" and reason:find("every version",1,true))
  DE.ToggleKeep(healing) -- unlocking a row covered by the bare id removes that entry
  assert(d.keep.items[727]==nil and DE._verdict(healing,nil)=="safe" and DE._verdict(magic,nil)=="blocked")
  DE.ToggleKeep(magic);assert(next(d.keep.items)==nil)
  DE.AddKeep(healing.link);assert(DE._verdict(healing,nil)=="blocked" and DE._verdict(magic,nil)=="safe")
  -- variant entries survive a reload's repair pass; junk keys still don't
  DisenchanterDB={keep={items={[727]=true,[healing.key]=healing.link,bad=true,["1:x"]=true,[5]="link"},names={}}}
  local r=DE._db().keep.items
  assert(r[727]==true and r[healing.key]==healing.link and r.bad==nil and r["1:x"]==nil and r[5]==nil)
end)
step("audit reads 1.60-style item links",function()
  local dust="|cnIQ1:|Hitem:10940::::::::13:1490:::::::::|h[Strange Dust]|h|r"
  local before=#DE._db().audit
  DE._event("UNIT_SPELLCAST_SUCCEEDED","player",nil,13262)
  DE._noteLoot("You receive loot: "..dust.."x3.")
  assert(DE.tally[dust]==3 and #DE._db().audit==before+1)
end)
step("run totals merge one material across level-ups",function()
  local d=DE._db();d.runs={};d.splitStart=999;d.runName=nil
  d.audit={{t=1000,out="|cffffffff|Hitem:11083::::::::26::::::::::|h[Soul Dust]|h|r",n=2},
           {t=1001,out="|cffffffff|Hitem:11083::::::::27::::::::::|h[Soul Dust]|h|r",n=3}}
  DE.RunHistory("end")
  assert(#d.runs==1 and #d.runs[1].totals==1 and d.runs[1].totals[1].n==5)
end)
step("completed runs are archived independently of the audit",function()
  local d=DE._db();d.runs={};d.splitStart=999;d.runName="Test run"
  d.audit={{t=1000,out="item:10940",n=2,src="item:1"}}
  DE.RunHistory("end")
  assert(#d.runs==1 and d.runs[1].name=="Test run" and d.runs[1].totals[1].n==2)
end)
step("drops since login archive without a marker, and only once",function()
  local d=DE._db();d.runs={};d.splitStart=nil;d.runName=nil
  d.audit={{t=1000,out="item:10940",n=2}}
  local now=1005;time=function()return now end
  DE.Split("start")
  assert(#d.runs==1 and d.runs[1].start==1000 and d.runs[1].totals[1].n==2 and d.splitStart==1005)
  DE.RunHistory("end");assert(#d.runs==1 and d.splitStart==1005) -- nothing new to save
  d.audit[#d.audit+1]={t=1006,out="item:10940",n=1};now=1010
  DE.RunHistory("end")
  assert(#d.runs==2 and d.runs[2].totals[1].n==1 and d.splitStart==1010) -- fresh marker, not none
  DE.RunHistory("end");assert(#d.runs==2)
  time=function()return 1000 end
end)
step("the since-login run survives reloads and disconnects, not a real logout",function()
  local d=DE._db();d.runs={};d.splitStart=nil;d.runName=nil
  d.audit={{t=500,out="item:10940",n=2},{t=510,out="deleted",n=1,del=true}}
  local now=600;time=function()return now end
  d.sessionStart=400;DE._event("PLAYER_LOGOUT");assert(d.lastSeen==600)
  now=700;DE._resumeSession() -- back 100s later: a reload or a relog
  assert(d.sessionStart==400 and DE.tally["item:10940"]==2 and DE.tally.deleted==nil)
  DE.Split("start") -- the pre-reload drops are still the current run
  assert(#d.runs==1 and d.runs[1].start==400 and d.runs[1].totals[1].n==2)
  d.splitStart=nil;now=800;DE._event("BAG_UPDATE_DELAYED");assert(d.lastSeen==800) -- heartbeat, no clean logout
  now=800+30*60+1;DE._resumeSession() -- gone longer than the grace: a new session
  assert(d.sessionStart==now and next(DE.tally)==nil)
  DisenchanterDB={sessionStart="junk",lastSeen={}} -- a fresh table is repaired on first use
  time=function()return 1000 end;DE._resumeSession()
  assert(DE._db().sessionStart==1000 and DE._db().lastSeen==1000)
end)
step("secure attributes separate plain and ctrl clicks",function()
  local row=stub();DE._db().clickMode="macro"
  DE._arm(row,"safe",2,3);assert(row._attr.type1=="macro" and row._attr["target-slot1"]==3 and row._attr["ctrl-type1"]==nil)
  DE._arm(row,"confirm",2,4);assert(row._attr.type1==nil and row._attr["ctrl-type1"]=="macro" and row._attr["ctrl-target-slot1"]==4)
  DE._arm(row,"blocked",2,5);assert(row._attr.type1==nil and row._attr["ctrl-type1"]==nil)
end)
step("active disenchant row becomes a secure cancel button",function()
  local row=stub();DE._armCancel(row)
  assert(row._attr.type1=="macro" and row._attr.macrotext1=="/stopcasting")
  assert(row._attr["target-bag1"]==nil and row._attr["target-slot1"]==nil)
  assert(row.cancelCast==true)
  DE._arm(row,"safe",2,3);assert(row.cancelCast==nil)
end)
print(("%d steps, %d failed"):format(steps,failed));if failed>0 then os.exit(1)end
