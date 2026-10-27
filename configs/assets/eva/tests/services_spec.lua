local test=morf.test
test.it("the network, Bluetooth and power services load from the library",function()
  test.load("../shell/init.lua",{size={400,300},source=[[
    local services=require("services")
    morf.ipc.loaded=function()
      return {net=services.net~=nil,bt=services.bt~=nil,upower=services.upower~=nil}
    end
  ]]})
  local loaded=test.ipc("loaded")
  test.truthy(loaded.net,"no NetworkManager service")
  test.truthy(loaded.bt,"no BlueZ service")
  test.truthy(loaded.upower,"no UPower service")
  for _,line in ipairs(test.logs("warn")) do test.falsy(tostring(line):find("missing"),tostring(line)) end
end)
