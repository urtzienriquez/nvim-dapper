--- Completion of expressions, where one is typed (Watches' i a e, Memory's f, :Dapper watch,
--- memory, hover, pin, break-change, conditions and log points; and in your own prompts:
--- completion = "customlist,v:lua.require'dapper'.complete"). It completes the last name typed:
--- - after `.` or `->`, the members of what is before it (while stopped);
--- - else the selected frame's variables (while stopped), the names in the current file (also
---   before the program runs: conditions are often set then), and the watched expressions.
--- :Dapper break completes the program's functions.

local M = {}

local api = vim.api

-- what util.cached's variables answers held (unused now; kept for its callers)
function M.note() end

local frame_cache = {} -- frame id -> its variables' names (this stop)

function M.forget()
  frame_cache = {}
end

-- waits (briefly) for a request: completion functions cannot yield
local function request(session, command, args)
  local result, done
  session:request(command, args, function(err, r)
    result, done = not err and r or nil, true
  end)
  vim.wait(500, function()
    return done
  end, 5)
  return result
end

local function stopped_session()
  local session = package.loaded["dap"] and require("dap").session()
  return session and session.stopped_thread_id and session.current_frame and session or nil
end

-- the selected frame's variables (not its registers)
local function frame_names(session)
  local frame = session.current_frame
  if frame_cache[frame.id] then
    return frame_cache[frame.id]
  end
  local names = {}
  local scopes = request(session, "scopes", { frameId = frame.id })
  for _, scope in ipairs(scopes and scopes.scopes or {}) do
    if not scope.expensive and not scope.name:lower():find("register") then
      local result = request(session, "variables", { variablesReference = scope.variablesReference })
      for _, var in ipairs(result and result.variables or {}) do
        table.insert(names, var.name)
      end
    end
  end
  frame_cache[frame.id] = names
  return names
end

-- the members of `expr` (a struct, an array: its children)
local function members(session, expr)
  local result = request(session, "evaluate", {
    expression = expr,
    context = "watch",
    frameId = session.current_frame.id,
  })
  local ref = result and result.variablesReference or 0
  if ref == 0 then
    return {}
  end
  local children = request(session, "variables", { variablesReference = ref })
  local names = {}
  for _, var in ipairs(children and children.variables or {}) do
    if var.name:match("^[%a_][%w_]*$") then
      table.insert(names, var.name)
    end
  end
  return names
end

local KEYWORDS = {}
for word in
  ([[auto break case char const continue default do double else enum extern float for goto
  if inline int long register restrict return short signed sizeof static struct switch typedef
  union unsigned void volatile while bool true false NULL nullptr class public private protected
  template typename namespace using new delete this virtual override const_cast static_cast
  include define ifdef ifndef endif]]):gmatch("%S+")
do
  KEYWORDS[word] = true
end

-- the names in the current buffer (a file of code), but its keywords
local function file_names()
  local buf = api.nvim_get_current_buf()
  if vim.bo[buf].buftype ~= "" then -- (a pane, a prompt's buffer: the code window's)
    local win = require("dapper.util").code_window()
    if not win then
      return {}
    end
    buf = api.nvim_win_get_buf(win)
  end
  local names, seen = {}, {}
  for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, 5000, false)) do
    for word in line:gmatch("[%a_][%w_]*") do
      if not seen[word] and not KEYWORDS[word] and #word > 1 then
        seen[word] = true
        table.insert(names, word)
      end
    end
  end
  return names
end

-- `lead` with its last name completed from `names` (the text before it kept), in order
local function complete_with(before, word, names)
  local out, done = {}, {}
  for _, name in ipairs(names) do
    if not done[name] and vim.startswith(name, word) and name ~= word then
      done[name] = true
      table.insert(out, before .. name)
    end
  end
  return out
end

--- for completion = "customlist,...": the last name of the expression being typed
function M.expressions(lead)
  lead = lead or ""
  local session = stopped_session()
  -- after . or ->: the members of the expression before it
  local base, sep, word = lead:match("^(.-)(%.)([%w_]*)$")
  if not base then
    base, sep, word = lead:match("^(.-)(%->)([%w_]*)$")
  end
  if base and session then
    local expr = base:match("([%w_%.%[%]%(%)%*&>-]+)$") -- (the expression just before it)
    if expr and expr ~= "" then
      local target = sep == "->" and ("*(" .. expr .. ")") or expr
      local out = complete_with(base .. sep, word, members(session, target))
      table.sort(out)
      return out
    end
  end
  local before, last = lead:match("^(.-)([%a_][%w_]*)$")
  if not before then
    before, last = lead, ""
  end
  local names = {}
  if session then
    vim.list_extend(names, frame_names(session))
  end
  for _, expr in ipairs(require("dapper.views.watches").expressions) do
    if expr:match("^[%a_][%w_]*$") then
      table.insert(names, expr)
    end
  end
  local first = complete_with(before, last, names) -- (the frame's first, then the file's)
  table.sort(first)
  local rest = complete_with(before, last, file_names())
  table.sort(rest)
  local out, done = {}, {}
  for _, list in ipairs({ first, rest }) do
    for _, c in ipairs(list) do
      if not done[c] then
        done[c] = true
        table.insert(out, c)
      end
    end
  end
  return out
end

--- for :Dapper break: the program's functions (gdb's info functions) starting with `lead`;
--- without a session, the names in the current file
function M.functions(lead)
  lead = lead or ""
  local session = package.loaded["dap"] and require("dap").session()
  local names = {}
  if session then
    local result = request(session, "evaluate", { expression = "info functions -q -n ^" .. lead, context = "repl" })
    for line in ((result and result.result) or ""):gmatch("[^\n]+") do
      local name = line:match("([%a_][%w_:]*)%s*%(")
      if name then
        table.insert(names, name)
      end
    end
  else
    names = file_names()
  end
  local out = complete_with("", lead, names)
  table.sort(out)
  return out
end

return M
