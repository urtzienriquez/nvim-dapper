--- Sessions: the programs being debugged (and their children); <CR> makes one the current.

local M = { label = "Sessions", short = "Sess", key = "K" }

function M.render(canvas, session)
  local dap = require("dap")
  local any = false
  local function add(s, depth)
    any = true
    local current = session and s.id == session.id
    canvas:add({
      { string.rep("  ", depth) .. (current and "→ " or "  "), "DapperCurrent" },
      { s.config.name or ("session " .. s.id), current and "DapperTitle" or nil },
      { "  " .. (s.config.type or "") .. (s.stopped_thread_id and "  stopped" or "  running"), "DapperMuted" },
    }, { kind = "session", session = s })
    for _, child in pairs(s.children or {}) do
      add(child, depth + 1)
    end
  end
  for _, s in pairs(dap.sessions()) do
    if not s.parent then
      add(s, 0)
    end
  end
  if not any then
    canvas:note("No sessions")
  end
end

M.keys = {
  {
    "<CR>",
    "make it the current session",
    function(item)
      if item and item.session then
        require("dap").set_session(item.session)
        require("dapper.views").refresh()
        require("dapper.util").notify(
          "Current session: " .. (item.session.config.name or ("session " .. item.session.id))
        )
      end
    end,
  },
}

return M
