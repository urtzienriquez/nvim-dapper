--- Breakpoints: all of them: on lines (with their code, highlighted as in the file, and their
--- condition, hit count, log message; also those of files not open, and those turned off), on
--- functions, on instructions, and on values changing.

local util = require("dapper.util")

local M = { label = "Breakpoints", short = "Breaks", key = "B" }

function M.render(canvas)
  local any = false
  local icons = require("dapper.config").values.icons
  for _, bp in ipairs(require("dapper.lines").all()) do
    any = true
    local rejected = bp.state and bp.state.verified == false
    local muted = rejected or bp.disabled
    local chunks = {
      { (bp.disabled and icons.disabled or icons.enabled) .. " ", bp.disabled and "DapperDisabled" or "DapperEnabled" },
      { vim.fn.fnamemodify(bp.path, ":~:."), muted and "DapperMuted" or "DapperFile" },
      { ":" },
      { tostring(bp.line), "DapperLine" },
      { "  " },
    }
    if bp.buf then
      vim.list_extend(chunks, util.code_chunks(bp.buf, bp.line))
    else -- (a file not open)
      table.insert(chunks, { vim.trim(vim.fn.readfile(bp.path, "", bp.line)[bp.line] or ""), "DapperMuted" })
    end
    for _, extra in ipairs({ { bp.condition, "if " }, { bp.hit, "hit " }, { bp.log, "log " } }) do
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
    canvas:add(chunks, vim.tbl_extend("force", bp, { kind = "breakpoint" }))
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
  if item and item.kind == "breakpoint" then
    local buf = item.buf or vim.fn.bufadd(item.path) -- (a file not open: opened)
    vim.fn.bufload(buf)
    return buf, item.line
  elseif item and item.kind == "function" and item.source and item.line then
    return util.source_buf(item.source), item.line
  end
end

-- file:line of a breakpoint on a line, as the view shows it
local function where(bp)
  return vim.fn.fnamemodify(bp.path, ":~:.") .. ":" .. bp.line
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
      if item and item.kind == "breakpoint" then
        require("dapper.lines").delete(item)
        require("dapper.views").refresh("breakpoints")
        util.notify("Deleted the breakpoint at " .. where(item))
      end
    end,
  },
  {
    "t",
    "turn it off, or on again (a breakpoint on a line: kept, ○)",
    function(item)
      if item and item.kind == "breakpoint" then
        local was_off = item.disabled
        require("dapper.lines").toggle(item)
        require("dapper.views").refresh("breakpoints")
        util.notify("Breakpoint at " .. where(item) .. (was_off and " on" or " off"))
      elseif item then
        util.notify("Only breakpoints on lines can be turned off (d deletes this one)", vim.log.levels.WARN)
      end
    end,
  },
}

return M
