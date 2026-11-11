--- nvim-dapper: a UI for nvim-dap, in panes. See :help dapper.

local config = require("dapper.config")

local M = {}

local api = vim.api

local function panes()
  return require("dapper.panes")
end
local function views()
  return require("dapper.views")
end

----------------------------------------
-- looks

local HIGHLIGHTS = {
  DapperTab = "TabLine",
  DapperTabSelected = "TabLineSel",
  DapperTabFill = "TabLineFill",
  DapperControls = "TabLine",
  DapperTitle = "Title",
  DapperName = "Identifier",
  DapperType = "Comment",
  DapperValue = "Normal",
  DapperChanged = "DiagnosticVirtualTextWarn", -- (well in sight: Changed is only a color)
  DapperMuted = "Comment",
  DapperError = "DiagnosticError",
  DapperFile = "Directory",
  DapperLine = "LineNr",
  DapperCurrent = "DiagnosticOk",
  DapperEnabled = "DiagnosticOk",
  DapperDisabled = "Comment",
  DapperVirtualText = "Comment",
  DapperPc = "Visual", -- (the current instruction, as nvim-dap's DapStopped line)
  DapperMemory1 = "DiagnosticVirtualTextInfo", -- (the variables' bytes, in turn)
  DapperMemory2 = "DiagnosticVirtualTextHint",
  DapperMemory3 = "DiagnosticVirtualTextOk",
  DapperMemory4 = "DiffText",
  DapperMemoryCursor = "Search", -- (Memory: the byte under the cursor, in hex and as text)
  DapperSync = "DiffChange", -- (Disassembly: the instructions of the source line shown)
  DapperPin = "DiagnosticVirtualTextHint", -- (pins: their values at the end of their lines)
  DapperHint = "Comment", -- (the panes' bar: g?)
}

local function highlights()
  for group, link in pairs(HIGHLIGHTS) do
    api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local SIGNS = {
  DapBreakpoint = { text = "●", texthl = "DiagnosticError" },
  DapBreakpointCondition = { text = "◆", texthl = "DiagnosticWarn" },
  DapLogPoint = { text = "◉", texthl = "DiagnosticInfo" },
  DapStopped = { text = "→", texthl = "DiagnosticOk", linehl = "Visual" },
  DapBreakpointRejected = { text = "✗", texthl = "DiagnosticHint" },
}

----------------------------------------
-- following the debugger

local last_frame -- the frame the views were drawn for

local function refresh(name)
  vim.schedule(function()
    views().refresh(name)
  end)
end

local function virtual_text()
  if config.values.virtual_text then
    vim.schedule(require("dapper.virtual_text").update)
  end
end

local function clear_virtual_text()
  if package.loaded["dapper.virtual_text"] then
    vim.schedule(require("dapper.virtual_text").clear)
  end
end

local function listen()
  local dap = require("dap")
  local before, after = dap.listeners.before, dap.listeners.after
  local id = "dapper"

  for _, event in ipairs({ "launch", "attach" }) do
    after[event][id] = function()
      if config.values.auto_open then
        vim.schedule(panes().open)
      end
      vim.schedule(function() -- (the pins of the project, in the files open)
        require("dapper.pins").draw()
      end)
    end
  end
  for _, event in ipairs({ "event_terminated", "disconnect" }) do
    before[event][id] = function(session)
      -- (a child session ending, e.g. js-debug's, leaves its parent running: the panes stay)
      if config.values.auto_close and not session.parent and vim.tbl_count(dap.sessions()) <= 1 then
        vim.schedule(panes().close)
      end
    end
  end

  -- status() changed: the status lines say it (once nvim-dap is done with the event)
  local function redraw_status()
    vim.schedule(function()
      vim.cmd("redrawstatus!")
    end)
  end

  -- A stop: the views that show the frame are drawn once nvim-dap has selected it (it then asks
  -- for its scopes, below), not before: they would show the old one, and draw twice.
  after.event_stopped[id] = function()
    last_frame = nil
    require("dapper.util").forget()
    views().stopped()
    if package.loaded["dapper.pins"] then
      require("dapper.pins").stopped()
    end
    refresh("breakpoints")
    refresh("sessions")
    vim.defer_fn(function() -- (no frame selected, e.g. a thread without source: draw anyway)
      if last_frame == nil then
        views().refresh()
      end
    end, 300)
  end
  -- nvim-dap asks for the scopes of the frame it selects (after a stop, or a frame chosen):
  -- draw then, once per frame (the views ask for scopes too)
  after.scopes[id] = function(session)
    local frame = session.current_frame and session.current_frame.id
    if frame ~= last_frame then
      last_frame = frame
      refresh()
      virtual_text()
      redraw_status()
      if package.loaded["dapper.pins"] then
        vim.schedule(require("dapper.pins").update)
      end
    end
  end
  for _, event in ipairs({ "event_continued", "event_terminated", "event_exited", "disconnect" }) do
    after[event][id] = function()
      last_frame = nil
      require("dapper.util").forget()
      if event ~= "event_continued" then
        vim.schedule(function() -- (once nvim-dap is done with it: no session left, the state goes)
          if next(require("dap").sessions()) ~= nil then
            return -- (another session goes on: its state stays)
          end
          if package.loaded["dapper.views.disassembly"] then
            require("dapper.views.disassembly").anchor = nil -- (an address: another, next session)
          end
          if package.loaded["dapper.breaks"] then
            require("dapper.breaks").session_ended()
          end
        end)
      end
      if package.loaded["dapper.pins"] then
        vim.schedule(require("dapper.pins").running)
      end
      refresh()
      clear_virtual_text()
      redraw_status()
    end
  end
  for _, event in ipairs({ "setBreakpoints", "event_breakpoint" }) do
    after[event][id] = function(_, body)
      if event == "event_breakpoint" and body and body.breakpoint and package.loaded["dapper.breaks"] then
        require("dapper.breaks").changed(body.breakpoint) -- (a pending one, verified)
      end
      refresh("breakpoints")
    end
  end
  after.event_thread[id] = function()
    refresh("threads")
  end
  -- the files with breakpoints opened (unseen) before nvim-dap sends the breakpoints: all are sent
  before.event_initialized[id] = function()
    require("dapper.lines").load_all()
  end
  after.event_initialized[id] = function(session)
    redraw_status()
    refresh("exceptions")
    refresh("sessions")
    if package.loaded["dapper.views.disassembly"] and next(require("dapper.views.disassembly").breakpoints) then
      require("dapper.views.disassembly").send(session) -- (kept from session to session)
    end
    if #require("dapper.breaks").functions > 0 then -- (on functions: kept per project)
      require("dapper.breaks").send_functions(session)
    end
  end

  -- gdb answers the breakpoints set before the program is loaded ("pending") without their line,
  -- and nvim-dap, which finds a breakpoint's sign by its line, then gives every breakpoint of a
  -- file the state of the last one: all but one look rejected (✗), although they work. The
  -- answer lists them in the order they were asked for, so their lines are known.
  before.setBreakpoints[id] = function(_, err, response, request)
    if err or not response or not request or not request.breakpoints then
      return
    end
    for i, bp in ipairs(response.breakpoints or {}) do
      if bp.line == nil and request.breakpoints[i] then
        bp.line = request.breakpoints[i].line
      end
    end
  end

  -- programs that ask for a terminal (runInTerminal) get one without a window: "Program I/O"
  -- shows it (unless you set nvim-dap's terminal_win_cmd yourself)
  if dap.defaults.fallback.terminal_win_cmd == "belowright new" then
    dap.defaults.fallback.terminal_win_cmd = function()
      return require("dapper.io").terminal_buffer()
    end
  end
end

-- the program stops: its line is shown (in the window showing that file, else in a code window),
-- but the cursor stays where it was, unlike nvim-dap's own way (keep_cursor)
local function own_switchbuf(buf, line, column)
  require("dapper.util").show_location(buf, line, column, false)
end
local switchbuf_before -- what it was before dapper's

local function apply_keep_cursor()
  local defaults = require("dap").defaults.fallback
  if config.values.keep_cursor and defaults.switchbuf ~= own_switchbuf then
    switchbuf_before = defaults.switchbuf
    defaults.switchbuf = own_switchbuf
  elseif not config.values.keep_cursor and defaults.switchbuf == own_switchbuf then
    defaults.switchbuf = switchbuf_before -- (setup() again, without it)
  end
end

local set_up = false

--- Sets it up: hooks it to nvim-dap (needed: until then, it does not follow the debugger; :Dapper
--- also does it, with the defaults). Calling it again applies the new options.
function M.setup(opts)
  config.set(opts)
  if package.loaded["dapper.panes"] then
    panes().forget() -- (the new layout, not the panes as they were left)
  end
  highlights()
  api.nvim_create_autocmd("ColorScheme", {
    group = api.nvim_create_augroup("dapper", {}),
    callback = highlights,
  })
  if config.values.signs then
    require("dap") -- (it defines its signs: replaced only where they are still its own)
    for name, sign in pairs(SIGNS) do
      local defined = vim.fn.sign_getdefined(name)[1]
      if not defined or defined.texthl == "SignColumn" then
        vim.fn.sign_define(name, sign)
      end
    end
  end
  api.nvim_create_autocmd("TabEnter", {
    group = "dapper",
    callback = function()
      if not package.loaded["dapper.panes"] then
        return
      end
      panes().on_tab_entered()
      if config.values.follow_tab and require("dap").session() then
        panes().follow()
      end
    end,
  })
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, { -- narrow panes: shorter tabs
    group = "dapper",
    callback = function()
      if package.loaded["dapper.panes"] and panes().is_open() then
        panes().on_resized()
        panes().refresh_bars()
      end
    end,
  })
  api.nvim_create_autocmd("WinClosed", { -- a pane closed with :q: the layout kept
    group = "dapper",
    callback = function(ev)
      if package.loaded["dapper.panes"] then
        panes().on_closed(tonumber(ev.match))
      end
    end,
  })
  api.nvim_create_autocmd("WinNew", { -- :vsplit in a pane: redone as a pane split
    group = "dapper",
    callback = function()
      if package.loaded["dapper.panes"] then
        panes().on_new_window()
      end
    end,
  })
  api.nvim_create_autocmd("WinEnter", { -- breakpoints change without telling the debugger
    group = "dapper",
    callback = function()
      if vim.bo.filetype == "dapper" and package.loaded["dapper.views"] then
        views().refresh("breakpoints")
      end
    end,
  })
  -- breakpoints on lines and pins, kept per project: given back to a file opened, kept where
  -- edits moved them
  local lines = require("dapper.lines")
  api.nvim_create_autocmd("BufReadPost", {
    group = "dapper",
    callback = function(ev)
      lines.restore(ev.buf)
      if package.loaded["dapper.pins"] then
        require("dapper.pins").draw(ev.buf)
      end
    end,
  })
  api.nvim_create_autocmd("BufUnload", {
    group = "dapper",
    callback = function(ev)
      lines.unloading(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "BufWritePost", "VimLeavePre" }, {
    group = "dapper",
    callback = function()
      lines.save()
      if package.loaded["dapper.pins"] then
        require("dapper.pins").save()
      end
    end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do -- (files open before setup())
    if api.nvim_buf_is_loaded(buf) then
      lines.restore(buf)
    end
  end
  if not set_up then
    listen()
  end
  -- no gdb adapter of yours: dapper's (whose program gets the Program I/O terminal)
  local dap = require("dap")
  if dap.adapters.gdb == nil and vim.fn.executable("gdb") == 1 then
    dap.adapters.gdb = M.gdb()
  end
  -- "Launch" and "Attach to process" in its list (in the `configurations` filetypes)
  if type(dap.providers) == "table" and type(dap.providers.configs) == "table" then
    dap.providers.configs.dapper = function(bufnr)
      return require("dapper.configurations").provider(bufnr)
    end
  end
  apply_keep_cursor()
  set_up = true
end

--- whether setup() was called (or done by :Dapper)
function M.is_set_up()
  return set_up
end

local function ensure()
  if not set_up then
    M.setup({})
  end
end

----------------------------------------
-- the API (and :Dapper)

function M.open()
  ensure()
  panes().open()
end

function M.close()
  ensure()
  panes().close()
end

function M.toggle()
  ensure()
  panes().toggle()
end

--- shows view `name` in a pane (opening them)
function M.show(name)
  ensure()
  if not vim.tbl_contains(config.values.views, name) then
    return require("dapper.util").notify("No view " .. tostring(name), vim.log.levels.WARN)
  end
  panes().show(name)
end

--- watches `expr` (default: the selection, or the expression under the cursor)
function M.watch(expr)
  ensure()
  expr = expr or require("dapper.util").expression()
  require("dapper.views.watches").add(expr)
  if not panes().shows("watches") then
    panes().show("watches")
  end
end

--- the memory at `expr` (an address, a variable, an expression; default: the selection, or the
--- expression under the cursor, else the current frame's variables), in the Memory tab page
function M.memory(expr)
  ensure()
  local implicit = expr == nil and vim.bo.filetype ~= "dapper"
  if implicit then
    expr = require("dapper.util").expression() -- (not an address, or nothing: the frame's variables)
  end
  require("dapper.tabs").open("memory")
  if expr then
    require("dapper.views.memory").go(expr, implicit)
  end
end

--- the disassembly at `expr` (a function, an address, an expression; default: from a file, the
--- cursor's line, its instructions highlighted; else the current instruction, followed), in the
--- Disassembly tab page
function M.disassembly(expr)
  ensure()
  local buf = api.nvim_get_current_buf()
  local from_code = expr == nil and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= ""
  local path, line = vim.fs.normalize(api.nvim_buf_get_name(buf)), api.nvim_win_get_cursor(0)[1]
  require("dapper.tabs").open("disassembly")
  if from_code and require("dap").session() then -- (the cursor's line: its instructions)
    require("dapper.views.disassembly").go_line(path, line)
  else
    require("dapper.views.disassembly").go(expr ~= "" and expr or nil)
  end
end

--- the value of `expr` (default: the selection, or the expression under the cursor) in a float
function M.hover(expr)
  ensure()
  require("dapper.hover").show(expr)
end

--- turns the values of variables at the end of their lines on or off
function M.toggle_virtual_text()
  ensure()
  config.values.virtual_text = not config.values.virtual_text
  require("dapper.util").notify(config.values.virtual_text and "Inline values on" or "Inline values off")
  if config.values.virtual_text then
    require("dapper.virtual_text").update()
  else
    clear_virtual_text()
  end
end

-- the breakpoint on the cursor's line, if there is one
-- the breakpoint of the cursor's line, or nil; false: the cursor is not on a line of a file
local function breakpoint_here()
  local buf, line = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)[1]
  if vim.bo[buf].buftype ~= "" or api.nvim_buf_get_name(buf) == "" then
    require("dapper.util").notify("Breakpoints go on a line of a file", vim.log.levels.WARN)
    return false
  end
  for _, bp in ipairs(require("dap.breakpoints").get(buf)[buf] or {}) do
    if bp.line == line then
      return bp
    end
  end
end

--- a breakpoint on the cursor's line with a condition (asked, with completion; the line's own
--- condition to edit, if it has one). <Esc>, or nothing typed: no breakpoint.
function M.conditional_breakpoint()
  ensure()
  local existing = breakpoint_here()
  if existing == false then
    return
  end
  existing = existing or {}
  local line = api.nvim_win_get_cursor(0)[1] -- (for the message: the prompt may move the cursor)
  require("dapper.util").prompt({
    prompt = "Break if: ",
    default = existing.condition,
    completion = "customlist,v:lua.require'dapper'.complete",
  }, function(condition)
    if condition and vim.trim(condition) ~= "" then -- (its hit count and log message kept)
      require("dap").set_breakpoint(vim.trim(condition), existing.hitCondition, existing.logMessage)
      require("dapper.util").notify(("Breaking on line %d if %s"):format(line, vim.trim(condition)))
    end
  end)
end

--- deletes all breakpoints: on lines (of every file, also those turned off: kept per project, so
--- nvim-dap's clear_breakpoints(), which knows only the files open, is not enough), on functions,
--- on instructions, and on values changing
function M.clear_breakpoints()
  ensure()
  require("dapper.lines").clear()
  require("dapper.breaks").clear()
  if package.loaded["dapper.views.disassembly"] then
    local disassembly = require("dapper.views.disassembly")
    disassembly.breakpoints = {}
    disassembly.send()
  end
  views().refresh("breakpoints")
  views().refresh("disassembly")
  require("dapper.util").notify("All breakpoints deleted")
end

--- values in hex, or not (in Watches, Scopes, the hover float, inline values and pins)
function M.toggle_hex()
  ensure()
  local util = require("dapper.util")
  util.hex = not util.hex
  util.notify(util.hex and "Values in hex" or "Values as they are")
  if package.loaded["dap"] and require("dap").session() then
    util.values_changed()
  end
end

--- a breakpoint on the cursor's line that stops on its Nth hit (asked; the line's own to edit; its
--- condition and log message kept). <Esc>, or nothing typed: none.
function M.hit_breakpoint()
  ensure()
  local existing = breakpoint_here()
  if existing == false then
    return
  end
  existing = existing or {}
  local line = api.nvim_win_get_cursor(0)[1] -- (for the message: the prompt may move the cursor)
  require("dapper.util").prompt({ prompt = "Stop on hit number: ", default = existing.hitCondition }, function(hits)
    if hits and vim.trim(hits) ~= "" then
      require("dap").set_breakpoint(existing.condition, vim.trim(hits), existing.logMessage)
      require("dapper.util").notify(("Stopping on hit %s of line %d"):format(vim.trim(hits), line))
    end
  end)
end

--- a log point on the cursor's line: a message printed (in the REPL) instead of stopping, with
--- the values of the expressions in {} (e.g. "n is {n}"). <Esc>, or nothing typed: none.
function M.log_point()
  ensure()
  local existing = breakpoint_here()
  if existing == false then
    return
  end
  existing = existing or {}
  local line = api.nvim_win_get_cursor(0)[1] -- (for the message: the prompt may move the cursor)
  require("dapper.util").prompt({
    prompt = "Log (expressions in {}): ",
    default = existing.logMessage,
    completion = "customlist,v:lua.require'dapper'.complete",
  }, function(message)
    if message and vim.trim(message) ~= "" then -- (its condition and hit count kept)
      require("dap").set_breakpoint(existing.condition, existing.hitCondition, message)
      require("dapper.util").notify(("Logging on line %d: %s"):format(line, message))
    end
  end)
end

--- breaks on function `name` (or no more), in this and the next sessions
function M.break_on(name)
  ensure()
  require("dapper.breaks").toggle_function(name)
end

--- breaks when `expr` changes (default: the selection, or the expression under the cursor)
function M.break_on_change(expr)
  ensure()
  expr = expr or require("dapper.util").expression()
  if expr ~= "" then
    require("dapper.breaks").toggle_change(expr)
  else
    require("dapper.util").notify("No expression under the cursor", vim.log.levels.WARN)
  end
end

--- pins `expr` (default: the selection, or the expression under the cursor) to the cursor's line
function M.pin(expr)
  ensure()
  require("dapper.pins").toggle(expr or require("dapper.util").expression())
end

--- set next statement: the program goes on from the cursor's line (without running the lines
--- between)
function M.jump()
  ensure()
  local util = require("dapper.util")
  local session = require("dap").session()
  if not (session and session.stopped_thread_id) then
    return util.notify("The program has to be stopped", vim.log.levels.WARN)
  end
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then
    return util.notify("Put the cursor on the line of code to go on from", vim.log.levels.WARN)
  end
  local path, line = vim.fs.normalize(api.nvim_buf_get_name(buf)), api.nvim_win_get_cursor(0)[1]
  util.run(function()
    if session.capabilities and session.capabilities.supportsGotoTargetsRequest then
      local targets = util.request(session, "gotoTargets", { source = { path = path }, line = line })
      local target = targets and targets.targets and targets.targets[1]
      if not target then
        return util.notify("Cannot go on from line " .. line, vim.log.levels.WARN)
      end
      util.request(session, "goto", { threadId = session.stopped_thread_id, targetId = target.id })
    else -- (gdb: a temporary breakpoint there, then jump: it stops at once)
      local where = ("%s:%d"):format(path, line)
      local frame = session.current_frame and session.current_frame.id
      util.request(session, "evaluate", { expression = "tbreak " .. where, context = "repl", frameId = frame })
      local result, err =
        util.request(session, "evaluate", { expression = "jump " .. where, context = "repl", frameId = frame })
      if err or (result and result.result:find("not within", 1, true)) then
        util.notify("Cannot go on from line " .. line .. ": " .. tostring(err or result.result), vim.log.levels.WARN)
      end
    end
  end)
end

--- for a status line: what the debugger is doing ("⏸ stats.c:42 maximum", "▶ running"; "" when
--- not debugging)
function M.status()
  if not package.loaded["dap"] then
    return ""
  end
  local session = require("dap").session()
  if not session then
    return ""
  end
  local frame = session.stopped_thread_id and session.current_frame
  if not frame then
    return session.stopped_thread_id and "⏸ stopped" or "▶ running"
  end
  local where = frame.source and frame.source.name and (frame.source.name .. ":" .. frame.line) or ""
  return vim.trim("⏸ " .. where .. " " .. (frame.name or ""))
end

--- for completion = "customlist,v:lua.require'dapper'.complete": the variables of the selected
--- frame (and the watched expressions)
function M.complete(lead)
  return require("dapper.complete").expressions(lead)
end

--- dapper's prompt (vim.ui.input's options), where <C-f> opens a window to edit the line in;
--- waited for, so in a coroutine, as nvim-dap's configuration functions run: the typed text, or
--- nil when cancelled
function M.input(opts)
  return require("dapper.util").input(opts)
end

--- :Dapper: every action, to pick from (those that need a stopped program, while it is)
function M.palette()
  ensure()
  local util = require("dapper.util")
  local in_code = vim.bo.buftype == "" and api.nvim_buf_get_name(0) ~= ""
  local expr = in_code and util.expression() or ""
  local session = package.loaded["dap"] and require("dap").session()
  local stopped = session and session.stopped_thread_id
  -- an action that takes a value: with a :Dapper subcommand (`cmd`), that put on the command line
  -- to be edited there (where <C-f> opens the command-line window); else asked
  local function ask(prompt, completion, fn, cmd)
    return function()
      if cmd then
        return util.cmdline(("Dapper %s %s"):format(cmd, expr))
      end
      util.run(function()
        local value = util.input({ prompt = prompt, default = expr, completion = completion })
        if value and vim.trim(value) ~= "" then
          fn(vim.trim(value))
        end
      end)
    end
  end
  local complete = "customlist,v:lua.require'dapper'.complete"
  -- { label, action, stop = it needs a stopped program, code = it needs the cursor in a file }
  -- (cmd: the :Dapper subcommand, or fn: the function, that a key of yours may run)
  local actions = {
    { "Open or close the panes", M.toggle, cmd = "toggle" },
    { "Watch an expression…", ask("Watch: ", complete, M.watch, "watch"), cmd = "watch" },
    { "Show a value (hover)…", ask("Value of: ", complete, M.hover, "hover"), stop = true, cmd = "hover" },
    { "Memory at…", ask("Memory at: ", complete, M.memory, "memory"), stop = true, cmd = "memory" },
    {
      "Memory: the frame's variables",
      function()
        M.memory("")
      end,
      stop = true,
    },
    {
      "Disassembly (the current instruction)",
      function()
        M.disassembly("")
      end,
      stop = true,
    },
    { "Disassembly of this line", M.disassembly, stop = true, code = true, cmd = "disassembly" },
    { "Break on this line, if…", M.conditional_breakpoint, code = true, cmd = "condition", fn = M.conditional_breakpoint },
    { "Log on this line (a log point)…", M.log_point, code = true, cmd = "log", fn = M.log_point },
    { "Break on this line on its Nth hit…", M.hit_breakpoint, code = true, cmd = "hits", fn = M.hit_breakpoint },
    { "Run to this line", require("dap").run_to_cursor, stop = true, code = true, fn = require("dap").run_to_cursor },
    { "Delete all breakpoints", M.clear_breakpoints, cmd = "clear", fn = M.clear_breakpoints },
    {
      "Break on a function…",
      ask("Break on function: ", "customlist,v:lua.require'dapper.complete'.functions", M.break_on, "break"),
    },
    {
      "Break when a value changes…",
      ask("Break when it changes: ", complete, M.break_on_change, "break-change"),
      stop = true,
      cmd = "break-change",
    },
    { "Pin a value to this line…", ask("Pin: ", complete, M.pin, "pin"), code = true, cmd = "pin" },
    { "Go on from this line (set next statement)", M.jump, stop = true, code = true, cmd = "jump" },
    { "Inline values on or off", M.toggle_virtual_text, cmd = "virtual-text" },
    { "Values in hex on or off", M.toggle_hex, cmd = "hex" },
    {
      "Check the setup (:checkhealth dapper)",
      function()
        vim.cmd("checkhealth dapper")
      end,
    },
    {
      "Help (:help dapper)",
      function()
        vim.cmd("help dapper")
      end,
    },
  }
  -- your keys for them, shown with them (to learn them)
  local leader = vim.g.mapleader or "\\"
  local keys = {}
  for _, map in ipairs(api.nvim_get_keymap("n")) do
    local lhs = map.lhs:sub(1, #leader) == leader and ("<leader>" .. map.lhs:sub(#leader + 1)) or map.lhs
    for _, action in ipairs(actions) do
      local rhs = (map.rhs or ""):lower()
      if
        (action.fn and map.callback == action.fn)
        or (action.cmd and rhs:find("dapper " .. action.cmd:lower() .. "<cr>", 1, true))
      then
        keys[action] = keys[action] or lhs
      end
    end
  end
  local width = 0
  for _, action in ipairs(actions) do
    width = math.max(width, vim.fn.strdisplaywidth(action[1]))
  end
  local available = vim.tbl_filter(function(action)
    return (stopped or not action.stop) and (in_code or not action.code)
  end, actions)
  vim.ui.select(available, {
    prompt = "dapper",
    format_item = function(action)
      local key = keys[action]
      return key and (action[1] .. string.rep(" ", width - vim.fn.strdisplaywidth(action[1]) + 3) .. key) or action[1]
    end,
  }, function(action)
    if action then
      action[2](nil)
    end
  end)
end

--- An nvim-dap adapter for gdb (14 and later speak DAP), whose program reads and writes the
--- "Program I/O" terminal: dap.adapters.gdb = require("dapper").gdb()
function M.gdb(args)
  return function(callback, cfg)
    local version = tonumber(vim.fn.system({ "gdb", "--version" }):match("GNU gdb [^%d]*(%d+)") or "")
    if version and version < 14 then
      require("dapper.util").notify(
        ("gdb %d speaks no DAP: gdb 14 or later is needed (:checkhealth dapper)"):format(version),
        vim.log.levels.ERROR
      )
    end
    local command = vim.list_extend({ "--interpreter=dap" }, args or { "--eval-command", "set print pretty on" })
    if cfg.request == "launch" then
      vim.list_extend(command, { "--eval-command", "set inferior-tty " .. require("dapper.io").tty() })
    end
    callback({ type = "executable", command = "gdb", args = command })
  end
end

return M
