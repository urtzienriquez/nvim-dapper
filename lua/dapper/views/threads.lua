--- Threads: every thread of the program, and the frames of the stopped ones.

local stack = require("dapper.views.stack")
local util = require("dapper.util")

local M = { label = "Threads", key = "T" }

M.filter = nil -- frames shown: only those whose name or file has it (or, inverted, has it not)
M.invert = false

local function shown(frame)
  if not M.filter then
    return true
  end
  local text = frame.name .. " " .. (frame.source and (frame.source.path or frame.source.name) or "")
  local found = text:lower():find(M.filter:lower(), 1, true) ~= nil
  return found ~= M.invert
end

function M.render(canvas, session)
  if not session then
    return canvas:note("Not debugging (:Dapper lists what you can do)")
  end
  local threads = vim.tbl_values(session.threads or {})
  table.sort(threads, function(a, b)
    return a.id < b.id
  end)
  if #threads == 0 then
    return canvas:note("No threads")
  end
  if M.filter then
    canvas:note((M.invert and "Frames without: " or "Frames with: ") .. M.filter)
  end
  for _, thread in ipairs(threads) do
    local stopped = thread.stopped or session.stopped_thread_id == thread.id
    canvas:add({
      { stopped and "⏸ " or "▶ ", "DapperMuted" },
      { thread.name, thread.id == session.stopped_thread_id and "DapperTitle" or nil },
      { "  #" .. thread.id, "DapperMuted" },
    }, { kind = "thread", thread = thread })
    local frames = thread.frames
    if stopped and not frames and session.stopped_thread_id then
      local result = util.request(session, "stackTrace", { threadId = thread.id, levels = 20 })
      frames = result and result.stackFrames
    end
    stack.frames(canvas, session, vim.tbl_filter(shown, frames or {}), "  ")
  end
end

M.keys = {
  stack.keys[1], -- <CR>: select the frame
  stack.keys[2], -- o
  stack.keys[3], -- D
  stack.keys[4], -- t
  {
    "f",
    "filter the frames",
    function()
      util.run(function()
        local text = util.input({ prompt = "Frames with: ", default = M.filter or "" })
        if text then
          local had = M.filter
          M.filter = text ~= "" and text or nil
          require("dapper.views").refresh("threads")
          if had and not M.filter then
            util.notify("Filter off")
          end
        end
      end)
    end,
  },
  {
    "F",
    "invert the filter",
    function()
      if not M.filter then
        return util.notify("No filter to invert (f sets one)", vim.log.levels.WARN)
      end
      M.invert = not M.invert
      require("dapper.views").refresh("threads")
      util.notify((M.invert and "Frames without: " or "Frames with: ") .. M.filter)
    end,
  },
}

return M
