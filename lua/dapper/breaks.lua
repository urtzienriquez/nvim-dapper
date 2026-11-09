--- Breakpoints nvim-dap has no interface for:
--- - on a function, by name (:Dapper break malloc): kept per project, sent to each session;
--- - when a value changes (x on a variable in Watches, Scopes, the hover float): with the
---   debugger's data breakpoints if it has them, else gdb's watch -location (it stays on that
---   memory when the function returns). For this session only.
--- Both are listed in the Breakpoints view (d deletes).

local util = require("dapper.util")

local M = {}

---@class dapper.FunctionBreakpoint
---@field name string
---@field id? integer the debugger's
---@field verified? boolean
---@field reason? string "pending" (the program not loaded yet), "failed"
---@field source? table where it was placed, once verified
---@field line? integer

M.functions = {} ---@type dapper.FunctionBreakpoint[] (kept per project)
local function save_functions()
  require("dapper.store").set(
    "functions",
    vim.tbl_map(function(f)
      return f.name
    end, M.functions)
  )
end
require("dapper.store").track("functions", M.functions, save_functions, function(name)
  return { name = name }
end)

M.changes = {} ---@type { expr: string, id?: any }[] (this session's)

local function refresh()
  require("dapper.views").refresh("breakpoints")
end

----------------------------------------
-- on a function

--- sends the function breakpoints to `session` (all of them: the request replaces them)
function M.send_functions(session)
  session = session or require("dap").session()
  if not (session and session.capabilities and session.capabilities.supportsFunctionBreakpoints) then
    return refresh()
  end
  util.run(function()
    local result = util.request(session, "setFunctionBreakpoints", {
      breakpoints = vim.tbl_map(function(f)
        return { name = f.name }
      end, M.functions),
    })
    for i, bp in ipairs(result and result.breakpoints or {}) do
      local f = M.functions[i]
      if f then
        f.id, f.verified, f.reason, f.source, f.line = bp.id, bp.verified, bp.reason, bp.source, bp.line
      end
    end
    refresh()
  end)
end

--- the debugger says a breakpoint changed (event_breakpoint): one sent before the program was
--- loaded ("pending") is verified once it is, and placed (gdb: at the function's first line)
function M.changed(bp)
  for _, f in ipairs(M.functions) do
    if bp.id and f.id == bp.id then
      f.verified, f.reason = bp.verified, bp.reason
      f.source, f.line = bp.source or f.source, bp.line or f.line
    end
  end
end

--- breaks on function `name` (or no more, if it did)
function M.toggle_function(name)
  name = vim.trim(name or "")
  if name == "" then
    return
  end
  local found
  for i, f in ipairs(M.functions) do
    if f.name == name then
      found = i
    end
  end
  if found then
    table.remove(M.functions, found)
    util.notify("No more breaking on " .. name)
  else
    table.insert(M.functions, { name = name })
    util.notify("Breaking on " .. name)
  end
  save_functions()
  M.send_functions()
end

----------------------------------------
-- when a value changes

local function gdb_like(session)
  return not (session.capabilities and session.capabilities.supportsDataBreakpoints)
end

--- the data breakpoints of the debugger (DAP), all sent again
local function send_data(session)
  local list = {}
  for _, c in ipairs(M.changes) do
    if c.id then
      table.insert(list, { dataId = c.id, accessType = "write" })
    end
  end
  util.request(session, "setDataBreakpoints", { breakpoints = list })
end

--- breaks when `expr` changes (item: its variable, for debuggers with data breakpoints), or no
--- more, if it did
function M.toggle_change(expr, item)
  local session = require("dap").session()
  if not (session and session.stopped_thread_id) then
    return util.notify("The program has to be stopped, to watch a value", vim.log.levels.WARN)
  end
  util.run(function()
    for i, c in ipairs(M.changes) do
      if c.expr == expr then -- (it did: no more)
        table.remove(M.changes, i)
        if gdb_like(session) then
          util.request(session, "evaluate", { expression = "delete " .. c.id, context = "repl" })
        else
          send_data(session)
        end
        util.notify("No more breaking when " .. expr .. " changes")
        return refresh()
      end
    end
    local entry = { expr = expr }
    if gdb_like(session) then
      local result, err = util.evaluate(session, "watch -location " .. expr, "repl")
      local id = result and result.result:match("atchpoint (%d+)")
      if not id then
        return util.notify(
          "Cannot watch " .. expr .. ": " .. tostring(err or (result and result.result)),
          vim.log.levels.WARN
        )
      end
      entry.id = id
    else
      local info = util.request(session, "dataBreakpointInfo", {
        name = item and item.var and item.var.name or expr,
        variablesReference = item and item.ref,
        frameId = session.current_frame and session.current_frame.id,
      })
      if not (info and info.dataId) then
        return util.notify("This debugger cannot watch " .. expr, vim.log.levels.WARN)
      end
      entry.id = info.dataId
    end
    table.insert(M.changes, entry)
    if not gdb_like(session) then
      send_data(session)
    end
    util.notify("Breaking when " .. expr .. " changes")
    refresh()
  end)
end

--- the session ended: its value watches go with it
function M.session_ended()
  M.changes = {}
  for _, f in ipairs(M.functions) do
    f.id, f.verified, f.reason, f.source, f.line = nil, nil, nil, nil, nil
  end
end

return M
