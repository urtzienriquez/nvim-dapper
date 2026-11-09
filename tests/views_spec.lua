local dapper = require("dapper")

local function lines(name)
  local buf = vim.fn.bufnr("dapper://" .. name)
  vim.wait(1000, function()
    return #table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) > 0
  end, 10)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("views, without a debug session", function()
  before_each(function()
    require("dapper.panes").close()
    vim.cmd("only")
    dapper.setup({})
  end)

  it("Watches lists the expressions", function()
    local watches = require("dapper.views.watches")
    for i = #watches.expressions, 1, -1 do -- (an empty list: the other tests' are kept per project)
      table.remove(watches.expressions, i)
    end
    dapper.watch("x + 1")
    dapper.watch("buffer[2]")
    assert.same({ "  x + 1     = not debugging", "  buffer[2] = not debugging" }, lines("watches"))
  end)

  it("Breakpoints lists them with their code", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main(void) {", "  int x = 1;", "  return x;", "}" }, file)
    vim.cmd("edit " .. file)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    require("dap").toggle_breakpoint()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    require("dap").set_breakpoint("x > 0")
    dapper.show("breakpoints")
    local shown = lines("breakpoints")
    assert.equals(2, #shown)
    assert.truthy(shown[1]:find(":2  int x = 1;", 1, true))
    assert.truthy(shown[2]:find(":3  return x;  if x > 0", 1, true))
  end)

  it("Watches tells the debugger's commands from expressions", function()
    local command = require("dapper.views.watches").command
    assert.equals("p/t n", command("p/t n"))
    assert.equals("x/8xb &n", command("x/8xb &n"))
    assert.equals("print/x n", command("/x n"))
    assert.equals("info frame", command("info frame"))
    assert.equals("ptype struct point", command("ptype struct point"))
    for _, expr in ipairs({ "x / 2", "n", "p", "a[i] * 2", "print_count" }) do
      assert.is_nil(command(expr), expr)
    end
    assert.equals("x/2", command("x/2")) -- (gdb's x: a division is written with spaces)
  end)

  it("a value that changed since the last stop is highlighted", function()
    local tree = require("dapper.tree").new()
    local canvas = require("dapper.canvas")
    local function hl_of_value(value)
      local c = canvas.new()
      tree:variable(c, nil, { name = "x", value = value, variablesReference = 0 }, "x", nil, 0)
      return c.marks[#c.marks][4]
    end
    assert.equals("DapperValue", hl_of_value("1")) -- first stop: nothing to compare with
    tree:stopped()
    assert.equals("DapperValue", hl_of_value("1")) -- same value
    tree:stopped()
    assert.equals("DapperChanged", hl_of_value("2")) -- changed
    assert.equals("DapperChanged", hl_of_value("2")) -- (drawn again, same stop: still)
    tree:stopped()
    assert.equals("DapperValue", hl_of_value("2"))
    assert.same(
      { link = "DiagnosticVirtualTextWarn", default = true },
      vim.api.nvim_get_hl(0, { name = "DapperChanged" })
    )
  end)

  it("a struct or array without a value of its own shows what it holds", function()
    local children = {
      [1] = { { name = "mass", value = "20" }, { name = "pos", value = "", variablesReference = 2 } },
      [3] = vim.tbl_map(function(i)
        return { name = tostring(i), value = tostring(i * 1000) }
      end, vim.fn.range(0, 40)),
    }
    require("dapper.util").forget()
    local session = {
      id = 1,
      request = function(_, _, args)
        return nil, { variables = children[args.variablesReference] }
      end,
    }
    local tree = require("dapper.tree").new()
    local c = require("dapper.canvas").new()
    tree:variable(c, session, { name = "f", value = "", variablesReference = 1 }, "f", nil, 0)
    tree:variable(c, session, { name = "big", value = "", variablesReference = 3 }, "big", nil, 0)
    assert.truthy(c.lines[1]:find("f = {mass = 20, pos = {…}}", 1, true))
    assert.truthy(c.lines[2]:find("big = {0, 1000, 2000, ", 1, true))
    assert.truthy(c.lines[2]:find(", …}$"))
    assert.is_true(#c.lines[2] < 90)
  end)

  it("the keys' list (g?) closes with q", function()
    require("dapper.help").show_keys("Test", { { "x", "something" } })
    assert.is_true(vim.api.nvim_win_get_config(0).relative ~= "")
    vim.api.nvim_feedkeys("q", "x", false)
    assert.equals("", vim.api.nvim_win_get_config(0).relative)
  end)

  it("completes the frame's variables, a struct's members, and the file's names", function()
    local fake = {
      id = 7,
      stopped_thread_id = 1,
      current_frame = { id = 1 },
      request = function(_, command, args, cb)
        local answers = {
          scopes = { scopes = { { name = "Locals", variablesReference = 2 } } },
          variables = ({
            [2] = { variables = { { name = "frog" }, { name = "total" }, { name = "pointer" } } },
            [5] = { variables = { { name = "mass" }, { name = "pos" } } },
          })[args.variablesReference],
          evaluate = { variablesReference = (args.expression == "frog" or args.expression == "*(pointer)") and 5 or 0 },
        }
        cb(nil, answers[command])
      end,
    }
    local dap = require("dap")
    local session = dap.session
    dap.session = function()
      return fake
    end
    require("dapper.complete").forget()
    local complete = require("dapper").complete
    local ok, err = pcall(function()
      assert.same({ "frog.mass" }, complete("frog.m"))
      assert.same({ "frog.mass", "frog.pos" }, complete("frog."))
      assert.same({ "x + pointer->pos" }, complete("x + pointer->p"))
      assert.equals("total", complete("to")[1], "the frame's first")
    end)
    dap.session = session
    assert(ok, err)
    -- no program running: the names of the current file
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main(void) {", "  int counter = 0;", "  return counter;", "}" }, file)
    vim.cmd("edit " .. file)
    require("dapper.complete").forget()
    assert.same({ "counter" }, complete("cou"))
    assert.same({ "x > counter" }, complete("x > cou"))
  end)

  it("the others say there is nothing to show", function()
    for _, name in ipairs({ "scopes", "stack", "threads", "exceptions" }) do
      dapper.show(name)
      assert.same({ "Not debugging (:Dapper lists what you can do)" }, lines(name), name)
    end
  end)

  it("keeps each project's watches its own, after :cd to another", function()
    local watches = require("dapper.views.watches")
    local a, b = vim.fn.tempname(), vim.fn.tempname()
    vim.fn.mkdir(a, "p")
    vim.fn.mkdir(b, "p")
    local before = vim.fn.getcwd()
    vim.cmd.cd(a)
    dapper.watch("in_a")
    vim.cmd.cd(b)
    assert.is_false(vim.tbl_contains(watches.expressions, "in_a"))
    dapper.watch("in_b")
    vim.cmd.cd(a)
    assert.is_true(vim.tbl_contains(watches.expressions, "in_a"))
    assert.is_false(vim.tbl_contains(watches.expressions, "in_b"))
    vim.cmd.cd(b)
    assert.is_true(vim.tbl_contains(watches.expressions, "in_b"))
    vim.cmd.cd(before)
  end)
end)
