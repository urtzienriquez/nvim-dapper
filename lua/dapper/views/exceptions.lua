--- Exceptions: when to stop on them (the filters the debug adapter offers; e.g. C++ throw).

local config = require("dapper.config")

local M = { label = "Exceptions", short = "Except", key = "E" }

M.enabled = {} -- adapter type -> { [filter] = true|false }

local function filters(session)
  return session and session.capabilities and session.capabilities.exceptionBreakpointFilters or {}
end

local function enabled(session, filter)
  local chosen = M.enabled[session.config.type] or {}
  if chosen[filter.filter] == nil then
    return filter.default == true
  end
  return chosen[filter.filter]
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
  for _, filter in ipairs(list) do
    local on = enabled(session, filter)
    canvas:add({
      { (on and icons.enabled or icons.disabled) .. " ", on and "DapperEnabled" or "DapperDisabled" },
      { filter.label },
      filter.description and { "  " .. filter.description, "DapperMuted" } or nil,
    }, { kind = "filter", filter = filter, on = on })
  end
end

--- sends the chosen filters to the sessions of the same debugger
local function apply(type)
  for _, session in pairs(require("dap").sessions()) do
    if session.config.type == type and session.initialized then
      local ids = {}
      for _, filter in ipairs(filters(session)) do
        if enabled(session, filter) then
          table.insert(ids, filter.filter)
        end
      end
      session:set_exception_breakpoints(ids)
    end
  end
end

M.keys = {
  {
    "<CR>",
    "toggle",
    function(item)
      local session = require("dap").session()
      if not (item and item.filter and session) then
        return
      end
      local type = session.config.type
      M.enabled[type] = M.enabled[type] or {}
      M.enabled[type][item.filter.filter] = not item.on
      apply(type)
      -- (and for the sessions to come: nvim-dap sends these before the program starts)
      local ids = {}
      for _, filter in ipairs(filters(session)) do
        if enabled(session, filter) then
          table.insert(ids, filter.filter)
        end
      end
      require("dap").defaults[type].exception_breakpoints = ids
      require("dapper.views").refresh("exceptions")
    end,
  },
}

return M
