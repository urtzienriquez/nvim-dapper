--- REPL: nvim-dap's; expressions, and the debugger's own commands (gdb: p/x var, x/8xb &var).

local M = { label = "REPL", key = "R" }

--- the buffer to show in `win` (nvim-dap makes it the first time, in that window)
local function find()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "dap-repl" then
      return buf
    end
  end
end

function M.buffer(win)
  if not find() then
    require("dap").repl.open({}, ("lua vim.api.nvim_set_current_win(%d)"):format(win))
  end
  return find()
end

return M
