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

M.keys = {
  {
    "<CR>",
    "toggle",
    function(item)
      local session = require("dap").session()
      if not (item and item.filter and session) then
        return
      end
      local ids = vim.tbl_filter(function(id)
        return id ~= item.filter.filter
      end, chosen(session))
      if not item.on then
        table.insert(ids, item.filter.filter)
      end
      local type = session.config.type
      require("dap").defaults[type].exception_breakpoints = ids -- (the sessions to come)
      for _, s in ipairs(sessions_of(type)) do -- (and those now)
        s:set_exception_breakpoints(ids)
      end
      require("dapper.views").refresh("exceptions")
    end,
  },
}

return M
