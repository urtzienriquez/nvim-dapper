--- Disassembly: the instructions of the current function (from its start), with its source
--- lines between them; the current instruction marked (→), and the instruction breakpoints (●).
--- x toggles one; <CR> on a source line goes to it; f goes to a function, address or expression;
--- . back to the current instruction. While the cursor is here, stepping goes one instruction.

local config = require("dapper.config")
local util = require("dapper.util")

local M = { label = "Disassembly" }

M.anchor = nil -- the address gone to with f (else: the current instruction's)
M.sync = nil -- { path, line }: the source line whose instructions are highlighted (else: the
-- current frame's, when following the current instruction)
M.breakpoints = {} ---@type table<string, { label: string, verified?: boolean }> by address

local function number(address)
  return tonumber((address or ""):match("0x(%x+)") or "", 16)
end

local function hex(n)
  return ("0x%x"):format(n)
end

-- where the function holding `address` starts (gdb: "main + 67 in section .text"), else it
local function function_start(session, address)
  local result = util.evaluate(session, "info symbol " .. hex(address), "repl")
  local offset = result and result.result:match("%+ (%d+) in section")
  return address - (tonumber(offset) or 0)
end

local sources = {} -- path -> lines
local function source_line(path, line)
  if not sources[path] then
    local ok, lines = pcall(vim.fn.readfile, path)
    sources[path] = ok and lines or {}
  end
  return sources[path][line] or ""
end

function M.render(canvas, session)
  if not (session and session.stopped_thread_id) then
    return canvas:note(session and "Running…" or "Not debugging")
  end
  local frame = session.current_frame
  local pc = frame and number(frame.instructionPointerReference)
  local target = M.anchor or pc
  if not target then
    return canvas:note("No instruction to show (the frame has no address)")
  end
  local start = function_start(session, target)
  -- (from the function's start: in a long one, more instructions, until the one shown is in)
  local count, result, err = config.values.disassembly.instructions, nil, nil
  local function disassemble(from)
    result, err = util.request(session, "disassemble", {
      memoryReference = hex(from),
      instructionCount = count,
      resolveSymbols = true,
    })
    local last = result and result.instructions and result.instructions[#result.instructions]
    return not last or number(last.address) >= target
  end
  local reached = disassemble(start)
  for _ = 1, 5 do
    if reached then
      break
    end
    count = count * 2
    reached = disassemble(start)
  end
  if not reached then -- (too long a function: from the instruction, not from its start)
    count = config.values.disassembly.instructions
    disassemble(target)
    canvas:note("A long function: shown from here, not from its start")
  end
  if not result then
    return canvas:add({ { err, "DapperError" } })
  end
  local last_source, cursor, first_synced
  local icons = config.values.icons
  local sync = M.sync
  if not sync and not M.anchor and frame and frame.source and frame.source.path then
    sync = { path = frame.source.path, line = frame.line }
  end
  local cur_path, cur_line -- the source line of the instructions being drawn
  for _, insn in ipairs(result.instructions or {}) do
    local address = number(insn.address)
    if insn.symbol then
      canvas:add({ { "<" .. insn.symbol .. ">:", "DapperTitle" } })
    end
    local path = insn.location and insn.location.path
    if insn.line and path and (path .. ":" .. insn.line) ~= last_source then
      last_source = path .. ":" .. insn.line
      local chunks = { { ("      %s:%d  "):format(vim.fs.basename(path), insn.line), "DapperFile" } }
      if vim.fn.bufloaded(path) == 1 then -- (highlighted as in the code)
        vim.list_extend(chunks, util.code_chunks(vim.fn.bufnr(path), insn.line))
      else
        table.insert(chunks, { vim.trim(source_line(path, insn.line)), "DapperMuted" })
      end
      canvas:add(chunks, { kind = "source", path = path, line = insn.line })
    end
    if insn.line and path then
      cur_path, cur_line = path, insn.line
    end
    local bp = M.breakpoints[hex(address)]
    local here = address == pc
    local chunks = {
      { bp and (bp.verified == false and icons.disabled or icons.enabled) or " ", "DiagnosticError" },
      { here and icons.current or " ", "DapperCurrent" },
      { " " .. ("0x%016x"):format(address) .. "  ", "DapperLine" },
    }
    if config.values.disassembly.bytes and insn.instructionBytes then
      table.insert(chunks, { ("%-24s"):format(insn.instructionBytes:gsub("..", "%0 ")), "DapperMuted" })
    end
    table.insert(chunks, { insn.instruction })
    local synced = sync and cur_path == sync.path and cur_line == sync.line
    canvas:add(
      chunks,
      { kind = "instruction", address = hex(address), text = insn.instruction, path = cur_path, line = cur_line },
      (here and { line_hl = "DapperPc" }) or (synced and { line_hl = "DapperSync" }) or nil
    )
    if synced and not first_synced then
      first_synced = #canvas.lines
    end
    if here then
      cursor = #canvas.lines
    end
  end
  if M.anchor and first_synced then -- (gone to a line: the cursor on its first instruction)
    cursor = first_synced
  end
  if cursor then -- (moved there when the current instruction is a new one)
    canvas.cursor, canvas.cursor_key = { cursor, 0 }, tostring(pc) .. ":" .. tostring(M.anchor)
  end
end

--- sends the instruction breakpoints to the session (all of them: the request replaces them)
function M.send(session)
  session = session or require("dap").session()
  if not session then
    return
  end
  util.run(function()
    local addresses = vim.tbl_keys(M.breakpoints)
    table.sort(addresses)
    local list = vim.tbl_map(function(address)
      return { instructionReference = address }
    end, addresses)
    local result = util.request(session, "setInstructionBreakpoints", { breakpoints = list })
    for i, bp in ipairs(result and result.breakpoints or {}) do
      if M.breakpoints[addresses[i]] then
        M.breakpoints[addresses[i]].verified = bp.verified
      end
    end
    require("dapper.views").refresh("disassembly")
    require("dapper.views").refresh("breakpoints")
  end)
end

function M.toggle_breakpoint(address, label)
  if M.breakpoints[address] then
    M.breakpoints[address] = nil
  else
    M.breakpoints[address] = { label = label or "" }
  end
  M.send()
end

--- goes to `expr` (a function, an address, an expression); nil: back to the current instruction
function M.go(expr)
  M.sync = nil
  if not expr then
    M.anchor = nil
    return require("dapper.views").refresh("disassembly")
  end
  local session = require("dap").session()
  if not session then
    return
  end
  util.run(function()
    local address = expr:match("^0[xX]%x+$") and tonumber(expr:sub(3), 16)
    if not address then
      local result = util.evaluate(session, "(void *)(" .. expr .. ")")
      address = result and number(result.result)
    end
    if not address then
      return util.notify("Not an address: " .. expr, vim.log.levels.WARN)
    end
    M.anchor = address
    require("dapper.views").refresh("disassembly")
  end)
end

--- a stop: following the current instruction, the highlight follows its line again
function M.stopped()
  if not M.anchor then
    M.sync = nil
  end
end

--- goes to the instructions of source line `line` of `path` (highlighted); the current frame's
--- line: the current instruction, followed
function M.go_line(path, line)
  local session = require("dap").session()
  if not session then
    return
  end
  local frame = session.current_frame
  if frame and frame.source and frame.source.path == path and frame.line == line then
    M.anchor, M.sync = nil, nil
    return require("dapper.views").refresh("disassembly")
  end
  util.run(function()
    local result = util.request(session, "evaluate", {
      expression = ("info line %s:%d"):format(path, line),
      context = "repl",
      frameId = frame and frame.id,
    })
    local address = number(result and result.result:match("starts at address (0x%x+)"))
    if not address then
      return util.notify(("No code for line %d (a comment, or a declaration)"):format(line), vim.log.levels.WARN)
    end
    M.anchor, M.sync = address, { path = path, line = line }
    require("dapper.views").refresh("disassembly")
  end)
end

--- while the cursor is in it, stepping goes one instruction at a time
--- While the cursor is in it, stepping goes one instruction at a time (nvim-dap's
--- stepping_granularity, given back on leaving).
function M.attach(buf)
  local before -- { the granularity before } while in it
  local defaults = require("dap").defaults.fallback
  vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    buffer = buf,
    callback = function()
      before = before or { defaults.stepping_granularity }
      defaults.stepping_granularity = "instruction"
    end,
  })
  vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave" }, {
    buffer = buf,
    callback = function()
      if before then
        defaults.stepping_granularity, before = before[1], nil
      end
    end,
  })
end

M.keys = {
  {
    "x",
    "toggle an instruction breakpoint",
    function(item)
      if item and item.kind == "instruction" then
        M.toggle_breakpoint(item.address, item.text)
      end
    end,
  },
  {
    "<CR>",
    "on a source line: go to it; on an instruction: show its source line (and its instructions)",
    function(item)
      if not (item and item.path and item.line) then
        return
      end
      local buf = vim.fn.bufadd(item.path)
      vim.fn.bufload(buf)
      if item.kind == "source" then
        util.show_location(buf, item.line, 1, true)
      else
        util.show_location(buf, item.line, 1, false)
        M.sync = { path = item.path, line = item.line }
        require("dapper.views").refresh("disassembly")
      end
    end,
  },
  {
    "f",
    "find: go to a function, an address or an expression",
    function()
      util.run(function()
        local expr = util.input({
          prompt = "Disassemble at (a function, an address): ",
          completion = "customlist,v:lua.require'dapper.complete'.functions",
        })
        if expr and vim.trim(expr) ~= "" then
          M.go(vim.trim(expr))
        end
      end)
    end,
  },
  {
    ".",
    "back to the current instruction",
    function()
      M.go(nil)
    end,
  },
}

return M
