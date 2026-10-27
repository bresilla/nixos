local test=morf.test
-- Each case runs in the configuration, where the tree's functions live, and
-- answers true or the first thing that was not as expected.
local HOST=[[
  local pages=require("lib.shell.settings.pages")
  local function eq(a,b) if a~=b then error(("expected %s, got %s"):format(tostring(b),tostring(a)),2) end end
  local function truthy(v) if not v then error("expected a true value",2) end end
  local function falsy(v) if v then error("expected a false value",2) end end
  local function raises(fn,pattern)
    local ok,err=pcall(fn)
    if ok then error("expected an error",2) end
    if not tostring(err):find(pattern,1,true) then error("error without "..pattern..": "..tostring(err),2) end
  end
  morf.ipc.breadcrumb=function()
    local selected=morf.signal("test.settings.path","")
    local tree=pages.new({{key="sound",name="Sound"},{key="eq",name="Equalizer",parent="sound"},
      {key="editor",name="Audiogram",parent="eq"}},selected,{old="sound"})
    truthy(tree.request("editor")) eq(tree.breadcrumb(),"Settings / Sound / Equalizer")
    tree.back() eq(selected:get(),"eq") tree.back() eq(selected:get(),"sound")
    tree.back() eq(selected:get(),"") truthy(tree.request("old")) eq(selected:get(),"sound")
    falsy(tree.request("missing")) eq(selected:get(),"sound")
    return true
  end
  morf.ipc.validation=function()
    local s=morf.signal("test.settings.validation","")
    raises(function() pages.new({{key="a",parent="missing"}},s) end,"parent")
    raises(function() pages.new({{key="a"},{key="a"}},s) end,"Duplicate")
    raises(function() pages.new({{key="a",parent="b"},{key="b",parent="a"}},s) end,"cycle")
    return true
  end
  morf.ipc.navigation=function()
    local selected=morf.signal("test.settings.nav","")
    local tree=pages.new({{key="sound",name="Sound"},{key="eq",name="Equalizer",parent="sound"}},selected)
    eq(tree.depth(),1) falsy(tree.can_go_back())
    tree.request("eq") eq(tree.depth(),3) truthy(tree.can_go_back())
    truthy(tree.key("Left","alt")) eq(selected:get(),"sound")
    truthy(tree.key("XF86Back","")) eq(selected:get(),"")
    falsy(tree.key("Left","alt")) eq(tree.depth(),1)
    selected:set("eq") eq(tree.depth(),3)
    truthy(tree.shortcuts()["alt+Left"]()) eq(selected:get(),"sound")
    return true
  end
]]
test.it("Settings tree returns one level and derives its breadcrumb",function()
  test.load {source=HOST}
  test.eq(test.ipc("breadcrumb"),true)
end)
test.it("Settings tree rejects missing parents, duplicate keys and cycles",function()
  test.load {source=HOST}
  test.eq(test.ipc("validation"),true)
end)
test.it("Settings tree pushes and pops on a Navigation stack",function()
  test.load {source=HOST}
  test.eq(test.ipc("navigation"),true)
end)
