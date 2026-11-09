--- The values of the variables of the selected frame, at the end of the lines where they appear
--- (the lines of the frame's file that are on screen), while the program is stopped.

local util = require("dapper.util")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("dapper.virtual_text")
local generation = 0 -- each update or clear: an update overtaken by another (or a clear) places nothing

function M.clear()
  generation = generation + 1
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_loaded(buf) then
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
end

-- the lines (0-based, from first to last) of buf that windows show
local function visible(buf)
  local first, last
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local top = vim.fn.line("w0", win) - 1
    local bottom = vim.fn.line("w$", win) - 1
    first = math.min(first or top, top)
    last = math.max(last or bottom, bottom)
  end
  return first, last
end

-- identifier -> lines (0-based) where it appears, in lines first..last of buf
local function occurrences(buf, first, last)
  local found = {}
  local function add(name, row)
    found[name] = found[name] or {}
    found[name][row] = true
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if ok and parser then
    parser:parse({ first, last + 1 })
    parser:for_each_tree(function(t)
      local function walk(node)
        local srow, _, erow = node:range()
        if erow < first or srow > last then
          return
        end
        if node:type():find("identifier") and node:child_count() == 0 then
          add(vim.treesitter.get_node_text(node, buf), srow)
        end
        for child in node:iter_children() do
          walk(child)
        end
      end
      walk(t:root())
    end)
  else -- no parser: words
    for row, line in ipairs(api.nvim_buf_get_lines(buf, first, last + 1, false)) do
      for word in line:gmatch("[%a_][%w_]*") do
        add(word, first + row - 1)
      end
    end
  end
  return found
end

function M.update()
  generation = generation + 1
  local mine = generation
  util.run(function()
    local session = require("dap").session()
    local frame = session and session.stopped_thread_id and session.current_frame
    local buf = frame and util.source_buf(frame.source)
    if not buf then
      return
    end
    local first, last = visible(buf)
    if not first then
      return
    end
    local values = {}
    for _, var in ipairs(util.frame_variables(session, frame)) do -- (not registers: sp, pc, ...)
      values[var.name] = values[var.name] or var.value
    end
    local per_line = {}
    for name, rows in pairs(occurrences(buf, first, last)) do
      if values[name] then
        for row in pairs(rows) do
          per_line[row] = per_line[row] or {}
          table.insert(per_line[row], name)
        end
      end
    end
    if mine ~= generation or not api.nvim_buf_is_valid(buf) then
      return -- (overtaken while waiting for the debugger)
    end
    M.clear()
    generation = mine -- (still this update's: clear() counted one)
    for row, names in pairs(per_line) do
      table.sort(names)
      local text = {}
      for _, name in ipairs(names) do
        local value = values[name]:gsub("\n", " ")
        table.insert(text, name .. " = " .. (#value > 40 and (value:sub(1, 39) .. "…") or value))
      end
      pcall(api.nvim_buf_set_extmark, buf, ns, row, 0, {
        virt_text = { { "  " .. table.concat(text, ", "), "DapperVirtualText" } },
        hl_mode = "combine",
      })
    end
  end)
end

return M
