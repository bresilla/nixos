local test=morf.test
local SOURCE=[[
  local hypr=require("lib.compositor.hyprland")
  local evals={}
  hypr.eval=function(chunk,cb) evals[#evals+1]=chunk if cb then cb("ok") end return true end
  hypr.options=function(_,cb) cb({["decoration:rounding"]={int=20},["general:border_size"]={int=3}}) return true end
  local focused={address="0xabc"}
  hypr.json=function(command,cb) if command=="j/activewindow" then cb(focused) end return true end
  package.loaded["lib.compositor.hyprland_config"]={flavour=function(cb) cb("lua") end}
  hypr.state.clients={{address="0xabc",class="kitty",title="~/code",workspace=2,workspace_name="2",monitor=0,
    x=400,y=200,width=800,height=500,floating=false,pinned=false,fullscreen=0,pid=4242,xwayland=false},
    {address="0xdef",class="firefox",title="news",workspace=2,workspace_name="2",monitor=0,
    x=1000,y=500,width=500,height=400,floating=true,pinned=false,fullscreen=0,pid=77,xwayland=false}}
  morf.ipc.focus_other=function() hypr.state.active_window.address="0xdef" focused={address="0xdef"} end
  morf.ipc.address=function() return require("window_menu").address:get() end
  hypr.state.active_window.address="0xabc" hypr.state.active_window.class="kitty"
  require("init")
  morf.ipc.menu_state=function()
    local m=require("window_menu")
    return {open=m.opened:get(),focus=m.focus:get(),follow=m.follow:get(),evals=evals}
  end
  -- As Hyprland leaves it once a layer has had the keyboard: no window said.
  morf.ipc.lost_focus=function() hypr.state.active_window.address="" end
  morf.ipc.no_window=function() hypr.state.active_window.address="" focused={} end
]]
local function load(style)
  test.load("../shell/init.lua",{source=SOURCE,size={1600,1000},env={EVA_STYLE=style}})
  test.advance(200)
end
local function state() return test.ipc("menu_state") end
local function last() local e=state().evals return e[#e] or "" end
local function open() test.eq(test.ipc("window_menu","open"),true) test.advance(800) end
local function shot(name) if morf.env("MORF_THEME_SNAPSHOTS")=="1" then test.snapshot(name..".png") end end
for _,style in ipairs {"material","tsugumori"} do
  test.it(style.." the window menu's buttons each act in one press",function()
    load(style) open()
    local box=test.get("window-menu")
    test.near(box.x+box.width/2,800,2,"not over the window")
    local outline=test.get("window-menu-outline")
    test.near(outline.x,397,1,"the frame is not on the window's border") test.near(outline.width,806,1)
    local a=test.get("window-menu-tape").x test.advance(400)
    test.truthy(math.abs(test.get("window-menu-tape").x-a)>1,"the tape stands still")
    shot(style.."-window-menu")
    test.key("3") test.advance(100)
    test.truthy(last():find('hl.dsp.window.move({ follow = true, window = "address:0xabc", workspace = "3" })',1,true),last())
    test.falsy(state().open)
    open()
    test.click("window-menu-top-2") test.advance(100)
    test.truthy(last():find('hl.dsp.window.fullscreen({ mode = "fullscreen", window = "address:0xabc" })',1,true),last())
    test.truthy(state().open,"a layout button shuts the menu")
    test.key("Up") test.eq(state().focus,"top:fullscreen")
    test.key("Down") test.eq(state().focus,"top:center")
    test.key("Down") test.key("Down") test.truthy(state().focus:match("^bottom:"),state().focus)
    test.key("Left") test.key("Left") test.eq(state().focus,"left:follow")
    test.key("Up") test.truthy(state().focus:match("^left:ws"),state().focus)
    test.key("Return") test.advance(100)
    test.truthy(last():find('hl.dsp.window.move(',1,true),last())
    open()
    test.click("window-menu-left-11") test.advance(100)
    test.falsy(state().follow)
    test.key("2") test.advance(100)
    test.truthy(last():find('follow = false',1,true),last())
    test.ipc("window_menu","open") test.advance(400)
    test.click("window-menu-left-11") test.advance(100) test.truthy(state().follow)
    test.key("Escape") test.advance(100) test.falsy(state().open)
    for _=1,3 do
      test.ipc("lost_focus") test.ipc("window_menu","toggle") test.advance(300)
      test.truthy(state().open,"did not open again after losing the focus")
      test.click(40,960) test.advance(300) test.falsy(state().open)
    end
    test.eq(#test.logs("error"),0) test.eq(#test.logs("warn"),0)
  end)
end
test.it("a press off the cards shuts it, and without a window it does not open",function()
  load("material") open()
  test.click(40,960) test.advance(100)
  test.falsy(state().open)
  test.ipc("no_window") test.advance(16)
  test.eq(test.ipc("window_menu","open"),nil) test.advance(100)
  test.falsy(state().open)
end)
test.it("over another window it folds away first, then opens there at once",function()
  load("tsugumori") open()
  test.ipc("focus_other")
  test.ipc("window_menu","close") test.ipc("window_menu","open") test.advance(16)
  test.falsy(state().open,"opened before the fold")
  test.advance(300)
  test.truthy(state().open) test.eq(test.ipc("address"),"0xdef")
  local box=test.get("window-menu")
  test.eq(box.x,1600-1040-16,"glided instead of opening in place")
  test.eq(#test.logs("error"),0) test.eq(#test.logs("warn"),0)
end)
