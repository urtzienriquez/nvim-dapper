--- Breakpoints: all of them: on lines (with their code, highlighted as in the file, and their
--- condition, hit count, log message), on functions, on instructions, and on values changing.

local util = require("dapper.util")

local M = { label = "Breakpoints", short = "Breaks", key = "B" }

function M.render(canvas)
  local by_buf = require("dap.breakpoints").get()
  local bufs = vim.tbl_keys(by_buf)
  table.sort(bufs, function(a, b)
    return vim.api.nvim_buf_get_name(a) < vim.api.nvim_buf_get_name(b)
  end)
  local any = false
  for _, buf in ipairs(bufs) do
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
    local list = by_buf[buf]
    table.sort(list, function(a, b)
      return a.line < b.line
    end)
    for _, bp in ipairs(list) do
      any = true
      local rejected = bp.state and bp.state.verified == false
      local chunks = {
        { name, rejected and "DapperMuted" or "DapperFile" },
        { ":" },
        { tostring(bp.line), "DapperLine" },
        { "  " },
      }
      vim.list_extend(chunks, util.code_chunks(buf, bp.line))
      for _, extra in ipairs({
        { bp.condition, "if " },
        { bp.hitCondition, "hits " },
        { bp.logMessage, "log " },
      }) do
        if extra[1] and extra[1] ~= "" then
          table.insert(chunks, { "  " .. extra[2] .. extra[1], "DapperMuted" })
        end
      end
      if rejected then
        table.insert(
          chunks,
          { "  (rejected" .. (bp.state.message and (": " .. bp.state.message) or "") .. ")", "DapperError" }
        )
      end
      canvas:add(chunks, { kind = "breakpoint", buf = buf, line = bp.line })
    end
  end
  local instructions = package.loaded["dapper.views.disassembly"] and require("dapper.views.disassembly").breakpoints
    or {}
  local addresses = vim.tbl_keys(instructions)
  table.sort(addresses)
  for _, address in ipairs(addresses) do
    any = true
    local bp = instructions[address]
    canvas:add({
      { address, bp.verified == false and "DapperMuted" or "DapperFile" },
      { "  " .. bp.label },
      { "  (instruction)", "DapperMuted" },
      bp.verified == false and { "  (rejected)", "DapperError" } or nil,
    }, { kind = "instruction", address = address })
  end
  local breaks = require("dapper.breaks")
  for _, f in ipairs(breaks.functions) do
    any = true
    local chunks = {
      { "ƒ ", "DapperMuted" },
      { f.name, f.verified == false and "DapperMuted" or "DapperName" },
      { "  (function)", "DapperMuted" },
    }
    if f.verified and f.source and f.line then -- (where it was placed)
      vim.list_extend(chunks, {
        { "  " .. (f.source.name or vim.fs.basename(f.source.path or "")), "DapperFile" },
        { ":" },
        { tostring(f.line), "DapperLine" },
      })
    elseif f.verified == false and f.reason == "pending" then
      table.insert(chunks, { "  (waiting for the program to load)", "DapperMuted" })
    elseif f.verified == false then
      table.insert(chunks, { "  (not found)", "DapperError" })
    end
    canvas:add(chunks, { kind = "function", name = f.name, source = f.source, line = f.line })
  end
  for _, c in ipairs(breaks.changes) do
    any = true
    canvas:add({
      { "⊙ ", "DapperMuted" },
      { c.expr, "DapperName" },
      { "  (when it changes)", "DapperMuted" },
    }, { kind = "change", expr = c.expr })
  end
  if not any then
    canvas:note("No breakpoints. On a line: nvim-dap's toggle_breakpoint. On a function:")
    canvas:note(":Dapper break {name}. When a value changes: x on it in Watches or Scopes.")
  end
end

-- the buffer and line of the breakpoint of `item` (on a line, or a function placed), or nil
local function location(item)
  if item and item.buf then
    return item.buf, item.line
  elseif item and item.kind == "function" and item.source and item.line then
    return util.source_buf(item.source), item.line
  end
end

M.keys = {
  {
    "<CR>",
    "go to it",
    function(item)
      if item and item.address then
        return require("dapper").disassembly(item.address)
      end
      local buf, line = location(item)
      if buf then
        util.show_location(buf, line, 1, true)
      end
    end,
  },
  {
    "p",
    "show it (the cursor stays)",
    function(item)
      local buf, line = location(item)
      if buf then
        util.show_location(buf, line, 1, false)
      end
    end,
  },
  {
    "d",
    "delete it",
    function(item)
      if item and item.address then -- an instruction breakpoint
        return require("dapper.views.disassembly").toggle_breakpoint(item.address)
      elseif item and item.kind == "function" then
        return require("dapper.breaks").toggle_function(item.name)
      elseif item and item.kind == "change" then
        return require("dapper.breaks").toggle_change(item.expr)
      end
      if not (item and item.buf) then
        return
      end
      local breakpoints = require("dap.breakpoints")
      breakpoints.remove(item.buf, item.line)
      local session = require("dap").session()
      if session then
        local all = breakpoints.get()
        all[item.buf] = all[item.buf] or {} -- (an empty list clears the file's)
        session:set_breakpoints(all)
      end
      require("dapper.views").refresh("breakpoints")
    end,
  },
}

return M
