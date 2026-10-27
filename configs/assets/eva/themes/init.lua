-- Theme packages own appearance, never wallpaper colors or application state.
local morf = require("morf")
local settings = require("lib.shell.settings")
local root = morf.env("XDG_CONFIG_HOME") or (morf.fs.home() .. "/.config")
-- make apply supplies a readable default beside each installed config. The
-- greeter has no personal settings; a user's explicit preference still wins.
local defaults = { theme = "material", font = "" }
do
  local ok, value = pcall(function()
    return morf.json.decode(morf.fs.read(morf.paths.shell("appearance-default.json")))
  end)
  if ok and type(value) == "table" then
    if type(value.theme) == "string" then defaults.theme = value.theme end
    if type(value.font) == "string" then defaults.font = value.font end
  end
end
local preferences = settings.open {
  path = morf.env("EVA_APPEARANCE") or (root .. "/morf/eva/appearance.json"),
  name = "eva.appearance", defaults = defaults,
}
local M = { preferences = preferences }
-- The engine a theme needs: `morf` in its manifest, written as a shell's
-- morf.lua writes it. An engine from before morf.satisfies cannot be asked.
local function needs(package)
  if type(package.morf) ~= "string" or not morf.satisfies or morf.satisfies(package.morf) then return nil end
  return ("%s needs morf %s; this is morf %s"):format(package.name or package.id, package.morf, tostring(morf.version))
end
function M.load(name)
  assert(type(name) == "string" and name:match("^[a-z][a-z0-9_]*$"), "Invalid visual theme name")
  local package = require("themes." .. name .. ".manifest")
  assert(package.api == 1 and package.id == name, "Incompatible visual theme: " .. name)
  assert(type(package.tokens) == "table" and type(package.components) == "string", "Incomplete visual theme: " .. name)
  local refused = needs(package)
  if refused then error(refused, 0) end
  return package
end
--- Why theme `name` cannot be shown here, or nil when it can.
function M.problem(name)
  local ok, problem = pcall(M.load, name)
  return not ok and tostring(problem) or nil
end
local session = require("themes.session")
M.font = session.font
if M.font == nil then M.font = preferences.get("font") end
local requested = session.target or morf.env("EVA_STYLE") or preferences.get("theme")
-- Futuristic was folded into Tsugumori: a saved choice of it lands there.
if requested == "futuristic" then requested = "tsugumori" end
-- A theme that cannot be shown gives way to Material; the shell says why.
M.refused = M.problem(requested)
if M.refused then
  morf.log("warn", "eva: " .. M.refused .. "; using Material")
  requested = "material"
end
M.current = M.load(requested)
-- A theme may reuse another theme's individual views while replacing others.
-- This is explicit inheritance, not an implicit fallback for misspelled files.
function M.view(name)
  local selected, seen = M.current, {}
  while selected do
    assert(not seen[selected.id], "Visual theme inheritance cycle")
    seen[selected.id] = true
    local module = (selected.views or {})[name]
    if module then return require(module) end
    selected = selected.inherits and M.load(selected.inherits) or nil
  end
  error("Visual theme " .. M.current.id .. " has no view: " .. name)
end
return M
