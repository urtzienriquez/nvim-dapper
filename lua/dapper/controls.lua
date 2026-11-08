--- Buttons in the panes' bar (config.controls): clicking one does what it says.

local M = {}

local BUTTONS = {
  { "▶", "continue" },
  { "↷", "step_over" },
  { "↓", "step_into" },
  { "↑", "step_out" },
  { "↻", "restart" },
  { "■", "terminate" },
}

--- for the window bar's %@...@ (a click)
function M.click(index)
  local action = BUTTONS[index] and BUTTONS[index][2]
  if action then
    require("dap")[action]()
  end
end

function M.bar()
  local parts = {}
  for i, button in ipairs(BUTTONS) do
    table.insert(parts, ("%%%d@v:lua.require'dapper.controls'.click@ %s %%T"):format(i, button[1]))
  end
  return "%#DapperControls#" .. table.concat(parts) .. "%*"
end

return M
