--- Exceptions: when to stop on them (the filters the debug adapter offers; e.g. C++ throw). What
--- is chosen is nvim-dap's own setting, dap.defaults[type].exception_breakpoints: set it in your
--- config, or toggle it here (it then applies to the sessions to come too).

local config = require("dapper.config")

local M = { label = "Exceptions", short = "Except", key = "E" }

local function filters(session)
  return session and session.capabilities and session.capabilities.exceptionBreakpointFilters or {}
end

-- the filters on, for `session`'s debugger: nvim-dap's setting ("default": the debugger's defaults)
local function chosen(session)
  local setting = require("dap").defaults[session.config.type].exception_breakpoints
  if type(setting) == "table" then
    return setting
  end
  return vim.tbl_map(
    function(filter)
      return filter.filter
    end,
    vim.tbl_filter(function(filter)
      return filter.default == true
    end, filters(session))
  )
end

function M.render(canvas, session)
  if not session then
    return canvas:note("Not debugging (:Dapper lists what you can do)")
  end
  local list = filters(session)
  if #list == 0 then
    return canvas:note("This debugger offers no exception filters")
  end
  local icons = config.values.icons
  local on_ids = chosen(session)
  for _, filter in ipairs(list) do
    local on = vim.tbl_contains(on_ids, filter.filter)
    canvas:add({
      { (on and icons.enabled or icons.disabled) .. " ", on and "DapperEnabled" or "DapperDisabled" },
      { filter.label },
      filter.description and { "  " .. filter.description, "DapperMuted" } or nil,
    }, { kind = "filter", filter = filter, on = on })
  end
end

-- the sessions of debugger `type` (their children too: js-debug, ...)
local function sessions_of(type)
  local found = {}
  local function walk(session)
    if session.config.type == type and session.initialized then
      table.insert(found, session)
    end
    for _, child in pairs(session.children or {}) do
      walk(child)
    end
  end
  for _, session in pairs(require("dap").sessions()) do
    walk(session)
  end
  return found
end

--- flips the filters of `items` (lines of this view); the debugger and the sessions to come told
local function flip(items)
  local util = require("dapper.util")
  local session = require("dap").session()
  if not session then
    return util.notify("Not debugging", vim.log.levels.WARN)
  end
  local ids = chosen(session)
  local now_on, now_off = {}, {}
  for _, item in ipairs(items) do
    if item.filter then
      ids = vim.tbl_filter(function(id)
        return id ~= item.filter.filter
      end, ids)
      if item.on then
        table.insert(now_off, item.filter.label)
      else
        table.insert(ids, item.filter.filter)
        table.insert(now_on, item.filter.label)
      end
    end
  end
  if #now_on + #now_off == 0 then
    return
  end
  local type = session.config.type
  require("dap").defaults[type].exception_breakpoints = ids -- (the sessions to come)
  for _, s in ipairs(sessions_of(type)) do -- (and those now)
    s:set_exception_breakpoints(ids)
  end
  require("dapper.views").refresh("exceptions")
  local said = {}
  if #now_on > 0 then
    table.insert(said, "Stopping on " .. table.concat(now_on, ", "))
  end
  if #now_off > 0 then
    table.insert(said, (#now_on > 0 and "no more on " or "No more stopping on ") .. table.concat(now_off, ", "))
  end
  util.notify(table.concat(said, "; "))
end

M.keys = {
  {
    "<CR>",
    "toggle",
    function(item)
      flip({ item })
    end,
    range = flip,
  },
}

return M
