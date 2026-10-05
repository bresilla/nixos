-- One text answer through Oslo's line editor, with an optional ghost suggestion.
-- Loaded in an isolated child configuration; entered text is never executed.
local suggestion = oslo.env.get("INSTALL_INPUT_SUGGESTION") or ""
local result = assert(oslo.env.get("INSTALL_INPUT_RESULT"))
oslo.ui.prompt(function() return "Dotfiles Git URL: " end)
oslo.suggest.sh_sources = {"provider"}
oslo.suggest.provider{
  name = "installer-url",
  answer = function(ctx)
    if #ctx.line > 0 and #ctx.line < #suggestion and suggestion:sub(1, #ctx.line) == ctx.line then
      return suggestion
    end
  end,
}
-- Oslo suppresses ghosts on an empty line. Show the optional suggestion above
-- it; accepting with Right also works before any characters have been typed.
io.write("\27[90m" .. suggestion .. "\27[0m  (Right Arrow to use; Esc to cancel)\n")
oslo.on.key(function(key)
  if key.name == "right" and key.text == "" then return {text = suggestion} end
  if key.name == "esc" or key.name == "ctrl-c" then
    return {text = "exit 1", submit = true, erase = true}
  end
  if key.name == "enter" or key.name == "ctrl-enter" then
    if key.text == "" then return false end
    local ok, message = oslo.fs.write(result, key.text)
    if not ok then error(message) end
    return {text = "exit 0", submit = true, erase = true}
  end
  if key.name == "shift-tab" then return false end
end)
oslo.on.pre_cmd(function(ctx)
  if ctx.text ~= "exit 0" and ctx.text ~= "exit 1" then return "exit 1" end
end)
oslo.on.pre_record(function() return false end)
