--- Scopes: the variables of the selected frame (locals, arguments, registers, ...).

local config = require("dapper.config")
local tree = require("dapper.tree")
local util = require("dapper.util")

local M = { label = "Scopes", key = "S" }

M.tree = tree.new()

function M.render(canvas, session)
  if not session then
    return canvas:note("Not debugging (:Dapper lists what you can do)")
  elseif not session.stopped_thread_id then
    return canvas:note("Running…")
  end
  local frame = session.current_frame
  if not frame then
    return canvas:note("No frame selected")
  end
  local result, err = util.cached(session, "scopes", { frameId = frame.id })
  if not result then
    return canvas:add({ { err, "DapperError" } })
  end
  local icons = config.values.icons
  for _, scope in ipairs(result.scopes or {}) do
    local path = "scope:" .. scope.name
    local open = M.tree.expanded[path]
    if open == nil then -- (open on its own, unless costly to fetch, or the registers: dozens)
      open = not scope.expensive and not scope.name:lower():find("register")
    end
    canvas:add(
      { { (open and icons.expanded or icons.collapsed) .. " ", "DapperMuted" }, { scope.name, "DapperTitle" } },
      { kind = "scope", path = path, tree = M.tree, open = open, depth = 0 }
    )
    if open then
      M.tree:children(canvas, session, scope.variablesReference, path, 1)
    end
  end
end

function M.stopped()
  M.tree:stopped()
end

M.keys = tree.keys(function()
  require("dapper.views").refresh("scopes")
end)

return M
