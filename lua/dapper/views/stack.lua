--- Call stack: the frames of the stopped thread; the selected one marked. <CR> selects a frame
--- (Scopes and Watches follow) and shows its line.

local config = require("dapper.config")
local util = require("dapper.util")

local M = { label = "Call stack", short = "Calls", key = "C" }

M.hide_subtle = false

--- draws `frames` (shared with Threads), indented by `indent`
function M.frames(canvas, session, frames, indent)
  local icons = config.values.icons
  local current = session.current_frame and session.current_frame.id
  for _, frame in ipairs(frames or {}) do
    local subtle = frame.presentationHint == "subtle" or frame.presentationHint == "label"
    if not (subtle and M.hide_subtle) then
      local where = frame.source and (frame.source.name or frame.source.path)
      local mark = frame.id == current and (icons.current .. " ") or "  "
      canvas:add({
        { indent .. mark, "DapperCurrent" },
        { frame.name, subtle and "DapperMuted" or (frame.id == current and "DapperTitle" or nil) },
        where and { "  " .. where, "DapperFile" } or nil,
        where and { ":" .. frame.line, "DapperLine" } or nil,
      }, { kind = "frame", frame = frame })
    end
  end
end

function M.render(canvas, session)
  if not session then
    return canvas:note("Not debugging (:Dapper lists what you can do)")
  elseif not session.stopped_thread_id then
    return canvas:note("Running…")
  end
  local thread = session.threads and session.threads[session.stopped_thread_id]
  local frames = thread and thread.frames
  if not frames then
    local result, err = util.request(session, "stackTrace", { threadId = session.stopped_thread_id })
    if not result then
      return canvas:add({ { err, "DapperError" } })
    end
    frames = result.stackFrames
  end
  M.frames(canvas, session, frames, "")
end

--- selects the frame of `item` and shows its line (focus: and goes there)
function M.select(item, focus)
  local session = require("dap").session()
  if not (item and item.frame and session) then
    return
  end
  local buf = util.source_buf(item.frame.source)
  if buf then
    util.show_location(buf, item.frame.line, item.frame.column, focus)
  else
    util.notify("No source for " .. item.frame.name)
  end
  session:_frame_set(item.frame)
end

M.keys = {
  {
    "<CR>",
    "select the frame (and show its line)",
    function(item)
      M.select(item, false)
    end,
  },
  {
    "o",
    "select the frame, and go to its line",
    function(item)
      M.select(item, true)
    end,
  },
  {
    "D",
    "its disassembly (in the Disassembly tab page)",
    function(item)
      if item and item.frame then
        M.select(item, false) -- (Disassembly follows the selected frame)
        require("dapper").disassembly()
      end
    end,
  },
  {
    "t",
    "hide or show the frames of no interest (library code)",
    function()
      M.hide_subtle = not M.hide_subtle
      require("dapper.views").refresh()
    end,
  },
}

return M
