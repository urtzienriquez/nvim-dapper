--- Memory: the bytes at an address, 16 a row, in hex and as text. The bytes of the current
--- function's variables are coloured, and those that changed since the last stop highlighted. The
--- cursor's row says what is under it (the variable, down to its member; else what the bytes read
--- as); the window bar is the columns' header, the cursor's column lit. f goes to an address, a
--- variable or any expression; r writes bytes; [[ ]] page; . goes back to what is followed.

local config = require("dapper.config")
local util = require("dapper.util")

local M = { label = "Memory" }

M.anchor = nil -- what g went to (an expression: followed at each stop); nil: the selected
-- frame's variables (followed at each stop, and when another frame is selected), as raddebugger
M.address = nil -- the address shown first (its row)
M.cursor = nil -- the address of the byte the cursor is on
M.follow = true -- the rows follow it (looked up again at each stop); paging stops it
local followed_frame -- the frame they were last looked up for
local quiet = false -- what was gone to came from under the cursor: if it is no address, no warning
local version = 0 -- a new one at each go to (a draw that started before one leaves its target alone)
local bytes = {} -- address -> byte, as last read
local before = {} -- the bytes at the stop before
local layout = {} -- buffer columns: hex = { [i] = column }, text = column (0-based)
local VAR_HL = 4 -- DapperMemory1..4, in turn

local function hex(address)
  return ("0x%x"):format(address)
end

--- the address `expr` stands for: an address, else where the expression is (&expr: `a` is a's
--- bytes, `*p` what p points to), else its value as an address ($sp, p + 4)
function M.resolve(session, expr)
  expr = vim.trim(expr or "")
  if expr:match("^0[xX]%x+$") then
    return tonumber(expr:sub(3), 16)
  elseif expr:match("^%d+$") then
    return tonumber(expr)
  end
  for _, form in ipairs({ "(void *)&(%s)", "(void *)(%s)" }) do
    local result = util.request(session, "evaluate", {
      expression = form:format(expr),
      context = "watch",
      frameId = session.current_frame and session.current_frame.id,
    })
    local digits = result and result.result:match("^0x(%x+)")
    if digits then
      return tonumber(digits, 16)
    end
  end
  return nil, "Not an address: " .. expr
end

local annotations = { frame = nil, list = {} }

-- the variables of the selected frame, where they are: { name, from, to, hl }
local function variables(session)
  local frame = session.current_frame
  if not frame then
    return {}
  end
  if annotations.frame == frame.id and annotations.stop == session.stopped_thread_id then
    return annotations.list
  end
  -- the frame's variables (not its registers), then where each is and its size: all asked at once
  local vars = {}
  local scopes = util.cached(session, "scopes", { frameId = frame.id })
  for _, scope in ipairs(scopes and scopes.scopes or {}) do
    if not scope.expensive and not scope.name:lower():find("register") then
      local result = util.cached(session, "variables", { variablesReference = scope.variablesReference })
      for _, var in ipairs(result and result.variables or {}) do
        if #vars < 32 then
          table.insert(vars, var)
        end
      end
    end
  end
  local asks = {}
  for _, var in ipairs(vars) do
    local name = var.evaluateName or var.name
    table.insert(
      asks,
      { "evaluate", { expression = "(void *)&(" .. name .. ")", context = "watch", frameId = frame.id } }
    )
    table.insert(asks, { "evaluate", { expression = "sizeof(" .. name .. ")", context = "watch", frameId = frame.id } })
  end
  local answers = util.requests(session, asks)
  local list = {}
  for i, var in ipairs(vars) do
    local address, size = answers[2 * i - 1], answers[2 * i]
    local from = address and address.result:match("^0x(%x+)") and tonumber(address.result:match("^0x(%x+)"), 16)
    size = size and tonumber(size.result)
    if from and size and size > 0 then
      table.insert(
        list,
        {
          name = var.name,
          expr = var.evaluateName or var.name,
          ref = var.variablesReference,
          value = var.value,
          type = var.type,
          from = from,
          to = from + size - 1,
          hl = "DapperMemory" .. (#list % VAR_HL + 1),
        }
      )
    end
  end
  annotations.frame, annotations.stop, annotations.list = frame.id, session.stopped_thread_id, list
  return list
end

-- the frames of the stopped thread, where their part of the stack starts: { name, sp }
local function frames(session)
  if annotations.frames then
    return annotations.frames
  end
  local thread = session.threads and session.threads[session.stopped_thread_id]
  local stack = vim.list_slice(thread and thread.frames or {}, 1, 16)
  local answers = util.requests(
    session,
    vim.tbl_map(function(frame)
      return { "evaluate", { expression = "(void *)$sp", context = "watch", frameId = frame.id } }
    end, stack)
  )
  local list = {}
  for i, frame in ipairs(stack) do
    local digits = answers[i] and answers[i].result:match("^0x(%x+)")
    if digits then
      table.insert(list, { name = frame.name, sp = tonumber(digits, 16) })
    end
  end
  annotations.frames = list
  return list
end

-- where to go when following the frame: its variables (the lowest), else its stack pointer
local function frame_address(session)
  local lowest
  for _, v in ipairs(variables(session)) do
    lowest = math.min(lowest or v.from, v.from)
  end
  if lowest then
    return lowest
  end
  return M.resolve(session, "$sp")
end

-- The members of a struct, where each is ({ name, expr, from, to, value, type, ref }), by the
-- struct's expression: asked once per stop.
local members = {}

local function kid(node, var, from, size)
  local expr = var.evaluateName or require("dapper.tree").child_expression(node.expr, node.type, var.name)
  return {
    name = var.name,
    expr = expr,
    from = from,
    to = from + size - 1,
    value = var.value,
    type = var.type,
    ref = var.variablesReference,
  }
end

-- the member of `node` (a variable, or a member of one) whose bytes hold `address`, or nil
local function member_at(session, node, address)
  local frame = session.current_frame and session.current_frame.id
  local result = util.cached(session, "variables", { variablesReference = node.ref })
  local vars = result and result.variables or {}
  if #vars == 0 then
    return nil
  end
  if vars[1].name:match("^%[?%d+%]?$") then -- an array: its element, by arithmetic
    local first = kid(node, vars[1], node.from, 1)
    local size = util.cached(session, "evaluate", { expression = "sizeof(" .. first.expr .. ")", context = "watch", frameId = frame })
    size = size and tonumber(size.result)
    if not size or size <= 0 then
      return nil
    end
    local index = math.floor((address - node.from) / size)
    local var = vars[index + 1]
    if var and tonumber(var.name:match("%d+")) == index then
      return kid(node, var, node.from + index * size, size)
    end
    return nil
  end
  local list = members[node.expr]
  if not list then -- a struct: where each member is, all asked at once
    vars = vim.list_slice(vars, 1, 64)
    local asks = {}
    for _, var in ipairs(vars) do
      local expr = kid(node, var, 0, 1).expr
      table.insert(asks, { "evaluate", { expression = "(void *)&(" .. expr .. ")", context = "watch", frameId = frame } })
      table.insert(asks, { "evaluate", { expression = "sizeof(" .. expr .. ")", context = "watch", frameId = frame } })
    end
    local answers = util.requests(session, asks)
    list = {}
    for i, var in ipairs(vars) do
      local from = answers[2 * i - 1] and answers[2 * i - 1].result:match("^0x(%x+)")
      local size = answers[2 * i] and tonumber(answers[2 * i].result)
      if from and size and size > 0 then
        table.insert(list, kid(node, var, tonumber(from, 16), size))
      end
    end
    members[node.expr] = list
  end
  for _, member in ipairs(list) do
    if address >= member.from and address <= member.to then
      return member
    end
  end
end

--- the innermost member of variable `var` holding `address` (var itself, if none)
function M.innermost(session, var, address)
  local node = var
  for _ = 1, 8 do
    if (node.ref or 0) == 0 then
      break
    end
    local inner = member_at(session, node, address)
    if not inner then
      break
    end
    node = inner
  end
  return node
end

function M.stopped()
  before, bytes = bytes, {}
  annotations = { list = {} }
  members = {}
  if M.follow then
    M.address = nil -- (looked up again: in another frame, a variable is elsewhere)
  end
end

function M.render(canvas, session)
  if not (session and session.stopped_thread_id) then
    return canvas:note(session and "Running…" or "Not debugging")
  end
  local columns, rows = config.values.memory.columns, config.values.memory.rows
  local frame = session.current_frame and session.current_frame.id
  if M.follow and not M.anchor and frame ~= followed_frame then
    M.address = nil -- (another frame selected: its variables)
  end
  if not M.address then
    local mine = version
    local target, err
    if M.anchor then
      target, err = M.resolve(session, M.anchor)
      if not target then
        if not quiet then
          util.notify(err .. ": the current frame's variables instead", vim.log.levels.WARN)
        end
        M.anchor = nil
      end
    end
    target = target or frame_address(session)
    if mine ~= version then
      return -- (gone elsewhere meanwhile: the draw for that replaces this one)
    end
    if not target then
      return canvas:note("Nothing to show: go to an address, a variable or an expression with f")
    end
    -- (the rows around it, the cursor on it, centered)
    M.address = math.max(0, target - target % columns - math.floor(rows / 2) * columns)
    M.cursor, followed_frame = target, frame
    canvas.center = true
  end
  local first = M.address - M.address % columns
  local result, err = util.request(session, "readMemory", { memoryReference = hex(first), count = columns * rows })
  if not result then
    return canvas:add({ { err, "DapperError" } })
  end
  local data = vim.base64.decode(result.data or "")
  local start = result.address and tonumber(result.address:match("0x(%x+)") or "", 16) or first
  local function byte_at(address)
    local i = address - start + 1
    return (i >= 1 and i <= #data) and data:byte(i) or nil
  end
  local vars = variables(session)
  local frame_starts = {} -- row base -> names of the frames whose part of the stack starts in it
  for _, f in ipairs(frames(session)) do
    local base = f.sp - f.sp % columns
    frame_starts[base] = frame_starts[base] or {}
    table.insert(frame_starts[base], f.name)
  end
  local function var_of(address)
    for _, v in ipairs(vars) do
      if address >= v.from and address <= v.to then
        return v
      end
    end
  end
  layout = { hex = {}, vars = vars, columns = columns }
  for row = 0, rows - 1 do
    local base = first + row * columns
    local chunks = { { ("0x%016x"):format(base), "DapperLine" }, { "  " } }
    local column = 20 -- (the line's length so far: "0x" and 16 digits, 2 spaces)
    local text = {}
    for i = 0, columns - 1 do
      local address = base + i
      local byte = byte_at(address)
      if i > 0 and i % 8 == 0 then
        table.insert(chunks, { " " }) -- (groups of 8)
        column = column + 1
      end
      layout.hex[i] = column
      local var = var_of(address)
      local hl
      if byte == nil then
        hl = "DapperMuted"
      elseif before[address] ~= nil and before[address] ~= byte then
        hl = "DapperChanged"
      elseif var then
        hl = var.hl
      end
      if byte then
        bytes[address] = byte
      end
      table.insert(chunks, { byte and ("%02x"):format(byte) or "??", hl })
      column = column + 2
      if i < columns - 1 then
        table.insert(chunks, { " " })
        column = column + 1
      end
      table.insert(text, { (byte and byte >= 32 and byte < 127) and string.char(byte) or ".", hl })
    end
    table.insert(chunks, { "  " })
    layout.text = column + 2
    vim.list_extend(chunks, text)
    local virt = {}
    if frame_starts[base] then -- (a frame's part of the stack starts here: its function, as raddebugger)
      table.insert(virt, { "  ⟨" .. table.concat(frame_starts[base], ", ") .. "⟩", "DapperTitle" })
    end
    canvas:add(chunks, { kind = "row", address = base }, #virt > 0 and { virt = virt } or nil)
    if M.cursor and M.cursor >= base and M.cursor < base + columns then
      canvas.cursor = { row + 1, layout.hex[M.cursor - base] }
    end
  end
end

--- the address of the byte under the cursor (in the hex or text columns), or nil
function M.byte_under_cursor()
  local item = require("dapper.canvas").item()
  if not (item and item.address) then
    return nil
  end
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local columns = config.values.memory.columns
  if layout.text and col >= layout.text then
    return item.address + math.min(col - layout.text, columns - 1)
  end
  for i = columns - 1, 0, -1 do
    if layout.hex[i] and col >= layout.hex[i] then
      return item.address + i
    end
  end
  return item.address
end

--- the bytes from `address` read as numbers (little-endian), for the window bar
local function readings(address)
  local b = {}
  for i = 0, 7 do
    b[i] = bytes[address + i]
  end
  if not b[0] then
    return ""
  end
  local function unsigned(n)
    local v = 0
    for i = n - 1, 0, -1 do
      if not b[i] then
        return nil
      end
      v = v * 256 + b[i]
    end
    return v
  end
  local function signed(n)
    local v = unsigned(n)
    return v and (v >= 2 ^ (8 * n - 1) and v - 2 ^ (8 * n) or v)
  end
  -- (a size's signed reading only where it differs from the unsigned one)
  local parts = {}
  for _, n in ipairs({ 1, 2, 4, 8 }) do
    local u, i = unsigned(n), signed(n)
    if u and (n < 8 or u < 2 ^ 53) then
      local reading = ("u%d %d"):format(8 * n, u)
      if i ~= u then
        reading = reading .. (" (%d)"):format(i)
      end
      table.insert(parts, reading)
    end
  end
  -- (a NaN is told from its bits: LuaJIT can take some NaNs for other values)
  local function nan(n)
    local band = bit.band
    if n == 4 then -- (exponent: 8 bits, the mantissa: 23)
      return band(b[3], 0x7f) == 0x7f and band(b[2], 0x80) ~= 0 and (band(b[2], 0x7f) + b[1] + b[0]) ~= 0
    end
    -- (exponent: 11 bits, the mantissa: 52)
    return band(b[7], 0x7f) == 0x7f
      and band(b[6], 0xf0) == 0xf0
      and (band(b[6], 0x0f) + b[5] + b[4] + b[3] + b[2] + b[1] + b[0]) ~= 0
  end
  local ok, ffi = pcall(require, "ffi")
  if ok and unsigned(4) then
    local raw = ffi.new("uint8_t[8]")
    for i = 0, 7 do
      raw[i] = b[i] or 0
    end
    table.insert(parts, nan(4) and "f32 nan" or ("f32 %.7g"):format(ffi.cast("float *", raw)[0]))
    if unsigned(8) then
      table.insert(parts, nan(8) and "f64 nan" or ("f64 %.15g"):format(ffi.cast("double *", raw)[0]))
    end
  end
  return table.concat(parts, "  ")
end
M.readings = readings

local cursor_ns = vim.api.nvim_create_namespace("dapper.memory.cursor")

--- the columns' header (the window bar), with column `lit` (0-based; nil: none) lit
local function header(lit)
  local parts, at = {}, 0
  local function put(column, text, i)
    table.insert(parts, string.rep(" ", column - at))
    table.insert(parts, i == lit and ("%#DapperTitle#" .. text .. "%#DapperMuted#") or text)
    at = column + #text
  end
  table.insert(parts, "%#DapperMuted#")
  for i = 0, layout.columns - 1 do
    put(layout.hex[i], ("%02x"):format(i), i)
  end
  for i = 0, layout.columns - 1 do
    put(layout.text + i, ("%x"):format(i % 16), i)
  end
  return table.concat(parts)
end

-- What is under the cursor of window `win`: its column lit in the header (the window bar), its
-- byte's twin (hex / text) highlighted, and at the end of its row the variable it is in (else
-- what the bytes read as).
local function update_cursor(win, force)
  vim.api.nvim_win_call(win, function()
    local buf = vim.api.nvim_get_current_buf()
    local address = M.byte_under_cursor()
    M.cursor = address or M.cursor
    if address == vim.w.dapper_bar_address and not force then
      return -- (the same byte: as it is)
    end
    vim.w.dapper_bar_address = address
    vim.api.nvim_buf_clear_namespace(buf, cursor_ns, 0, -1)
    if not (address and layout.hex[0]) then
      vim.wo.winbar = ""
      return
    end
    local item = require("dapper.canvas").item()
    local i = address - item.address
    vim.wo.winbar = header(i)
    local row = vim.api.nvim_win_get_cursor(0)[1] - 1
    for _, col in ipairs({ layout.hex[i], layout.text + i }) do
      local width = col == layout.text + i and 1 or 2
      pcall(vim.api.nvim_buf_set_extmark, buf, cursor_ns, row, col, {
        end_col = col + width,
        hl_group = "DapperMemoryCursor",
        priority = 300,
      })
    end
    local var
    for _, v in ipairs(layout.vars or {}) do
      if address >= v.from and address <= v.to then
        var = v
        break
      end
    end
    local function said(node) -- (the variable, or its member, in the variable's colour)
      local value = (node.value or ""):gsub("\n", " ")
      if value == "" and (node.ref or 0) > 0 then
        value = "{…}"
      end
      local virt = { { "  " .. node.expr .. " = " .. value, var.hl } }
      if node.type and node.type ~= "" then
        table.insert(virt, { "  " .. node.type, "DapperType" })
      end
      return virt
    end
    local virt = var and said(var) or {}
    -- (in no variable: what the bytes read as; a variable's value says it already)
    local ok, text = true, ""
    if #virt == 0 then
      ok, text = pcall(readings, address) -- (it must never fail)
    end
    if ok and text ~= "" then
      table.insert(virt, { "   " .. text, "DapperMuted" })
    end
    local mark = select(2, pcall(vim.api.nvim_buf_set_extmark, buf, cursor_ns, row, 0, { virt_text = virt }))
    local session = require("dap").session()
    if var and (var.ref or 0) > 0 and session and type(mark) == "number" then
      util.run(function() -- (a struct or an array: the member under the cursor, as raddebugger)
        local node = M.innermost(session, var, address)
        if node ~= var and vim.api.nvim_win_is_valid(win) and vim.w[win].dapper_bar_address == address then
          pcall(vim.api.nvim_buf_set_extmark, buf, cursor_ns, row, 0, { id = mark, virt_text = said(node) })
        end
      end)
    end
  end)
end

function M.attach(buf)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      update_cursor(vim.api.nvim_get_current_win())
    end,
  })
end

--- drawn: the bytes under the cursors may have changed
function M.written(buf)
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    update_cursor(win, true)
  end
end

local function refresh()
  require("dapper.views").refresh("memory")
end

--- goes to `expr` (an address, a variable, an expression); nothing: the selected frame's
--- variables (followed). implicit: `expr` is what was under the cursor (not an address: the
--- frame's variables, without a warning)
function M.go(expr, implicit)
  quiet = implicit or false
  expr = expr and vim.trim(expr) or ""
  M.anchor, M.address, M.cursor, M.follow = expr ~= "" and expr or nil, nil, nil, true
  version = version + 1
  refresh()
end

M.keys = {
  {
    "f",
    "find: go to an address, a variable or an expression (nothing: the frame's variables)",
    function()
      util.run(function()
        local expr = util.input({
          prompt = "Memory at (empty: the frame's variables): ",
          default = M.anchor or "",
          completion = "customlist,v:lua.require'dapper'.complete",
        })
        if expr then
          M.go(expr)
        end
      end)
    end,
  },
  {
    "r",
    "write bytes (hex) at the cursor",
    function()
      local address = M.byte_under_cursor()
      local session = require("dap").session()
      if not (address and session) then
        return
      end
      util.run(function()
        local current = bytes[address] and ("%02x"):format(bytes[address]) or ""
        local text = util.input({ prompt = ("Bytes at %s (hex): "):format(hex(address)), default = current })
        if not text or vim.trim(text) == "" then
          return
        end
        local chars = {}
        for token in text:gmatch("%S+") do
          local value = tonumber((token:gsub("^0[xX]", "")), 16)
          if not value or value > 255 then
            return util.notify("Not a byte: " .. token, vim.log.levels.WARN)
          end
          table.insert(chars, string.char(value))
        end
        local _, err = util.request(session, "writeMemory", {
          memoryReference = hex(address),
          data = vim.base64.encode(table.concat(chars)),
        })
        if err then
          return util.notify("Could not write: " .. err, vim.log.levels.WARN)
        end
        M.cursor = address
        util.forget()
        require("dapper.views").refresh() -- (the variables changed too)
      end)
    end,
  },
  {
    "]]",
    "next page",
    function()
      if M.address then
        M.address = M.address
          - M.address % config.values.memory.columns
          + config.values.memory.columns * config.values.memory.rows
        M.cursor, M.follow = M.address, false
        refresh()
      end
    end,
  },
  {
    "[[",
    "previous page",
    function()
      if M.address then
        M.address = math.max(
          0,
          M.address
            - M.address % config.values.memory.columns
            - config.values.memory.columns * config.values.memory.rows
        )
        M.cursor, M.follow = M.address, false
        refresh()
      end
    end,
  },
  {
    ".",
    "back to what is followed (what was gone to, or the frame's variables)",
    function()
      M.address, M.cursor, M.follow = nil, nil, true
      refresh()
    end,
  },
}

return M
