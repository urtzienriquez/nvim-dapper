-- The Memory and Disassembly views, in a real gdb session (14 and later); skipped without it.

local version = vim.fn.executable("gdb") == 1 and tonumber(vim.fn.system("gdb --version"):match("GNU gdb [^%d]*(%d+)"))
  or 0
if version < 14 or vim.fn.executable("gcc") == 0 then
  describe("Memory and Disassembly", function()
    it("need gcc and gdb 14 or later (skipped)", function() end)
  end)
  return
end

local dap = require("dap")
local dapper = require("dapper")
local api = vim.api

local PROGRAM = [[
#include <stdio.h>
struct pt { short x; int y[2]; }; static int twice(int x) { int result = 2 * x; return result; }
int main(void)
{
    unsigned char c = 200; struct pt ps[2] = {{1, {2, 3}}, {4, {5, 6}}};
    int n = 21;
    int total = twice(n);
    printf("%d %d\n", total, c);
    return 0;
}]]

local function wait(fn, ms)
  return vim.wait(ms or 10000, fn, 20)
end

local function lines(name)
  return api.nvim_buf_get_lines(vim.fn.bufnr("dapper://" .. name), 0, -1, false)
end

local function evaluate(expr)
  local session, value = dap.session(), nil
  session:request(
    "evaluate",
    { expression = expr, context = "watch", frameId = session.current_frame.id },
    function(_, r)
      value = r and r.result or "?"
    end
  )
  wait(function()
    return value ~= nil
  end)
  return value
end

local function pc()
  return dap.session().current_frame.instructionPointerReference
end

local function press(keys)
  api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

describe("Memory and Disassembly", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(PROGRAM, "\n"), dir .. "/prog.c")
  vim.fn.system({ "gcc", "-g", "-O0", "-o", dir .. "/prog", dir .. "/prog.c" })
  local stops = 0
  dap.listeners.after.event_stopped["test"] = function()
    stops = stops + 1
  end

  local function stopped(n)
    return wait(function()
      return stops >= n and dap.session() and dap.session().current_frame ~= nil
    end)
  end

  it("Memory opens in a tab page, at a variable; the cursor says what is under it", function()
    dapper.setup({})
    dap.adapters.gdb = dapper.gdb()
    vim.cmd("edit " .. dir .. "/prog.c")
    api.nvim_win_set_cursor(0, { 7, 0 }) -- int total = twice(n);
    dap.toggle_breakpoint()
    dap.run({ name = "prog", type = "gdb", request = "launch", program = dir .. "/prog", cwd = dir })
    assert.is_true(stopped(1))
    vim.wait(500)

    dapper.memory("n")
    assert.equals("memory", vim.t.dapper_view)
    assert.is_true(wait(function()
      return table.concat(lines("memory"), "\n"):find("15 00 00 00", 1, true) ~= nil
    end))
    local row = api.nvim_win_get_cursor(0)[1]
    assert.truthy(lines("memory")[row]:find("15 00 00 00", 1, true), "the cursor is on n's row")
    api.nvim_exec_autocmds("CursorMoved", { buffer = 0 }) -- (headless nvim does not fire it)
    local said = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(0, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        table.insert(said, chunk[1])
      end
    end
    said = table.concat(said)
    assert.truthy(said:find("n = 21  int", 1, true), said) -- (the variable under the cursor)
    assert.is_nil(said:find("u8", 1, true), said) -- (only the variable: its value says it)
    local col = api.nvim_win_get_cursor(0)[2]
    assert.equals("15", lines("memory")[row]:sub(col + 1, col + 2))
    local column = vim.wo.winbar:match("%%#DapperTitle#(%x%x)") -- (its column, lit in the header)
    local address = tonumber(evaluate("(void *)&n"):match("0x(%x+)"), 16)
    assert.equals(("%02x"):format(address % 16), column, vim.wo.winbar)
    local readings = require("dapper.views.memory").readings(address) -- (shown in no variable)
    assert.truthy(readings:find("^u8 21  u16 21  u32 21"), readings)
  end)

  it("opened without an expression, goes to the frame's variables, frames labelled", function()
    vim.cmd("tabclose")
    dapper.memory("")
    assert.is_true(wait(function()
      local row = api.nvim_win_get_cursor(0)[1]
      return (lines("memory")[row] or ""):find("c8", 1, true) ~= nil -- (c's row: n's too)
    end))
    api.nvim_exec_autocmds("CursorMoved", { buffer = 0 }) -- (headless nvim does not fire it)
    local labels = {}
    for _, mark in ipairs(api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        table.insert(labels, chunk[1])
      end
    end
    assert.truthy(table.concat(labels):find("⟨main⟩", 1, true), table.concat(labels, "|"))
    local said = table.concat(labels)
    assert.truthy(said:find("c = 200", 1, true) or said:find("n = 21", 1, true), said) -- (the one under the cursor)
    require("dapper.views.memory").go("n") -- (back to n, for the tests after)
    assert.is_true(wait(function()
      local row = api.nvim_win_get_cursor(0)[1]
      return (lines("memory")[row] or ""):find("15 00 00 00", 1, true) ~= nil
    end))
  end)

  it("names the member of a struct or array under the cursor", function()
    require("dapper.views.memory").go("ps[1].y[1]")
    assert.is_true(wait(function()
      local row = api.nvim_win_get_cursor(0)[1]
      return (lines("memory")[row] or ""):find("06 00 00 00", 1, true) ~= nil
    end))
    local function said()
      local row = api.nvim_win_get_cursor(0)[1]
      local text = {}
      for _, mark in ipairs(api.nvim_buf_get_extmarks(0, -1, { row - 1, 0 }, { row - 1, -1 }, { details = true })) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          table.insert(text, chunk[1])
        end
      end
      return table.concat(text)
    end
    vim.w.dapper_bar_address = nil
    api.nvim_exec_autocmds("CursorMoved", { buffer = 0 }) -- (headless nvim does not fire it)
    assert.is_true(wait(function()
      return said():find("ps[1].y[1] = 6  int", 1, true) ~= nil
    end), said())
    require("dapper.views.memory").go("n") -- (back to n, for the tests after)
    assert.is_true(wait(function()
      local row = api.nvim_win_get_cursor(0)[1]
      return (lines("memory")[row] or ""):find("15 00 00 00", 1, true) ~= nil
    end))
  end)

  it("writes a byte with r", function()
    local input = vim.ui.input
    vim.ui.input = function(_, cb)
      cb("16")
    end
    press("r")
    vim.ui.input = input
    assert.is_true(wait(function()
      return evaluate("n") == "22"
    end))
  end)

  it("goes to a variable or an address with g", function()
    require("dapper.views.memory").go("c")
    assert.is_true(wait(function()
      local row = api.nvim_win_get_cursor(0)[1]
      return (lines("memory")[row] or ""):find("c8", 1, true) ~= nil
    end))
    local address = evaluate("(void *)&n")
    require("dapper.views.memory").go(address)
    assert.is_true(wait(function()
      local row = api.nvim_win_get_cursor(0)[1]
      return (lines("memory")[row] or ""):find("16 00 00 00", 1, true) ~= nil
    end))
  end)

  it("marks the bytes that changed at a step", function()
    require("dapper.views.memory").go("total")
    vim.wait(500)
    dap.step_over()
    assert.is_true(stopped(2))
    assert.is_true(wait(function()
      for _, mark in ipairs(api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
        if mark[4].hl_group == "DapperChanged" then
          return true
        end
      end
    end))
  end)

  it("Disassembly opens in its own tab page, at the current instruction", function()
    dapper.disassembly()
    assert.equals("disassembly", vim.t.dapper_view)
    assert.is_true(wait(function()
      return table.concat(lines("disassembly"), "\n"):find("→", 1, true) ~= nil
    end))
    local text = table.concat(lines("disassembly"), "\n")
    assert.truthy(text:find("<main", 1, true) or text:find("main", 1, true))
    assert.truthy(text:find("printf", 1, true), "the source lines between the instructions")
    local row = api.nvim_win_get_cursor(0)[1]
    assert.truthy(lines("disassembly")[row]:find("→", 1, true), "the cursor on the current instruction")
  end)

  it("steps one instruction at a time in it, without a code window in its tab page", function()
    assert.equals("instruction", dap.defaults.fallback.stepping_granularity)
    local before, line = pc(), dap.session().current_frame.line
    dap.step_over()
    assert.is_true(stopped(3))
    assert.is_true(wait(function() -- (once nvim-dap has the new frame)
      return pc() ~= before
    end))
    assert.equals(line, dap.session().current_frame.line, "still on the same line of code")
    assert.equals(1, #api.nvim_tabpage_list_wins(0))
    assert.equals("disassembly", vim.t.dapper_view)
  end)

  it("stops at an instruction breakpoint", function()
    -- (an instruction still ahead: the first of `return 0;`; twice was already called)
    require("dapper.views.disassembly").go(nil)
    local row
    assert.is_true(wait(function()
      local after_source = false
      for n, line in ipairs(lines("disassembly")) do
        if line:find("return 0;", 1, true) then
          after_source = true
        elseif after_source and line:match("^%s*.?%s*0x") then
          row = n
          return true
        end
      end
    end))
    api.nvim_win_set_cursor(0, { row, 0 })
    local item = require("dapper.canvas").item()
    press("x")
    local bp = require("dapper.views.disassembly").breakpoints
    assert.is_true(wait(function()
      return bp[item.address] and bp[item.address].verified == true
    end))
    vim.cmd("tabfirst")
    dap.continue()
    assert.is_true(stopped(4))
    assert.is_true(wait(function()
      return tonumber(pc():sub(3), 16) == tonumber(item.address:sub(3), 16)
    end))
    assert.equals("statement", dap.defaults.fallback.stepping_granularity, "restored outside it")
  end)

  it("lists instruction breakpoints in Breakpoints", function()
    dapper.show("breakpoints")
    assert.is_true(wait(function()
      return table.concat(lines("breakpoints"), "\n"):find("(instruction)", 1, true) ~= nil
    end))
    dap.terminate()
    wait(function()
      return dap.session() == nil
    end)
  end)
end)
