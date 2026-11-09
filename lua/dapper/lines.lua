--- Breakpoints on lines, kept per project (nvim-dap forgets them when Neovim quits), and turned off
--- without deleting them. nvim-dap holds those of the files open; this list, the rest:
--- - a file opened gets its breakpoints back (and its turned-off ones, shown with ○);
--- - a session starting opens (unlisted, unseen) the files with breakpoints, so all are sent;
--- - they are saved when a file is written or closed, when Neovim quits, and when changed here.

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("dapper.disabled")

---@class dapper.LineBreakpoint
---@field path string
---@field line integer
---@field condition? string
---@field hit? string
---@field log? string
---@field disabled? boolean
---@field buf? integer its file's buffer, while it is open (turned off ones)
---@field mark? integer its sign there (it follows edits)

M.list = {} ---@type dapper.LineBreakpoint[]
local restored = {} -- path -> true: its file is open, and nvim-dap holds its breakpoints

local function path_of(buf)
  local name = api.nvim_buf_get_name(buf)
  return name ~= "" and vim.bo[buf].buftype == "" and vim.fs.normalize(name) or nil
end

local function loaded(path)
  local buf = vim.fn.bufnr(path)
  return buf ~= -1 and api.nvim_buf_is_loaded(buf) and buf or nil
end

local function mark(entry, buf)
  local icon = require("dapper.config").values.icons.disabled
  local ok, id = pcall(api.nvim_buf_set_extmark, buf, ns, entry.line - 1, 0, {
    sign_text = icon,
    sign_hl_group = "DapperDisabled",
    priority = 21,
  })
  entry.buf, entry.mark = buf, ok and id or nil
end

--- The list as it is now: nvim-dap's breakpoints of the files open, where edits moved them.
local function collect()
  local out = {}
  for _, e in ipairs(M.list) do
    if e.disabled and e.mark and e.buf and api.nvim_buf_is_loaded(e.buf) then
      local pos = api.nvim_buf_get_extmark_by_id(e.buf, ns, e.mark, {})
      e.line = pos[1] and pos[1] + 1 or e.line
    end
    if e.disabled or not restored[e.path] then
      table.insert(out, e)
    end
  end
  for path in pairs(restored) do
    local buf = loaded(path)
    for _, bp in ipairs(buf and require("dap.breakpoints").get(buf)[buf] or {}) do
      table.insert(out, { path = path, line = bp.line, condition = bp.condition, hit = bp.hitCondition, log = bp.logMessage })
    end
  end
  for i = #M.list, 1, -1 do -- (in place: the list is the store's)
    M.list[i] = nil
  end
  vim.list_extend(M.list, out)
end

function M.save()
  collect()
  require("dapper.store").set(
    "breakpoints",
    vim.tbl_map(function(e)
      return { path = e.path, line = e.line, condition = e.condition, hit = e.hit, log = e.log, disabled = e.disabled }
    end, M.list)
  )
end

--- file buffer `buf` opened: its breakpoints given back to nvim-dap, its turned-off ones marked
function M.restore(buf)
  local path = path_of(buf)
  if not path or restored[path] then
    return
  end
  local breakpoints = require("dap.breakpoints")
  for _, e in ipairs(M.list) do
    if e.path == path and e.line <= api.nvim_buf_line_count(buf) then
      if e.disabled then
        mark(e, buf)
      else
        breakpoints.set({ condition = e.condition, hit_condition = e.hit, log_message = e.log }, buf, e.line)
      end
    end
  end
  restored[path] = true
end

--- file buffer `buf` closing: what it holds kept (nvim-dap forgets it)
function M.unloading(buf)
  local path = path_of(buf)
  if path and restored[path] then
    M.save()
    restored[path] = nil
    for _, e in ipairs(M.list) do
      if e.path == path then
        e.buf, e.mark = nil, nil
      end
    end
  end
end

--- a session starts: the files with breakpoints opened (unseen), so that nvim-dap sends them all
function M.load_all()
  for _, e in ipairs(M.list) do
    if not e.disabled and not loaded(e.path) and vim.uv.fs_stat(e.path) then
      local buf = vim.fn.bufadd(e.path)
      local listed = vim.bo[buf].buflisted
      vim.fn.bufload(buf) -- (its BufReadPost restores them)
      vim.bo[buf].buflisted = listed and vim.fn.bufwinid(buf) ~= -1 -- (unseen: not in your list)
      M.restore(buf)
    end
  end
end

--- the project changed (:cd): its breakpoints, in the files open
local function reloaded()
  restored = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      M.restore(buf)
    end
  end
end

require("dapper.store").track("breakpoints", M.list, M.save, nil, reloaded)

--- All line breakpoints, for the Breakpoints view: { path, line, buf?, condition?, hit?, log?,
--- disabled?, state? (the debugger's answer) }, by file and line.
function M.all()
  collect()
  local out = {}
  for _, e in ipairs(M.list) do
    if e.disabled or not restored[e.path] then -- (nvim-dap's, with its state, below)
      table.insert(out, vim.tbl_extend("force", e, { buf = loaded(e.path) }))
    end
  end
  for path in pairs(restored) do
    local buf = loaded(path)
    for _, bp in ipairs(buf and require("dap.breakpoints").get(buf)[buf] or {}) do
      local e = { path = path, line = bp.line, buf = buf, condition = bp.condition, hit = bp.hitCondition }
      e.log, e.state = bp.logMessage, bp.state
      table.insert(out, e)
    end
  end
  table.sort(out, function(a, b)
    return a.path < b.path or (a.path == b.path and a.line < b.line)
  end)
  return out
end

-- sends buffer `buf`'s breakpoints to the sessions (their children too)
local function send(buf)
  local list = require("dap.breakpoints").get(buf)[buf] or {}
  local function each(sessions)
    for _, s in pairs(sessions) do
      s:set_breakpoints({ [buf] = list })
      each(s.children or {})
    end
  end
  each(require("dap").sessions())
end

local function find(path, line, disabled)
  for i, e in ipairs(M.list) do
    if e.path == path and e.line == line and (e.disabled or false) == (disabled or false) then
      return i, e
    end
  end
end

--- turns breakpoint `bp` (from all()) off, or on again
function M.toggle(bp)
  local breakpoints = require("dap.breakpoints")
  if bp.disabled then -- on again
    local i, e = find(bp.path, bp.line, true)
    if not e then
      return
    end
    table.remove(M.list, i)
    if e.buf and e.mark then
      pcall(api.nvim_buf_del_extmark, e.buf, ns, e.mark)
    end
    local buf = loaded(bp.path)
    if buf and restored[bp.path] then
      breakpoints.set({ condition = e.condition, hit_condition = e.hit, log_message = e.log }, buf, e.line)
      send(buf)
    else
      table.insert(M.list, { path = e.path, line = e.line, condition = e.condition, hit = e.hit, log = e.log })
    end
  else -- off
    local entry = { path = bp.path, line = bp.line, condition = bp.condition, hit = bp.hit, log = bp.log, disabled = true }
    local buf = loaded(bp.path)
    if buf and restored[bp.path] then
      breakpoints.remove(buf, bp.line)
      send(buf)
      mark(entry, buf)
    else
      local i = find(bp.path, bp.line, false)
      if i then
        table.remove(M.list, i)
      end
    end
    table.insert(M.list, entry)
  end
  M.save()
end

--- deletes breakpoint `bp` (from all())
function M.delete(bp)
  local buf = loaded(bp.path)
  if not bp.disabled and buf and restored[bp.path] then
    require("dap.breakpoints").remove(buf, bp.line)
    send(buf)
  else
    local i, e = find(bp.path, bp.line, bp.disabled)
    if i then
      table.remove(M.list, i)
      if e.buf and e.mark then
        pcall(api.nvim_buf_del_extmark, e.buf, ns, e.mark)
      end
    end
  end
  M.save()
end

--- deletes them all: of the files open (nvim-dap's, the sessions told), of the others, turned off
function M.clear()
  require("dap").clear_breakpoints()
  for _, e in ipairs(M.list) do
    if e.buf and e.mark then
      pcall(api.nvim_buf_del_extmark, e.buf, ns, e.mark)
    end
  end
  for i = #M.list, 1, -1 do
    M.list[i] = nil
  end
  M.save()
end

return M
