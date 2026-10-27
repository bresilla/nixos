local test=morf.test
local SOURCE=[[
  require("init")
  require("settings_model").set_edge_hover(true)
  morf.ipc.eva_state=function()
    local config=require("config")
    return {sidebar=require("sidebar").drawer.open:get(),detail=require("utilities").detail:get(),
      hover={config.get("dashboard.hover"),config.get("sidebar.hover"),config.get("leftbar.hover"),config.get("bottom.hover")}}
  end
]]
local W,H=1600,1000
local function load(style) test.load("../shell/init.lua",{source=SOURCE,size={W,H},env={EVA_STYLE=style}}) test.advance(200) end
local function state() return test.ipc("eva_state") end
for _,style in ipairs {"material","tsugumori"} do
  test.it(style.." the Eva tile holds the bar and how the panels open",function()
    load(style)
    test.ipc("utilities","open") test.settle(900)
    test.truthy(test.find{id="utilities-toggle-eva",visible=true},"no Eva tile")
    for _,id in ipairs {"bar","roaming","5g"} do
      test.falsy(test.find{id="utilities-toggle-"..id,visible=true},id.." is still a tile of its own")
    end
    test.click("utilities-toggle-eva") test.advance(2500)
    test.eq(state().detail,"eva")
    test.click("utilities-toggle-edge-hover") test.advance(100)
    test.eq(state().hover,{false,false,false,false})
    test.click("settings-eva-bar") test.advance(2500)
    test.eq(state().detail,"bar")
    test.click("settings-back") test.advance(2500)
    test.eq(state().detail,"eva")
    test.eq(#test.logs("error"),0)
  end)
end
test.it("with hovering off a press at the edge opens its panel, and hovering there does not",function()
  load("material")
  test.ipc("settings","eva") test.advance(2500)
  test.click("utilities-toggle-edge-hover") test.advance(100)
  test.eq(state().hover,{false,false,false,false})
  test.click(100,100) test.settle(900)
  test.falsy(state().sidebar)
  test.move(W-2,H/2) test.advance(900)
  test.falsy(state().sidebar,"hovering opened it")
  test.click(W-2,H/2) test.settle(900)
  test.truthy(state().sidebar,"a press at the edge did not open it")
  test.click(100,100) test.settle(900)
  test.falsy(state().sidebar)
  test.ipc("settings","eva") test.advance(2500)
  test.click("utilities-toggle-edge-hover") test.advance(100)
  test.click(100,100) test.settle(900)
  test.move(W-2,H/2) test.advance(900)
  test.truthy(state().sidebar,"hovering again did not open it")
  test.eq(#test.logs("error"),0)
end)
