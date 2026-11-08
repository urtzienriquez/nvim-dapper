--- Variables as a tree (Scopes, Watches, the hover float): expanded and collapsed by path, with
--- the values that changed since the last stop marked.

local config = require("dapper.config")
local util = require("dapper.util")

local M = {}

---@class dapper.Tree
---@field expanded table<string, boolean>
---@field values table<string, string> the value of each path, as last drawn
---@field before table<string, string> the values at the stop before
local Tree = {}
Tree.__index = Tree

function M.new()
  return setmetatable({ expanded = {}, values = {}, before = {}, summaries = {} }, Tree)
end

--- a new stop: values that differ from now on are "changed"
function Tree:stopped()
  self.before, self.values, self.summaries = self.values, {}, {}
end

local SUMMARY_WIDTH = 60

--- What a struct or an array holds, in one line, as gdb prints it ({mass = 20, id = 7, pos =
--- {…}}, {1, 2, 3}): for the ones the debugger gives no value of their own (gdb gives none).
--- Fetched once per stop.
function Tree:summary(session, ref)
  if self.summaries[ref] == nil then
    local result = session and util.cached(session, "variables", { variablesReference = ref })
    local parts, length = {}, 0
    for _, child in ipairs(result and result.variables or {}) do
      local value = (child.value or ""):gsub("\n", " ")
      if value == "" and (child.variablesReference or 0) > 0 then
        value = "{…}"
      end
      local part = child.name:match("^%[?%d+%]?$") and value or (child.name .. " = " .. value) -- (array: values)
      length = length + #part + 2
      if length > SUMMARY_WIDTH then
        table.insert(parts, "…")
        break
      end
      table.insert(parts, part)
    end
    self.summaries[ref] = result and ("{" .. table.concat(parts, ", ") .. "}") or false
  end
  return self.summaries[ref] or ""
end

--- Draws variable `var` (and its children, if expanded) at `depth`.
--- item fields: kind = "variable", var, path, ref (of its container), depth, tree
-- the C expression of child `name` of the variable whose expression is `parent` (of type
-- `type`): a[2], s.x, p->x, *p (gdb names what a pointer points to "value")
local function child_expression(parent, type, name)
  if not parent then
    return name
  elseif name:sub(1, 1) == "*" then -- (one given: Watches' char pointers)
    return name
  elseif name:match("^%[?%d+%]?$") then
    return parent .. "[" .. name:match("%d+") .. "]"
  end
  local pointer = type and type:match("%*%s*$")
  if pointer and name == "value" then
    return "(*" .. parent .. ")"
  end
  return parent .. (pointer and "->" or ".") .. name
end
M.child_expression = child_expression

local NAME_WIDTH = 24 -- names are padded to the longest of their siblings, up to this

--- the width to pad the names of `vars` to (siblings: their values line up)
function M.name_width(vars, key)
  local width = 0
  for _, var in ipairs(vars) do
    local w = vim.fn.strdisplaywidth(var[key or "name"] or "")
    if w <= NAME_WIDTH then
      width = math.max(width, w)
    end
  end
  return width
end

--- (expr: the variable's C expression, for :Dapper memory; default: its name. width: to pad
--- the name to)
function Tree:variable(canvas, session, var, path, ref, depth, expr, width)
  expr = expr or var.evaluateName or var.name
  local icons = config.values.icons
  -- (var.children: ones given, not the debugger's: see Watches' char pointers)
  local has_children = (var.variablesReference or 0) > 0 or var.children ~= nil
  local open = self.expanded[path]
  local value = var.value or var.result or ""
  if value == "" and has_children and not var.children then
    value = self:summary(session, var.variablesReference)
  end
  self.values[path] = value
  local changed = self.before[path] ~= nil and self.before[path] ~= value
  local chunks = {
    { string.rep("  ", depth) },
    { has_children and ((open and icons.expanded or icons.collapsed) .. " ") or "  ", "DapperMuted" },
    { var.name, "DapperName" },
    { string.rep(" ", (width or 0) - vim.fn.strdisplaywidth(var.name)) .. " = " },
    { value, changed and "DapperChanged" or "DapperValue" },
  }
  if var.type and var.type ~= "" then
    table.insert(chunks, { "  " .. var.type, "DapperType" })
  end
  canvas:add(
    chunks,
    { kind = "variable", var = var, path = path, ref = ref, depth = depth, tree = self, open = open, expr = expr }
  )
  if has_children and open then
    if var.children then
      local w = M.name_width(var.children)
      for _, child in ipairs(var.children) do
        self:variable(canvas, session, child, path .. "/" .. child.name, nil, depth + 1, child.name, w)
      end
    else
      self:children(canvas, session, var.variablesReference, path, depth + 1, { expr = expr, type = var.type })
    end
  end
end

--- Draws the variables of reference `ref`.
function Tree:children(canvas, session, ref, path, depth, parent)
  local result, err = util.cached(session, "variables", { variablesReference = ref })
  if not result then
    canvas:add({ { string.rep("  ", depth + 1) .. err, "DapperError" } })
    return
  end
  local width = M.name_width(result.variables or {})
  for _, var in ipairs(result.variables or {}) do
    local expr = var.evaluateName or child_expression(parent and parent.expr, parent and parent.type, var.name)
    self:variable(canvas, session, var, path .. "/" .. var.name, ref, depth, expr, width)
  end
end

--- opens or closes `path`, which is open now if `open` (remembered either way: a scope that
--- opens on its own can be closed)
function Tree:toggle(path, open)
  self.expanded[path] = not open
end

--- The keys of a tree's lines; refresh() draws the view again.
function M.keys(refresh)
  return {
    {
      "<CR>",
      "expand or collapse",
      function(item)
        local var = item and item.var
        if
          item
          and item.tree
          and (var and ((var.variablesReference or 0) > 0 or var.children) or item.kind == "scope")
        then
          item.tree:toggle(item.path, item.open)
          refresh()
        end
      end,
    },
    {
      "s",
      "set the value",
      function(item)
        if not (item and item.kind == "variable") then
          return
        end
        util.run(function()
          local session = require("dap").session()
          local value = util.input({ prompt = "Value of " .. item.var.name .. ": ", default = item.var.value })
          if not (session and value) then
            return
          end
          local _, err
          if item.ref then
            _, err = util.request(
              session,
              "setVariable",
              { variablesReference = item.ref, name = item.var.name, value = value }
            )
          else -- a watched expression
            _, err = util.request(session, "setExpression", {
              expression = item.var.name,
              value = value,
              frameId = session.current_frame and session.current_frame.id,
            })
          end
          if err then
            util.notify("Could not set it: " .. err, vim.log.levels.WARN)
          end
          util.forget()
          require("dapper.views").refresh() -- (other views may show it too)
          refresh()
        end)
      end,
    },
    {
      "c",
      "copy the value",
      function(item)
        if item and item.var then
          vim.fn.setreg(vim.v.register, item.var.value or "")
          util.notify("Copied: " .. (item.var.value or ""))
        end
      end,
    },
    {
      "x",
      "break when it changes",
      function(item)
        if item and item.expr then
          require("dapper.breaks").toggle_change(item.expr, item)
        end
      end,
    },
    {
      "m",
      "show its memory (in the Memory tab page)",
      function(item)
        if item and item.expr then
          require("dapper").memory(item.expr)
        end
      end,
    },
    {
      "[[",
      "go to the parent",
      function(item)
        if not (item and item.depth and item.depth > 0) then
          return
        end
        local row = vim.api.nvim_win_get_cursor(0)[1]
        local items = require("dapper.canvas").items_of[vim.api.nvim_get_current_buf()] or {}
        for line = row - 1, 1, -1 do
          if items[line] and items[line].depth and items[line].depth < item.depth then
            vim.api.nvim_win_set_cursor(0, { line, 0 })
            return
          end
        end
      end,
    },
  }
end

return M
