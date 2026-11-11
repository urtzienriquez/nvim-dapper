--- Watches: expressions evaluated each time the program stops (in the selected frame).

local tree = require("dapper.tree")
local util = require("dapper.util")

local M = { label = "Watches", short = "Watch", key = "W" }

local COMPLETE = "customlist,v:lua.require'dapper'.complete"

M.expressions = {} ---@type string[] (kept per project)
local function save()
  require("dapper.store").set("watches", M.expressions)
end
require("dapper.store").track("watches", M.expressions, save)
M.tree = tree.new()

-- The debugger's own commands, as typed in its REPL (gdb's p/t n, x/8xb &n, info frame, ...),
-- watched too: their output is shown. `/t n` is short for `print/t n`. (`x / 2` is an
-- expression: a command's format follows it without a space.)
local COMMANDS = { "print", "output", "info", "ptype", "whatis" }

--- the command `expr` is, or nil (an expression)
function M.command(expr)
  local format, rest = expr:match("^/(%w+)%s+(.+)$")
  if format then
    return "print/" .. format .. " " .. rest
  end
  if expr:match("^%a+/%w") then -- p/x n, x/8xb &n, print/t n
    return expr
  end
  local word = expr:match("^(%a+)%s")
  if word and vim.tbl_contains(COMMANDS, word) then
    return expr
  end
end

--- `p, 10` (raddebugger's way): 10 elements from pointer p, gdb's `*(p)@10`. With gdb only (in
--- Python, `p, 10` is a tuple). nil: `expr` is no such thing.
function M.array(expr, session)
  local base, count = expr:match("^(.-)%s*,%s*(%d+)%s*$")
  if base and base ~= "" and session and (session.config.type or ""):find("gdb") then
    return "*(" .. base .. ")@" .. count
  end
end

local width = 0 -- the expressions' names are padded to it (their values line up)
local function pad(expr)
  return string.rep(" ", width - vim.fn.strdisplaywidth(expr)) .. " = "
end

-- expression number i has no value now: why (an error, the program running, not debugging)
local function no_value(canvas, session, i, expr, err)
  local why = err or (session and "running…" or "not debugging")
  canvas:add(
    { { "  " }, { expr, "DapperName" }, { pad(expr) }, { why, err and "DapperError" or "DapperMuted" } },
    { kind = "expression", index = i }
  )
end

--- draws command `command` (of expression number i) and its output
local function draw_command(canvas, session, i, expr, command, path)
  local result, err
  if session and session.stopped_thread_id then
    result, err = util.evaluate(session, command, "repl")
  end
  local output = result and vim.trim(result.result or ""):gsub("^%$%d+ = ", "")
  if not output then
    return no_value(canvas, session, i, expr, err)
  end
  local lines = vim.split(output, "\n", { trimempty = true })
  M.tree.values[path] = output
  local before = M.tree.before[path]
  local hl = (before ~= nil and before ~= output) and "DapperChanged" or "DapperValue"
  canvas:add({ { "  " }, { expr, "DapperName" }, { pad(expr) }, { lines[1] or "", hl } }, { kind = "command", index = i })
  for n = 2, #lines do -- (x/16xb: several lines)
    canvas:add({ { "    " }, { lines[n], hl } }, { kind = "command", index = i })
  end
end

function M.render(canvas, session)
  if #M.expressions == 0 then
    canvas:note("No expressions. i adds one, or :Dapper watch on a variable in the code.")
    canvas:note("On one: x breaks when it changes, m shows its memory, g? lists the keys.")
    return
  end
  width = tree.name_width(vim.tbl_map(function(expr)
    return { name = expr }
  end, M.expressions))
  for i, expr in ipairs(M.expressions) do
    local path = "watch:" .. expr
    local command = M.command(expr)
    local result, err
    local value_expr = M.array(expr, session) or expr -- (what is evaluated: p, 10 is *(p)@10)
    if not command and session and session.stopped_thread_id then
      result, err = util.evaluate(session, value_expr)
    end
    if command then
      draw_command(canvas, session, i, expr, command, path)
    elseif result then
      local value = result.result
      -- a pointer shown without its address (gdb prints a char pointer as the string it points
      -- to): the address first, as gdb's own print does
      if result.type and result.type:match("%*%s*$") and not value:match("^0x") then
        local address = util.evaluate(session, "(void *)(" .. value_expr .. ")")
        if address and address.result:match("^0x") then
          value = address.result .. " " .. value
        end
      end
      local var = { name = expr, value = value, type = result.type, variablesReference = result.variablesReference }
      -- a pointer the debugger gives nothing to expand (gdb, a char pointer: it is shown as a
      -- string): what it points to, as its child (set with s, as an expression)
      if result.type and result.type:match("%*%s*$") and (result.variablesReference or 0) == 0 then
        local target = value_expr:match("^&[%w_]+$") and ("*" .. value_expr) or ("*(" .. value_expr .. ")")
        local pointed = util.evaluate(session, target)
        if pointed then
          var.children = {
            {
              name = target,
              value = pointed.result,
              type = pointed.type,
              variablesReference = pointed.variablesReference,
            },
          }
        end
      end
      local row = #canvas.lines + 1
      M.tree:variable(canvas, session, var, path, nil, 0, value_expr, width)
      canvas.items[row].index = i
    else
      no_value(canvas, session, i, expr, err)
    end
  end
end

function M.stopped()
  M.tree:stopped()
end

function M.add(expr, at)
  expr = expr and vim.trim(expr)
  if expr and expr ~= "" then
    if M.tree.expanded["watch:" .. expr] == nil then
      M.tree.expanded["watch:" .. expr] = true -- (a new one opens: its value(s) below it)
    end
    table.insert(M.expressions, math.min(at or (#M.expressions + 1), #M.expressions + 1), expr)
    save()
    util.notify("Watching " .. expr)
    require("dapper.views").refresh("watches")
  end
end

--- the index of the expression of line `line` (of its top-level line, below it), or nil
local function index_at(line)
  local items = require("dapper.canvas").items_of[vim.api.nvim_get_current_buf()] or {}
  if not items[line] then
    return nil
  end
  for l = line, 1, -1 do
    if items[l] and items[l].index then
      return items[l].index
    end
  end
end

--- the index of the expression of the cursor's line
local function index_of(item)
  if not item then
    return nil
  end
  return item.index or index_at(vim.api.nvim_win_get_cursor(0)[1])
end

local function refresh()
  require("dapper.views").refresh("watches")
end

M.keys = vim.list_extend({
  {
    "i",
    "add an expression (above)",
    function(item)
      util.run(function()
        M.add(util.input({ prompt = "Watch: ", completion = COMPLETE }), index_of(item) or 1)
      end)
    end,
  },
  {
    "a",
    "add an expression (below)",
    function(item)
      util.run(function()
        local i = index_of(item)
        M.add(util.input({ prompt = "Watch: ", completion = COMPLETE }), i and (i + 1) or nil)
      end)
    end,
  },
  {
    "e",
    "edit the expression",
    function(item)
      local i = index_of(item)
      if not i then
        return
      end
      util.run(function()
        local expr = util.input({ prompt = "Watch: ", default = M.expressions[i], completion = COMPLETE })
        if expr and vim.trim(expr) ~= "" and vim.trim(expr) ~= M.expressions[i] then
          M.expressions[i] = vim.trim(expr)
          save()
          util.notify("Watching " .. M.expressions[i])
          refresh()
        end
      end)
    end,
  },
  {
    "d",
    "delete the expression",
    function(item)
      local i = index_of(item)
      if i and M.expressions[i] then
        local expr = table.remove(M.expressions, i)
        save()
        util.notify("Stopped watching " .. expr)
        refresh()
      end
    end,
    range = function(_, first, last)
      local indices, seen = {}, {}
      for line = first, last do
        local i = index_at(line)
        if i and M.expressions[i] and not seen[i] then
          seen[i] = true
          table.insert(indices, i)
        end
      end
      if #indices == 0 then
        return
      end
      table.sort(indices)
      local gone = vim.tbl_map(function(i)
        return M.expressions[i]
      end, indices)
      for n = #indices, 1, -1 do -- (from the last: the indices before stay right)
        table.remove(M.expressions, indices[n])
      end
      save()
      refresh()
      util.notify("Stopped watching " .. table.concat(gone, ", "))
    end,
  },
}, tree.keys(refresh))

return M
