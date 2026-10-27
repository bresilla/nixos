-- One keyboard for desktop, lock and greet. Hosts supply colours and a
-- private key sink; sizing, layouts and touch ownership are shared here.
local morf=require("morf")
local ui=require("morf.ui")
-- EDGE: the bottom strip; CATCH: how far above it a second finger may land.
local M={PAD=12,MAX_WIDTH=1060,EDGE=20,CATCH=120}
-- The desktop reads this without loading the keyboard controller recursively.
-- Authentication has its own scene, and uses the same panel height directly.
M.inset=morf.signal("eva.keyboard.inset",0)

function M.contacts(region,model,single)
  return require("themes.touch_contacts").new {
    allowed=model.allowed,single=single,cancel_keys=model.cancel,
    pair=function(a,b)
      local dx1,dy1,dx2,dy2=a.x-a.sx,a.y-a.sy,b.x-b.sx,b.y-b.sy
      if math.abs(dy1)<48 or math.abs(dy2)<48 or dy1*dy2<=0
        or math.abs(dy1)<math.abs(dx1)*1.2 or math.abs(dy2)<math.abs(dx2)*1.2 then return end
      if model.allowed and not model.allowed() then return end
      if region=="bottom" then
        -- One finger from the edge itself, the other from it or the band above.
        local h=model.height()
        if math.max(a.sy,b.sy)<h-M.EDGE or math.min(a.sy,b.sy)<h-M.EDGE-M.CATCH then return end
        if dy1<0 and not model.active() then
          if model.before_show then model.before_show() end
          model.show("full")
        end
      elseif model.active() then
        if dy1>0 then model.hide()
        else model.show(model.mode()=="dev" and "full" or "dev") end
      end
    end,
  }
end

function M.area(contacts,props)
  props=props or {}
  props.on_touch_pressed=contacts.down
  props.on_touch_moved=contacts.move
  props.on_touch_released=contacts.up
  props.on_touch_canceled=contacts.cancel
  props.on_dragged=function() end
  return ui.MouseArea(props)
end

-- The bottom strip's height: CATCH higher while a finger rests on it.
function M.reach(name)
  local held=morf.signal(name,false)
  local release
  local r={}
  function r.hold(on)
    if release then release:cancel() release=nil end
    if on then release=morf.time.timer(1500,function() release=nil held:set(false) end,false) end
    if held:get()~=on then held:set(on) end
  end
  function r.height() return M.EDGE+(held:get() and M.CATCH or 0) end
  return r
end

-- The strip along `floor` (the y its lower side rests on).
function M.strip(contacts,reach,floor,props)
  props.height=reach.height
  props.y=function() return floor()-reach.height() end
  return M.area({down=function(...) reach.hold(true) contacts.down(...) end,move=contacts.move,
    up=function(...) reach.hold(false) contacts.up(...) end,
    cancel=function(...) reach.hold(false) contacts.cancel(...) end},props)
end

function M.panel(options)
  local width=math.min(M.MAX_WIDTH,options.width)
  local keys=require("lib.shell.osk").new {
    prefix=options.prefix,width=width-2*M.PAD,mode="full",numbers=false,
    look=options.look,key_face=options.look.key_face,action=options.action,
    send=options.send,active=options.active,touch=options.touch,
  }
  local function height() return keys.height()+2*M.PAD end
  local content=ui.Item {width=width,height=height,
    M.area(options.touch,{anchors={fill=true},z=-1}),
    ui.Item {x=M.PAD,y=M.PAD,width=width-2*M.PAD,height=keys.height,keys.node},
  }
  if options.decoration then ui.reparent(options.decoration,content) end
  return {width=width,height=height,keys=keys,content=content}
end
return M
