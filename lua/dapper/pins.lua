--- Pins (:Dapper pin [expr]): an expression pinned to a line of code, its value shown at the end
--- of that line at each stop (dimmed while the program runs). :Dapper pin again on the same line
--- and expression removes it. They move with the line when the file is edited, and are kept per
--- project.

local util = require("dapper.util")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("dapper.pins")

---@class dapper.Pin
---@field path string
---@field line integer
---@field expr string
---@field mark? integer its extmark (follows the line), in the file's buffer

M.list = {} ---@type dapper.Pin[]
local values = {} -- expr .. "@" .. path .. ":" .. line -> { text, changed }
local before = {}

local function key(pin)
  return pin.expr .. "@" .. pin.path .. ":" .. pin.line
end

-- the lines pins are on now (their extmarks follow edits)
local function sync_lines()
  for _, pin in ipairs(M.list) do
    local buf = vim.fn.bufnr(pin.path)
    if pin.mark and buf ~= -1 and api.nvim_buf_is_loaded(buf) then
      local pos = api.nvim_buf_get_extmark_by_id(buf, ns, pin.mark, {})
      if pos[1] then
        pin.line = pos[1] + 1
      end
    end
  end
end

function M.save()
  sync_lines()
  require("dapper.store").set(
    "pins",
    vim.tbl_map(function(pin)
      return { path = pin.path, line = pin.line, expr = pin.expr }
    end, M.list)
  )
end
require("dapper.store").track("pins", M.list, M.save)

--- draws the pins of buffer `buf` (all loaded buffers, without one)
function M.draw(buf)
  sync_lines() -- (where edits moved them: drawn there)
  if not buf then
    for _, b in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_loaded(b) then
        M.draw(b)
      end
    end
    return
  end
  local path = vim.fs.normalize(api.nvim_buf_get_name(buf))
  local per_line = {}
  for _, pin in ipairs(M.list) do
    if pin.path == path then
      per_line[pin.line] = per_line[pin.line] or {}
      table.insert(per_line[pin.line], pin)
    end
  end
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local count = api.nvim_buf_line_count(buf)
  for line, pins in pairs(per_line) do
    local chunks = {}
    for _, pin in ipairs(pins) do
      local v = values[key(pin)]
      table.insert(chunks, { "  ▹ " .. pin.expr, "DapperPin" })
      if v then
        table.insert(chunks, { " = " .. v.text, v.changed and "DapperChanged" or "DapperPin" })
      end
    end
    if line <= count then
      local mark = api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { virt_text = chunks, hl_mode = "combine" })
      for _, pin in ipairs(pins) do
        pin.mark = mark
      end
    end
  end
end

--- a stop: the pins' values (in the selected frame)
function M.update()
  if #M.list == 0 then
    return
  end
  util.run(function()
    local session = require("dap").session()
    if not (session and session.stopped_thread_id) then
      values = {}
      return M.draw()
    end
    local frame = session.current_frame and session.current_frame.id
    local answers = util.requests(
      session,
      vim.tbl_map(function(pin)
        return { "evaluate", { expression = pin.expr, context = "watch", frameId = frame } }
      end, M.list)
    )
    local new = {}
    for i, pin in ipairs(M.list) do
      local text = answers[i] and answers[i].result or "?"
      text = text:gsub("\n", " ")
      if #text > 60 then
        text = text:sub(1, 59) .. "…"
      end
      new[key(pin)] = { text = text, changed = before[key(pin)] ~= nil and before[key(pin)] ~= text }
    end
    values = new
    M.draw()
  end)
end

--- the program stopped (a new stop: changes are from the values now)
function M.stopped()
  before = {}
  for k, v in pairs(values) do
    before[k] = v.text
  end
end

--- the program runs: the values go (the pins stay, dimmed)
function M.running()
  values = {}
  M.draw()
end

--- pins `expr` to the cursor's line (or unpins it, if it was)
function M.toggle(expr)
  expr = vim.trim(expr or "")
  if expr == "" then
    return
  end
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" or api.nvim_buf_get_name(buf) == "" then
    return util.notify("Pins go on a line of a file", vim.log.levels.WARN)
  end
  sync_lines()
  local path = vim.fs.normalize(api.nvim_buf_get_name(buf))
  local line = api.nvim_win_get_cursor(0)[1]
  for i, pin in ipairs(M.list) do
    if pin.path == path and pin.line == line and pin.expr == expr then
      table.remove(M.list, i)
      M.save()
      M.draw(buf)
      return util.notify("Unpinned " .. expr)
    end
  end
  table.insert(M.list, { path = path, line = line, expr = expr })
  M.save()
  M.draw(buf)
  M.update()
end

return M
