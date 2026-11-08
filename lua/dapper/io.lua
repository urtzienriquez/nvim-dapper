--- The terminal of the program being debugged, shown by the "Program I/O" view:
--- - for debug adapters that run programs in a terminal (debugpy, codelldb, ...: the DAP
---   runInTerminal request), the one nvim-dap makes (session.term_buf), without a window;
--- - for gdb, whose DAP gives the program no terminal (so scanf() would read nothing), one made
---   here: tty() gives its device, for gdb's `set inferior-tty` (see require("dapper").gdb()).
--- A terminal is kept after its session (to read the output) and replaced by the next one.

local M = {}

local api = vim.api

local own -- the terminal made here (for gdb)
M.unseen = false -- the program printed while no pane showed it

local function watch(buf)
  M.unseen = false
  -- not in the buffer list: it is dapper's, shown by Program I/O (a TermOpen autocmd may list
  -- terminals; this runs after it)
  vim.schedule(function()
    if api.nvim_buf_is_valid(buf) then
      vim.bo[buf].buflisted = false
    end
  end)
  api.nvim_buf_attach(buf, false, {
    on_lines = function()
      if not M.unseen and not require("dapper.panes").shows("io") then
        M.unseen = true
        vim.schedule(require("dapper.panes").refresh_bars)
      end
    end,
  })
  vim.schedule(function() -- the panes that showed the old terminal show this one
    require("dapper.panes").reshow("io")
  end)
end

--- the terminal to show: the current session's, else the last one made here
function M.buffer()
  local session = require("dap").session()
  if session and session.term_buf and api.nvim_buf_is_valid(session.term_buf) then
    return session.term_buf
  end
  if own and api.nvim_buf_is_valid(own) then
    return own
  end
end

--- A new terminal for a program run by gdb; returns its tty.
function M.tty()
  local old = own
  own = api.nvim_create_buf(false, true)
  local chan
  api.nvim_buf_call(own, function()
    chan = vim.fn.jobstart({ "sleep", "infinity" }, { term = true }) -- keeps it open, reads nothing
  end)
  if old and api.nvim_buf_is_valid(old) then
    -- the panes showing the old one show the new one first: deleting a buffer closes its windows
    pcall(api.nvim_buf_set_name, old, "")
    require("dapper.panes").reshow("io")
    pcall(api.nvim_buf_delete, old, { force = true })
  end
  pcall(api.nvim_buf_set_name, own, "dapper://program")
  watch(own)
  return api.nvim_get_chan_info(chan).pty
end

--- for nvim-dap's terminal_win_cmd: the terminal of runInTerminal, made without a window
function M.terminal_buffer()
  local buf = api.nvim_create_buf(false, true)
  vim.schedule(function()
    if api.nvim_buf_is_valid(buf) then
      watch(buf)
    end
  end)
  return buf
end

return M
