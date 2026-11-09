-- Function breakpoints, breaking when a value changes, pins, set next statement, Disassembly of
-- a line, completion, the status, the palette, :checkhealth; in a real gdb session (skipped
-- without gdb 14 or later).

local version = vim.fn.executable("gdb") == 1 and tonumber(vim.fn.system("gdb --version"):match("GNU gdb [^%d]*(%d+)"))
  or 0
if version < 14 or vim.fn.executable("gcc") == 0 then
  describe("features", function()
    it("need gcc and gdb 14 or later (skipped)", function() end)
  end)
  return
end

local dap = require("dap")
local dapper = require("dapper")
local api = vim.api

local PROGRAM = [[
#include <stdio.h>
static int twice(int x)
{
    int result = 2 * x;
    return result;
}
int main(void)
{
    int n = 21;
    int total = 0;
    n = n + 1;
    total = twice(n);
    printf("%d\n", total);
    return 0;
}]]

local function wait(fn, ms)
  return vim.wait(ms or 10000, fn, 20)
end

local function frame()
  return dap.session() and dap.session().current_frame or {}
end

local function lines(name)
  return table.concat(api.nvim_buf_get_lines(vim.fn.bufnr("dapper://" .. name), 0, -1, false), "\n")
end

local function virt_texts(buf, ns_name)
  local out = {}
  for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace(ns_name), 0, -1, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      table.insert(out, chunk[1])
    end
  end
  return table.concat(out)
end

describe("features", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local file = dir .. "/prog.c"
  vim.fn.writefile(vim.split(PROGRAM, "\n"), file)
  vim.fn.system({ "gcc", "-g", "-O0", "-o", dir .. "/prog", file })
  local stops = 0
  dap.listeners.after.event_stopped["test"] = function()
    stops = stops + 1
  end
  local code_win, code_buf

  local function stopped_at(n, check)
    return wait(function()
      return stops >= n and frame().line ~= nil and (not check or check())
    end)
  end

  it("needs no adapter of yours (setup gives gdb one), and shows the status", function()
    dap.adapters.gdb = nil
    dapper.setup({})
    assert.equals("function", type(dap.adapters.gdb))
    assert.equals("", dapper.status())
    vim.cmd("edit " .. file)
    code_win, code_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
    api.nvim_win_set_cursor(0, { 10, 0 }) -- int total = 0;
    dap.toggle_breakpoint()
    dap.run({ name = "prog", type = "gdb", request = "launch", program = dir .. "/prog", cwd = dir })
    assert.is_true(stopped_at(1))
    assert.equals("⏸ prog.c:10 main", dapper.status())
  end)

  it("completes the frame's variables", function()
    api.nvim_set_current_win(code_win)
    assert.truthy(vim.tbl_contains(dapper.complete("t"), "total"))
    assert.truthy(vim.tbl_contains(dapper.complete("n + to"), "n + total"))
  end)

  it("pins a value to a line, shown at each stop", function()
    api.nvim_set_current_win(code_win)
    api.nvim_win_set_cursor(0, { 11, 4 })
    dapper.pin("n")
    assert.is_true(wait(function()
      return virt_texts(code_buf, "dapper.pins"):find("▹ n = 21", 1, true) ~= nil
    end))
    assert.same({ { path = vim.fs.normalize(file), line = 11, expr = "n" } }, require("dapper.store").get("pins"))
  end)

  it("moves a pin with its line, also when drawn again", function()
    local function pin_row()
      local marks = api.nvim_buf_get_extmarks(code_buf, api.nvim_create_namespace("dapper.pins"), 0, -1, {})
      return marks[1] and marks[1][2] + 1
    end
    api.nvim_buf_set_lines(code_buf, 0, 0, false, { "", "" }) -- (two lines above it)
    require("dapper.pins").draw()
    assert.equals(13, pin_row())
    api.nvim_buf_set_lines(code_buf, 0, 2, false, {}) -- (and back)
    require("dapper.pins").draw()
    assert.equals(11, pin_row())
    vim.bo[code_buf].modified = false
  end)

  it("breaks when a value changes", function()
    dapper.break_on_change("n")
    assert.is_true(wait(function()
      return #require("dapper.breaks").changes == 1
    end))
    dapper.show("breakpoints")
    assert.is_true(wait(function()
      return lines("breakpoints"):find("⊙ n  (when it changes)", 1, true) ~= nil
    end))
    dap.continue()
    assert.is_true(stopped_at(2, function()
      return frame().line ~= 10
    end))
    assert.is_true(frame().line == 11 or frame().line == 12, "stopped right after n changed")
    assert.is_true(
      wait(function()
        return virt_texts(code_buf, "dapper.pins"):find("▹ n = 22", 1, true) ~= nil
      end),
      "the pin follows"
    )
    dapper.break_on_change("n") -- (off)
    assert.is_true(wait(function()
      return #require("dapper.breaks").changes == 0
    end))
  end)

  it("breaks on a function, by name", function()
    dapper.break_on("twice")
    assert.is_true(wait(function()
      return require("dapper.breaks").functions[1].verified == true
    end))
    assert.truthy(lines("breakpoints"):find("ƒ twice  (function)", 1, true))
    dap.continue()
    assert.is_true(stopped_at(3, function()
      return frame().name == "twice"
    end))
    dapper.break_on("twice") -- (off)
    assert.same({}, require("dapper.store").get("functions"))
  end)

  it("highlights the code of the breakpoints, as in the file", function()
    local groups = {}
    local buf = vim.fn.bufnr("dapper://breakpoints")
    for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
      if mark[4].hl_group then
        groups[mark[4].hl_group] = true
      end
    end
    assert.truthy(groups["@type.builtin.c"] or groups["@type.c"], vim.inspect(vim.tbl_keys(groups)))
  end)

  it("goes on from another line (set next statement)", function()
    dap.step_out()
    assert.is_true(stopped_at(4, function()
      return frame().name == "main"
    end))
    api.nvim_set_current_win(code_win)
    api.nvim_win_set_cursor(code_win, { 14, 4 }) -- return 0; (printf not run)
    dapper.jump()
    assert.is_true(wait(function()
      return frame().line == 14
    end))
  end)

  it("disassembles the cursor's line, its instructions highlighted", function()
    api.nvim_set_current_win(code_win)
    api.nvim_win_set_cursor(code_win, { 13, 4 }) -- printf
    dapper.disassembly()
    local buf = vim.fn.bufnr("dapper://disassembly")
    assert.is_true(wait(function()
      for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
        if mark[4].line_hl_group == "DapperSync" then
          return true
        end
      end
    end))
    local row = api.nvim_win_get_cursor(0)[1]
    local item = require("dapper.canvas").items_of[buf][row]
    assert.equals(13, item.line, "the cursor on the line's first instruction")
    vim.cmd("tabclose")
  end)

  it("lists in the palette what can be done now", function()
    api.nvim_set_current_win(code_win)
    local labels
    local select = vim.ui.select
    vim.ui.select = function(items, opts)
      labels = vim.tbl_map(opts.format_item, items)
    end
    dapper.palette()
    vim.ui.select = select
    assert.truthy(vim.tbl_contains(labels, "Go on from this line (set next statement)"))
    assert.truthy(vim.tbl_contains(labels, "Break on a function…"))
    assert.truthy(vim.tbl_contains(labels, "Memory: the frame's variables"))
  end)

  it("checks the setup (:checkhealth dapper)", function()
    vim.cmd("checkhealth dapper")
    local text = ""
    wait(function()
      for _, b in ipairs(api.nvim_list_bufs()) do
        if vim.bo[b].filetype == "checkhealth" then
          text = table.concat(api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        end
      end
      return text:find("debug information", 1, true) ~= nil
    end)
    if version >= 16 then
      assert.truthy(text:find("gdb %d+ %(it speaks DAP%)"), text)
    else -- (14, 15: they start the program before the breakpoints are set)
      assert.truthy(text:find("gdb %d+ starts the program before the breakpoints are set"), text)
    end
    assert.truthy(text:find("has debug information", 1, true), text)
    assert.truthy(text:find("setup() called", 1, true), text)
    for _, b in ipairs(api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "checkhealth" then
        api.nvim_buf_delete(b, { force = true })
      end
    end
  end)

  it("keeps the watches per project", function()
    dapper.watch("total")
    assert.truthy(vim.tbl_contains(require("dapper.store").get("watches"), "total"))
    dap.terminate()
    wait(function()
      return dap.session() == nil
    end)
  end)

  -- (gdb 14 and 15 run the program at the launch request, before the breakpoints are set: the
  -- function breakpoints dapper sends then come too late. gdb 16 waits for configurationDone.)
  local it16 = version >= 16 and it or pending
  it16("verifies a function breakpoint set before the session (pending until it loads)", function()
    dap.clear_breakpoints() -- (the line ones of the tests before: it stops in twice first)
    dapper.break_on("twice")
    stops = 0
    dap.run({ name = "prog", type = "gdb", request = "launch", program = dir .. "/prog", cwd = dir })
    assert.is_true(wait(function()
      return stops >= 1 and frame().name == "twice"
    end))
    local f = require("dapper.breaks").functions[1]
    assert.is_true(wait(function()
      return f.verified == true
    end))
    assert.equals(4, f.line, "placed at the function's first line")
    dapper.show("breakpoints")
    assert.is_true(
      wait(function()
        return lines("breakpoints"):find("ƒ twice  (function)  prog.c:4", 1, true) ~= nil
      end),
      lines("breakpoints")
    )
    dapper.break_on("twice") -- (off)
    dap.terminate()
    wait(function()
      return dap.session() == nil
    end)
  end)
end)
