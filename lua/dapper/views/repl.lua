--- REPL: nvim-dap's; expressions, and the debugger's own commands (gdb: p/x var, x/8xb &var).

local M = { label = "REPL", key = "R" }

local function find()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == "dap-repl" then
      return buf
    end
  end
end

--- the buffer to show (nvim-dap makes it, in a window of its own, closed at once: nvim-dap then
--- holds no pane as its REPL window, and your dap.repl.toggle() opens its own)
function M.buffer()
  if not find() then
    local repl = require("dap").repl
    repl.open({}, "noautocmd botright new | setlocal nowinfixbuf")
    repl.close({ mode = "toggle" }) -- (the window goes, the buffer stays)
  end
  return find()
end

return M
