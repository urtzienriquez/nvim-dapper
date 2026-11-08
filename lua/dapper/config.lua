--- The options of setup(), merged over these defaults.

local M = {}

---@class dapper.Config
M.defaults = {
  -- the column of panes: where, and how wide (or tall, "below": a fraction, or columns/lines)
  position = "right", ---@type "right"|"left"|"below"
  size = 0.4,
  -- the panes it opens with: the first one, then each split from the one before it
  -- ("below" or "right" of it); after that, they open as they were last closed
  layout = {
    { view = "watches" },
    { view = "stack", split = "below" },
  },
  -- the views, in the order of the tabs; each has a key that shows it in a pane
  views = { "watches", "scopes", "exceptions", "breakpoints", "stack", "threads", "sessions", "repl", "io" },
  auto_open = true, -- open with a debug session
  auto_close = true, -- close when it ends
  follow_tab = false, -- move the panes to the tab you enter, while debugging
  keep_cursor = true, -- the program stops: show the code, without moving the cursor there
  signs = true, -- breakpoint and stop signs: ● ◆ ◉ → ✗
  virtual_text = false, -- the values of the variables, at the end of their lines, while stopped
  controls = false, -- buttons in the panes' bar: continue, step over/into/out, restart, stop
  icons = { collapsed = "▸", expanded = "▾", enabled = "●", disabled = "○", current = "→" },
  memory = { columns = 16, rows = 64 }, -- the Memory view: bytes a row, rows shown
  disassembly = { instructions = 100, bytes = false }, -- instructions shown; their bytes too
}

---@type dapper.Config
M.values = vim.deepcopy(M.defaults)

function M.set(opts)
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  if opts and opts.layout then
    M.values.layout = opts.layout -- a list: replaced, not merged
  end
  if opts and opts.views then
    M.values.views = opts.views
  end
end

return M
