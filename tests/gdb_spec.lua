-- A real debug session with gdb (14 and later speak DAP); skipped without it.

local version = vim.fn.executable("gdb") == 1 and tonumber(vim.fn.system("gdb --version"):match("GNU gdb [^%d]*(%d+)"))
  or 0
if version < 14 or vim.fn.executable("gcc") == 0 then
  describe("a gdb session", function()
    it("needs gcc and gdb 14 or later (skipped)", function() end)
  end)
  return
end

local dap = require("dap")
local dapper = require("dapper")

local PROGRAM = [[
#include <stdio.h>

static int twice(int x)
{
    int result = 2 * x;
    return result;
}

int main(void)
{
    unsigned char c = 200;
    int n = c - 200;
    printf("number? ");
    fflush(stdout);
    scanf("%d", &n);
    int total = twice(n);
    printf("total %d\n", total);
    return 0;
}]]

local function text(name)
  return table.concat(vim.api.nvim_buf_get_lines(vim.fn.bufnr("dapper://" .. name), 0, -1, false), "\n")
end

local function wait(fn, ms)
  return vim.wait(ms or 10000, fn, 20)
end

describe("a gdb session", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(vim.split(PROGRAM, "\n"), dir .. "/prog.c")
  vim.fn.system({ "gcc", "-g", "-O0", "-o", dir .. "/prog", dir .. "/prog.c" })

  local stops = 0
  dap.listeners.after.event_stopped["test"] = function()
    stops = stops + 1
  end

  it("opens the panes, gives the program a terminal, and shows where it stopped", function()
    dapper.setup({})
    dap.adapters.gdb = dapper.gdb()
    vim.cmd("edit " .. dir .. "/prog.c")
    vim.api.nvim_win_set_cursor(0, { 5, 0 }) -- int result = 2 * x;
    dap.toggle_breakpoint()
    dapper.watch("n * 10")
    dap.run({ name = "prog", type = "gdb", request = "launch", program = dir .. "/prog", cwd = dir })

    assert.is_true(wait(function()
      return require("dapper.panes").is_open() and require("dapper.io").buffer() ~= nil
    end))
    local io = require("dapper.io").buffer()
    assert.is_true(wait(function()
      return table.concat(vim.api.nvim_buf_get_lines(io, 0, -1, false)):find("number?", 1, true) ~= nil
    end))
    vim.fn.chansend(vim.bo[io].channel, "21\r") -- typed in the program's terminal
    assert.is_true(wait(function()
      return stops >= 1 and dap.session().current_frame ~= nil
    end))

    assert.is_true(wait(function()
      return text("stack"):find("→ twice", 1, true) ~= nil
    end))
    assert.truthy(text("stack"):find("main", 1, true))
    assert.is_true(wait(function()
      return text("watches"):find("No symbol", 1, true) ~= nil -- (n is main's: not in twice)
    end))
  end)

  it("follows the frame chosen in the call stack", function()
    local buf = vim.fn.bufnr("dapper://stack")
    local win = vim.fn.bufwinid(buf)
    for n, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      if line:find("main", 1, true) then
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_cursor(win, { n, 0 })
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      end
    end
    assert.is_true(wait(function()
      return text("watches"):find("n %* 10%s+= 210  int") ~= nil
    end))
    dapper.show("scopes")
    assert.is_true(wait(function()
      return text("scopes"):find("\n%s*n%s+= 21  int") ~= nil
    end))
  end)

  it("expands a char pointer gdb gives nothing to expand (&c)", function()
    dapper.watch("&c")
    dapper.show("watches")
    assert.is_true(
      wait(function()
        return text("watches"):find("%*&c%s+= 200 .-unsigned char") ~= nil
      end),
      text("watches")
    )
  end)

  it("watches gdb's commands too (p/t n, /x n, x/4xb &n)", function()
    dapper.watch("p/t n")
    dapper.watch("/x n")
    dapper.watch("x/4xb &n")
    dapper.show("watches")
    assert.is_true(
      wait(function()
        local shown = text("watches")
        return shown:find("p/t n%s+= 10101") ~= nil
          and shown:find("/x n%s+= 0x15") ~= nil
          and shown:find("x/4xb &n%s+= 0x%x+.-0x15%s+0x00%s+0x00%s+0x00") ~= nil
      end),
      text("watches")
    )
  end)

  it("opens the hover float; a second time, goes into it (as Neovim's hover)", function()
    local win = vim.api.nvim_get_current_win()
    dapper.hover("n")
    assert.equals(win, vim.api.nvim_get_current_win(), "the first time: the cursor stays")
    local float = vim.tbl_filter(function(w)
      return vim.api.nvim_win_get_config(w).relative ~= ""
    end, vim.api.nvim_tabpage_list_wins(0))[1]
    assert.is_true(wait(function()
      return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false)):find("21", 1, true)
        ~= nil
    end))
    dapper.hover("n")
    assert.equals(float, vim.api.nvim_get_current_win(), "the second time: into it")
    vim.api.nvim_feedkeys("q", "x", false)
    assert.is_false(vim.api.nvim_win_is_valid(float), "q closes it")
    vim.api.nvim_set_current_win(win)
  end)

  it("keeps the program's terminal out of the buffer list", function()
    local buf = require("dapper.io").buffer()
    assert.is_true(wait(function()
      return not vim.bo[buf].buflisted
    end))
  end)

  it("keeps the cursor where it was when the program stops", function()
    local pane = vim.fn.bufwinid(vim.fn.bufnr("dapper://watches"))
    vim.api.nvim_set_current_win(pane)
    dap.step_over()
    assert.is_true(wait(function()
      return stops >= 2
    end))
    vim.wait(300)
    assert.equals(pane, vim.api.nvim_get_current_win())
  end)

  it("keeps the Program I/O pane for the next session, showing its program", function()
    dapper.show("io")
    local old = require("dapper.io").buffer()
    dap.terminate()
    assert.is_true(wait(function()
      return dap.session() == nil
    end))
    dapper.open() -- (to read the output, then debug again)
    assert.is_true(require("dapper.panes").shows("io"))
    stops = 0
    dap.run({ name = "prog", type = "gdb", request = "launch", program = dir .. "/prog", cwd = dir })
    assert.is_true(wait(function()
      local buf = require("dapper.io").buffer()
      return buf ~= old and require("dapper.panes").shows("io") and #vim.fn.win_findbuf(buf) > 0
    end))
    vim.fn.chansend(vim.bo[require("dapper.io").buffer()].channel, "21\r")
    assert.is_true(wait(function()
      return stops >= 1
    end))
  end)

  it("closes with the session", function()
    dap.terminate()
    assert.is_true(wait(function()
      return dap.session() == nil and not require("dapper.panes").is_open()
    end))
  end)
end)
