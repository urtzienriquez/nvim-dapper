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

  it("keeps the breakpoints on lines, gives them back when the file opens, turns them off", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main(void)", "{", "  int n = 1;", "  return n;", "}" }, file)
    vim.cmd("edit " .. file)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    require("dap").toggle_breakpoint()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    require("dap").set_breakpoint(nil, "3") -- (on its 3rd hit)
    vim.cmd("write")
    local kept = vim.tbl_filter(function(bp) -- (this file's: the tests before leave theirs)
      return bp.path == vim.fs.normalize(file)
    end, require("dapper.store").get("breakpoints"))
    assert.same({ { path = vim.fs.normalize(file), line = 3 }, { path = vim.fs.normalize(file), line = 4, hit = "3" } }, kept)

    vim.cmd("bwipeout!") -- (as after quitting: nvim-dap has none of it)
    assert.is_nil(require("dap.breakpoints").get()[buf])
    vim.cmd("edit " .. file)
    buf = vim.api.nvim_get_current_buf()
    local bps = require("dap.breakpoints").get(buf)[buf]
    assert.equals(2, #bps)

    local lines_ = require("dapper.lines")
    local function mine()
      return vim.tbl_filter(function(bp)
        return bp.path == vim.fs.normalize(file)
      end, lines_.all())
    end
    lines_.toggle(mine()[1]) -- (off: nvim-dap no longer has it; a ○ marks it)
    assert.equals(1, #require("dap.breakpoints").get(buf)[buf])
    local signs = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace("dapper.disabled"), 0, -1, { details = true })
    assert.equals(1, #signs)
    assert.equals(2, signs[1][2]) -- (row 3)
    dapper.show("breakpoints")
    assert.truthy(table.concat(lines("breakpoints"), "\n"):find("○ ", 1, true))
    lines_.toggle(mine()[1]) -- (on again)
    assert.equals(2, #require("dap.breakpoints").get(buf)[buf])
    require("dap").clear_breakpoints()
    lines_.save()
  end)

  it("deletes all breakpoints: of files open or not, turned off, on functions", function()
    local open_file, other = vim.fn.tempname() .. ".c", vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int a;", "int b;", "int c;" }, open_file)
    vim.fn.writefile({ "int d;", "int e;" }, other)
    vim.cmd("edit " .. other)
    require("dap").toggle_breakpoint()
    vim.cmd("write")
    vim.cmd("bwipeout") -- (kept, its file not open)
    vim.cmd("edit " .. open_file)
    require("dap").toggle_breakpoint()
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    require("dap").toggle_breakpoint()
    local lines_ = require("dapper.lines")
    for _, bp in ipairs(lines_.all()) do
      if bp.path == vim.fs.normalize(open_file) and bp.line == 2 then
        lines_.toggle(bp) -- (turned off)
      end
    end
    require("dapper.breaks").toggle_function("main")
    assert.truthy(#lines_.all() >= 3)

    dapper.clear_breakpoints()
    assert.same({}, lines_.all())
    assert.same({}, require("dap.breakpoints").get())
    assert.same({}, require("dapper.store").get("breakpoints"))
    assert.same({}, require("dapper.breaks").functions)
    assert.same({}, vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_create_namespace("dapper.disabled"), 0, -1, {}))
  end)

  describe("says what a key did", function()
    local messages, notify
    before_each(function()
      messages, notify = {}, vim.notify
      vim.notify = function(msg, level)
        table.insert(messages, { msg, level or vim.log.levels.INFO })
      end
    end)
    after_each(function()
      vim.notify = notify
    end)

    -- runs key `lhs` of view `name` on `item`
    local function press(name, lhs, item)
      for _, key in ipairs(require("dapper.views").get(name).keys) do
        if key[1] == lhs then
          return key[3](item)
        end
      end
      error("no key " .. lhs)
    end

    it("adding and deleting a watch", function()
      local watches = require("dapper.views.watches")
      for i = #watches.expressions, 1, -1 do
        table.remove(watches.expressions, i)
      end
      dapper.watch("count")
      press("watches", "d", { kind = "expression", index = 1 })
      assert.same({}, watches.expressions)
      assert.same({ { "Watching count" }, { "Stopped watching count" } }, vim.tbl_map(function(m)
        return { m[1] }
      end, messages))
    end)

    it("x on a watch line that is no value warns instead of doing nothing", function()
      press("watches", "x", { kind = "command", index = 1 })
      assert.same({ { "Not a value: no breaking when it changes", vim.log.levels.WARN } }, messages)
    end)

    it("turning a breakpoint off and on again", function()
      local file = vim.fn.tempname() .. ".c"
      vim.fn.writefile({ "int a;", "int b;" }, file)
      vim.cmd("edit " .. file)
      require("dap").toggle_breakpoint()
      local lines_ = require("dapper.lines")
      local function mine()
        return vim.tbl_filter(function(bp)
          return bp.path == vim.fs.normalize(file)
        end, lines_.all())[1]
      end
      press("breakpoints", "t", vim.tbl_extend("force", mine(), { kind = "breakpoint" }))
      press("breakpoints", "t", vim.tbl_extend("force", mine(), { kind = "breakpoint" }))
      local where = vim.fn.fnamemodify(file, ":~:.") .. ":1"
      assert.equals("Breakpoint at " .. where .. " off", messages[1][1])
      assert.equals("Breakpoint at " .. where .. " on", messages[2][1])
      dapper.clear_breakpoints()
    end)

    it("d on a selection deletes those watches (in Watches, through the real mapping)", function()
      local watches = require("dapper.views.watches")
      for i = #watches.expressions, 1, -1 do
        table.remove(watches.expressions, i)
      end
      for _, expr in ipairs({ "a", "b", "c" }) do
        watches.add(expr)
      end
      dapper.show("watches")
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == vim.fn.bufnr("dapper://watches") then
          vim.api.nvim_set_current_win(win)
        end
      end
      vim.wait(1000, function()
        return #lines("watches") == 3 and lines("watches")[1]:find("a", 1, true) ~= nil
      end, 10)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      messages = {}
      vim.api.nvim_feedkeys("Vjd", "x", false)
      assert.same({ "c" }, watches.expressions)
      assert.same({ { "Stopped watching a, b", vim.log.levels.INFO } }, messages)
      assert.are_not.equal("V", vim.api.nvim_get_mode().mode) -- (Visual mode left)
    end)

    it("d and t on a selection in Breakpoints", function()
      local file = vim.fn.tempname() .. ".c"
      vim.fn.writefile({ "int a;", "int b;", "int c;" }, file)
      vim.cmd("edit " .. file)
      for _, line in ipairs({ 1, 2 }) do
        vim.api.nvim_win_set_cursor(0, { line, 0 })
        require("dap").toggle_breakpoint()
      end
      local lines_ = require("dapper.lines")
      local function mine()
        return vim.tbl_map(
          function(bp)
            return vim.tbl_extend("force", bp, { kind = "breakpoint" })
          end,
          vim.tbl_filter(function(bp)
            return bp.path == vim.fs.normalize(file)
          end, lines_.all())
        )
      end
      local view = require("dapper.views").get("breakpoints")
      local function key(lhs)
        for _, k in ipairs(view.keys) do
          if k[1] == lhs then
            return k
          end
        end
      end
      key("t").range(mine())
      assert.equals("Breakpoints: 2 off, 0 on", messages[#messages][1])
      assert.is_true(vim.iter(mine()):all(function(bp)
        return bp.disabled == true
      end))
      key("d").range(mine())
      assert.equals("Deleted 2 breakpoints", messages[#messages][1])
      assert.same({}, mine())
    end)

    it("inline values on and off", function()
      dapper.toggle_virtual_text()
      dapper.toggle_virtual_text()
      local said = vim.tbl_map(function(m)
        return m[1]
      end, messages)
      table.sort(said)
      assert.same({ "Inline values off", "Inline values on" }, said)
    end)
  end)

  it(":checkhealth dapper checks the other debuggers too (not only gdb)", function()
    local dap = require("dap")
    dap.adapters.fake = { type = "executable", command = "no-such-debugger-xyz" }
    dap.configurations.fakeft = { { type = "fake", request = "launch", name = "x" } }
    vim.cmd("checkhealth dapper")
    local text = ""
    vim.wait(5000, function() -- (filled in as it checks)
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.bo[b].filetype == "checkhealth" then
          text = table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
        end
      end
      return text:find("program being debugged", 1, true) ~= nil
    end, 20)
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.bo[b].filetype == "checkhealth" then
        vim.api.nvim_buf_delete(b, { force = true })
      end
    end
    dap.adapters.fake, dap.configurations.fakeft = nil, nil
    assert.truthy(text:find("fake: no-such-debugger-xyz is not on $PATH (for fakeft)", 1, true), text)
  end)
end)
