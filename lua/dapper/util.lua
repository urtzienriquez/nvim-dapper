local M = {}

local api = vim.api

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "dapper" })
end

local function is_code(win)
  return api.nvim_win_get_config(win).relative == ""
    and vim.bo[api.nvim_win_get_buf(win)].buftype == ""
    and not vim.wo[win].winfixbuf
end

-- the tab pages to look for code in: the current one, unless it is one of dapper's (Memory,
-- Disassembly: then the others, in order)
local function code_tabs()
  if not vim.t.dapper_view then
    return { api.nvim_get_current_tabpage() }
  end
  return vim.tbl_filter(function(tab)
    return not vim.t[tab].dapper_view
  end, api.nvim_list_tabpages())
end

--- a window that shows a file (not a pane, a terminal, ...): in the current tab page (the
--- previous window first), or from one of dapper's tab pages, in the others
function M.code_window()
  if not vim.t.dapper_view then
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    if prev ~= 0 and is_code(prev) then
      return prev
    end
  end
  for _, tab in ipairs(code_tabs()) do
    local win = vim.tbl_filter(is_code, api.nvim_tabpage_list_wins(tab))[1]
    if win then
      return win
    end
  end
end

--- the buffer of a DAP source (a path, or a source the adapter sends by reference), or nil
function M.source_buf(source)
  if not source then
    return nil
  end
  if source.path and vim.uv.fs_stat(source.path) then
    local buf = vim.fn.bufadd(source.path)
    vim.fn.bufload(buf)
    return buf
  end
  for _, buf in ipairs(api.nvim_list_bufs()) do -- nvim-dap's dap-src:// buffers
    if source.path and api.nvim_buf_get_name(buf):find(source.path, 1, true) then
      return buf
    end
  end
end

--- Gives window `win` (made from a pane, or one of dapper's tab pages: a split copies its
--- options) a code window's options: those of one in any tab page, else Neovim's defaults. So the
--- signs show, without the pane's tabs, ...
function M.plain_window(win)
  local model
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    model = model
      or vim.tbl_filter(function(w)
        return w ~= win and is_code(w) and not vim.t[tab].dapper_view
      end, api.nvim_tabpage_list_wins(tab))[1]
  end
  for _, option in ipairs({
    "winbar",
    "signcolumn",
    "number",
    "relativenumber",
    "foldcolumn",
    "cursorline",
    "wrap",
    "list",
    "spell",
    "winfixwidth",
    "winfixheight",
    "winfixbuf",
  }) do
    pcall(function()
      vim.wo[win][option] = model and vim.wo[model][option] or api.nvim_get_option_info2(option, {}).default
    end)
  end
  vim.wo[win].winfixbuf = false
end

--- Shows line (and column) of buf in a window: the one showing it, else the code window (made
--- if there is none). focus: also move the cursor there.
function M.show_location(buf, line, column, focus)
  local win
  for _, tab in ipairs(code_tabs()) do
    win = win
      or vim.tbl_filter(function(w)
        return api.nvim_win_get_buf(w) == buf
      end, api.nvim_tabpage_list_wins(tab))[1]
  end
  if not win then
    win = M.code_window()
    if win then
      api.nvim_win_set_buf(win, buf)
    else -- no window for code: a new one (never in a tab page of dapper's)
      local cur = api.nvim_get_current_win()
      if vim.t.dapper_view then
        vim.cmd("tabnew")
        win = api.nvim_get_current_win()
      else
        vim.cmd("topleft split")
        win = api.nvim_get_current_win()
      end
      M.plain_window(win)
      api.nvim_win_set_buf(win, buf)
      api.nvim_set_current_win(cur)
    end
  end
  pcall(api.nvim_win_set_cursor, win, { line, math.max((column or 1) - 1, 0) })
  api.nvim_win_call(win, function()
    vim.cmd("normal! zv")
  end)
  if focus then
    api.nvim_set_current_win(win) -- (in another tab page: goes there)
  end
  return win
end

--- the expression to act on: the visual selection, else the one under the cursor
function M.expression()
  local mode = api.nvim_get_mode().mode
  if mode:match("^[vV\22]") then
    local lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return vim.trim(table.concat(lines, "\n"))
  end
  return vim.fn.expand("<cexpr>")
end

--- Line `lnum` (1-based) of buffer `buf`, without its indent, as chunks highlighted as in the code
--- (treesitter, if the buffer has a parser; else plain).
function M.code_chunks(buf, lnum)
  local line = api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
  local indent = #(line:match("^%s*"))
  local text = line:sub(indent + 1)
  local ok, parser = pcall(vim.treesitter.get_parser, buf)
  if not (ok and parser) or text == "" then
    return { { text } }
  end
  local hl_at = {} -- byte column of the line -> highlight group
  parser:parse({ lnum - 1, lnum })
  parser:for_each_tree(function(tree, ltree)
    local query = vim.treesitter.query.get(ltree:lang(), "highlights")
    if not query then
      return
    end
    for id, node in query:iter_captures(tree:root(), buf, lnum - 1, lnum) do
      local name = query.captures[id]
      if name and not name:find("^_") and name ~= "spell" and name ~= "nospell" then
        local srow, scol, erow, ecol = node:range()
        local from = srow < lnum - 1 and 0 or scol
        local to = erow > lnum - 1 and #line or ecol
        for col = from, to - 1 do
          hl_at[col] = "@" .. name .. "." .. ltree:lang() -- (later captures win, as in the code)
        end
      end
    end
  end)
  local chunks, start = {}, indent
  for col = indent + 1, #line do
    if col == #line or hl_at[col] ~= hl_at[start] then
      table.insert(chunks, { line:sub(start + 1, col), hl_at[start] })
      start = col
    end
  end
  return chunks
end

--- runs fn in a coroutine (nvim-dap's requests then read as plain calls), reporting its errors,
--- also those after it waited for an answer
function M.run(fn, ...)
  local args = { ... }
  coroutine.wrap(function()
    local ok, err = xpcall(fn, debug.traceback, unpack(args))
    if not ok then
      M.notify(err, vim.log.levels.ERROR)
    end
  end)()
end

--- Puts `:text` on the command line, to be edited (<C-f> opens the real command-line window)
--- and run. `text` goes in as it is: no key notation.
function M.cmdline(text)
  vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-n>") .. ":" .. text, "n", false)
end

--- A window to edit `text` in, much like the command-line window (which input() cannot open):
--- <CR> (Normal or Insert mode) gives `cb` the line under the cursor; closing it gives nil.
local function edit_window(opts, text, cb)
  local lines = {}
  for i = 1, vim.fn.histnr("@") do
    local h = vim.fn.histget("@", i)
    if h ~= "" then
      table.insert(lines, h)
    end
  end
  table.insert(lines, text)

  vim.cmd(("botright %dnew"):format(math.max(vim.o.cmdwinheight, 1)))
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.wo[win].winbar = (opts.prompt or ""):gsub("%%", "%%%%")
  vim.wo[win].winfixheight = true
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })

  local done = false
  local function finish(result)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    cb(result)
  end
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    vim.fn.histadd("@", line)
    vim.cmd("stopinsert")
    finish(line)
  end, { buffer = buf, desc = "dapper: use this line" })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    vim.cmd("stopinsert")
    finish(nil)
  end, { buffer = buf, desc = "dapper: cancel" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish(nil)
      end)
    end,
  })
end

--- vim.ui.input, where <C-f> (at input()'s prompt, which cannot open the command-line window)
--- opens an edit_window
function M.prompt(opts, on_confirm)
  local escaped -- what was typed, when <C-f> left the prompt for an edit_window
  local saved = vim.fn.maparg("<C-f>", "c", false, true)
  vim.keymap.set("c", "<C-f>", function()
    if vim.fn.getcmdtype() == "@" then
      escaped = vim.fn.getcmdline()
      return "<C-c>"
    end
    return "<C-f>"
  end, { expr = true, desc = "dapper: edit the prompt in a window" })
  local function restore()
    pcall(vim.keymap.del, "c", "<C-f>")
    if not vim.tbl_isempty(saved) then
      vim.fn.mapset("c", false, saved)
    end
  end
  local ok, err = pcall(vim.ui.input, opts, function(value)
    restore()
    if escaped then
      vim.schedule(function()
        edit_window(opts, escaped, on_confirm)
      end)
    else
      on_confirm(value)
    end
  end)
  if not ok then
    restore()
    error(err)
  end
end

--- M.prompt, waited for (in a coroutine)
function M.input(opts)
  local co = assert(coroutine.running(), "input outside a coroutine")
  local result, done, waiting
  M.prompt(opts, function(value)
    result, done = value, true
    if waiting then
      coroutine.resume(co)
    end
  end)
  if not done then
    waiting = true
    coroutine.yield()
  end
  return result
end

-- the debugger's messages that have a fix, and the fix
local FIXES = {
  { "No symbol table is loaded", "no debug information: build the program with -g" },
  { 'No symbol "[^"]*" in current context', "not in the selected frame: select another in the Call stack" },
  { "Cannot access memory at address", "memory the program cannot read" },
  { "The program is not being run", "start the program first" },
  { "No frame selected", "the program has to be stopped" },
}

--- the debugger's message `msg`, with its fix if there is one known
function M.explain(msg)
  msg = tostring(msg or "")
  for _, fix in ipairs(FIXES) do
    if msg:find(fix[1]) then
      return msg:gsub("%.?%s*$", "") .. " (" .. fix[2] .. ")"
    end
  end
  return msg
end

--- a request to the session, waited for (in a coroutine): result, or nil and the error
M.hex = false -- values in hex (:Dapper hex): the debugger formats them (DAP's value format)

-- `args` of request `command`, with the value format (hex) where the debugger takes one
local function formatted(session, command, args)
  if
    M.hex
    and (command == "variables" or (command == "evaluate" and args.context ~= "repl")) -- (not commands)
    and session.capabilities
    and session.capabilities.supportsValueFormattingOptions
  then
    return vim.tbl_extend("force", args, { format = { hex = true } })
  end
  return args
end

function M.request(session, command, args)
  local err, result = session:request(command, formatted(session, command, args))
  if err then
    return nil, M.explain(err.message or tostring(err))
  end
  return result
end

--- evaluates `expression` in the selected frame (context: "watch", default; "repl" for the
--- debugger's own commands; "hover") (in a coroutine)
function M.evaluate(session, expression, context)
  return M.request(session, "evaluate", {
    expression = expression,
    context = context or "watch",
    frameId = session.current_frame and session.current_frame.id,
  })
end

--- Several requests ({ command, args } each), sent at once and waited for together (in a
--- coroutine): their results, in order (nil for one that failed).
function M.requests(session, list)
  local co = assert(coroutine.running(), "requests outside a coroutine")
  local results, pending, waiting = {}, #list, false
  if pending == 0 then
    return results
  end
  for i, item in ipairs(list) do
    session:request(item[1], formatted(session, item[1], item[2]), function(err, result)
      results[i] = not err and result or nil
      pending = pending - 1
      if pending == 0 and waiting then
        coroutine.resume(co)
      end
    end)
  end
  if pending > 0 then
    waiting = true
    coroutine.yield()
  end
  return results
end

-- What does not change while the program is stopped (the scopes of a frame, the variables of a
-- reference), asked for once per stop and shared by the views. Forgotten when the program runs
-- again or a value is set.
local cache = {}

function M.forget()
  cache = {}
  if package.loaded["dapper.complete"] then
    require("dapper.complete").forget()
  end
end

--- M.request, remembered until M.forget()
function M.cached(session, command, args)
  local key = session.id .. command .. vim.json.encode(args)
  local hit = cache[key]
  if hit then
    if hit.waiting then -- (asked for by another view, not answered yet: wait for that answer)
      local co = assert(coroutine.running(), "cached outside a coroutine")
      table.insert(hit.waiting, co)
      return coroutine.yield()
    end
    return hit.result, hit.err
  end
  hit = { waiting = {} }
  cache[key] = hit
  local result, err = M.request(session, command, args)
  local waiting = hit.waiting
  hit.result, hit.err, hit.waiting = result, err, nil
  if err then
    cache[key] = nil -- (an error is asked again)
  end
  for _, co in ipairs(waiting) do
    coroutine.resume(co, result, err)
  end
  return result, err
end

--- The variables of `frame` (default: the selected one), not its registers (in a coroutine).
function M.frame_variables(session, frame)
  frame = frame or session.current_frame
  local vars = {}
  local scopes = frame and M.cached(session, "scopes", { frameId = frame.id })
  for _, scope in ipairs(scopes and scopes.scopes or {}) do
    if not scope.expensive and not scope.name:lower():find("register") then
      local result = M.cached(session, "variables", { variablesReference = scope.variablesReference })
      vim.list_extend(vars, result and result.variables or {})
    end
  end
  return vars
end

--- A value was set (or memory written) while stopped: everything that shows values, again.
function M.values_changed()
  M.forget()
  if package.loaded["dapper.views.memory"] then
    require("dapper.views.memory").forget()
  end
  require("dapper.views").refresh()
  if require("dapper.config").values.virtual_text then
    require("dapper.virtual_text").update()
  end
  if package.loaded["dapper.pins"] then
    require("dapper.pins").update()
  end
end

return M
