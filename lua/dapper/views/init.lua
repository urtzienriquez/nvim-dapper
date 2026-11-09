--- The views: their buffers, and drawing them (when they are shown, and when the debugger says
--- something changed).

local canvas = require("dapper.canvas")
local util = require("dapper.util")

local M = {}

local api = vim.api

--- the options of the windows showing views (panes, Memory's and Disassembly's tab pages)
M.WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  spell = false,
  list = false,
  wrap = false,
  cursorline = true,
}

local modules = {} -- name -> module, loaded on use
function M.get(name)
  if not modules[name] then
    modules[name] = require("dapper.views." .. name)
  end
  return modules[name]
end

local bufs = {} -- name -> buffer (of the views that are drawn)
local generation = {} -- name -> draws started (a draw that is no longer the last is dropped)

--- the buffer of view `name`, and whether it is one drawn here
function M.buffer(name)
  local view = M.get(name)
  if view.buffer then
    return view.buffer(), false
  end
  local buf = bufs[name]
  if buf and api.nvim_buf_is_valid(buf) and not api.nvim_buf_is_loaded(buf) then -- (:bd: made again)
    api.nvim_buf_delete(buf, { force = true })
  end
  if not (buf and api.nvim_buf_is_loaded(buf)) then
    buf = api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "dapper"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].modifiable = false
    pcall(api.nvim_buf_set_name, buf, "dapper://" .. name)
    if view.attach then
      view.attach(buf)
    end
    for _, key in ipairs(view.keys or {}) do
      vim.keymap.set("n", key[1], function()
        key[3](canvas.item())
      end, { buffer = buf, nowait = true, desc = view.label .. ": " .. key[2] })
    end
    bufs[name] = buf
  end
  return buf, true
end

--- draws view `name` (all the shown ones, without a name)
function M.refresh(name)
  if not name then
    for view in pairs(bufs) do
      M.refresh(view)
    end
    return
  end
  local buf = bufs[name]
  if not (buf and api.nvim_buf_is_valid(buf)) or #vim.fn.win_findbuf(buf) == 0 then
    return -- not shown: drawn when it is
  end
  generation[name] = (generation[name] or 0) + 1
  local mine = generation[name]
  util.run(function()
    local c = canvas.new()
    local ok, err = pcall(M.get(name).render, c, require("dap").session())
    if not ok then
      c = canvas.new()
      c:add({ { tostring(err), "DapperError" } })
    end
    if generation[name] == mine then -- (else a later draw replaces it)
      c:write(buf)
      if M.get(name).written then
        M.get(name).written(buf)
      end
    end
  end)
end

--- the program stopped: the views that mark changed values start over
function M.stopped()
  for name in pairs(modules) do
    if modules[name].stopped then
      modules[name].stopped()
    end
  end
end

return M
