local dapper = require("dapper")
local panes = require("dapper.panes")

local function list()
  local out = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.wo[win].winbar:find("DapperTab", 1, true) then
      local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):match("dapper://(.*)") or "?"
      table.insert(out, { win = win, view = name })
    end
  end
  return out
end

local function views()
  return vim.tbl_map(function(p)
    return p.view
  end, list())
end

local function press(win, keys)
  vim.api.nvim_set_current_win(win)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
end

local function column_width()
  return vim.api.nvim_win_get_width(list()[1].win)
end

describe("panes", function()
  before_each(function()
    panes.close() -- (first: the cursor may be in a pane, which :only would keep)
    vim.cmd("only")
    dapper.setup({}) -- (and they open as the layout says, not as the last test left them)
  end)

  it("open as the layout says: Watches above the call stack, on the right", function()
    dapper.open()
    assert.same({ "watches", "stack" }, views())
    local first = list()[1].win
    assert.equals(math.floor(vim.o.columns * 0.4), vim.api.nvim_win_get_width(first))
    assert.is_true(vim.api.nvim_win_get_position(first)[2] > 0)
    assert.is_true(vim.wo[first].winfixbuf)
  end)

  it("switch views with their keys, and ]v / [v", function()
    dapper.open()
    local top = list()[1].win
    press(top, "B")
    assert.same({ "breakpoints", "stack" }, views())
    press(top, "]v")
    assert.equals("stack", views()[1])
    press(top, "[v[v")
    assert.equals("exceptions", views()[1])
  end)

  it("split (keeping the column's width) and close one by one, with :q", function()
    dapper.open()
    local width = column_width()
    press(list()[1].win, "<C-w>s")
    assert.same({ "watches", "scopes", "stack" }, views())
    press(list()[1].win, "<C-w>v")
    assert.equals(4, #list())
    for _, p in ipairs(list()) do
      local col = vim.api.nvim_win_get_position(p.win)[2]
      assert.is_true(col >= vim.o.columns - width - 1, "the column did not grow")
    end
    vim.api.nvim_set_current_win(list()[2].win)
    vim.cmd("quit")
    assert.equals(3, #list())
    assert.equals(width, column_width())
    for _ = 1, 3 do
      vim.api.nvim_set_current_win(list()[1].win)
      vim.cmd("quit")
    end
    assert.equals(0, #list())
  end)

  it("open again as they were closed", function()
    dapper.open()
    press(list()[1].win, "S")
    press(list()[2].win, "<C-w>s")
    local before = views()
    dapper.toggle()
    assert.equals(0, #list())
    dapper.toggle()
    assert.same(before, views())
  end)

  it("open again with the same nesting (two side by side, above the call stack)", function()
    dapper.open()
    local width = column_width()
    press(list()[1].win, "<C-w>v") -- Watches | Scopes, above the call stack
    local function shape()
      local function walk(node)
        if node[1] == "leaf" then
          local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(node[2])):match("dapper://(.*)")
          return name
        end
        local parts = {}
        for _, child in ipairs(node[2]) do
          local part = walk(child)
          if part then
            table.insert(parts, part)
          end
        end
        if #parts == 0 then
          return nil
        end
        return #parts == 1 and parts[1] or (node[1] .. "(" .. table.concat(parts, ",") .. ")")
      end
      return walk(vim.fn.winlayout())
    end
    assert.equals("col(row(watches,scopes),stack)", shape())
    dapper.toggle()
    dapper.toggle()
    assert.equals("col(row(watches,scopes),stack)", shape())
    assert.equals(width, vim.api.nvim_win_get_width(list()[3].win))
  end)

  it("redo :vsplit and :split typed in a pane as their own splits", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main(void) { return 0; }" }, file)
    vim.cmd("edit " .. file)
    local code = vim.api.nvim_get_current_win()
    dapper.open()
    local code_width, width = vim.api.nvim_win_get_width(code), column_width()
    vim.api.nvim_set_current_win(list()[1].win)
    vim.cmd("vsplit")
    vim.wait(300)
    assert.equals(code_width, vim.api.nvim_win_get_width(code))
    assert.same({ "watches", "scopes", "stack" }, views())
    vim.api.nvim_set_current_win(list()[3].win)
    vim.cmd("split")
    vim.wait(300)
    assert.equals(code_width, vim.api.nvim_win_get_width(code))
    assert.same({ "watches", "scopes", "stack", "exceptions" }, views())
    assert.equals(width, vim.api.nvim_win_get_width(list()[3].win))
  end)

  it("keep the width you resize the column to", function()
    dapper.open()
    vim.api.nvim_win_set_width(list()[1].win, 50)
    vim.api.nvim_exec_autocmds("WinResized", {})
    vim.api.nvim_set_current_win(list()[1].win)
    vim.cmd("vsplit")
    vim.wait(300)
    assert.equals(50, vim.api.nvim_win_get_width(list()[3].win))
  end)

  it("open again as they were left, after :q closed them one by one", function()
    dapper.open()
    press(list()[1].win, "S") -- Scopes above the call stack
    vim.api.nvim_set_current_win(list()[2].win)
    vim.cmd("quit") -- the call stack
    vim.api.nvim_set_current_win(list()[1].win)
    vim.cmd("quit") -- the last one
    assert.equals(0, #list())
    dapper.open()
    assert.same({ "scopes" }, views())
  end)

  it("map no q, and no g (Vim's own: gg, gt, g? ...)", function()
    dapper.open()
    for _, p in ipairs(list()) do
      vim.api.nvim_set_current_win(p.win)
      assert.equals("", vim.fn.maparg("q", "n"))
      assert.equals("", vim.fn.maparg("g", "n"))
      assert.truthy(vim.fn.maparg("g?", "n") ~= "")
    end
    for _, name in ipairs({ "memory", "disassembly" }) do
      require("dapper.tabs").open(name)
      assert.equals("", vim.fn.maparg("q", "n"), name)
      assert.equals("", vim.fn.maparg("g", "n"), name)
      assert.equals("", vim.fn.maparg("b", "n"), name)
      assert.truthy(vim.fn.maparg("g?", "n") ~= "", name)
      vim.cmd("tabclose")
    end
  end)

  it("open in a code tab page, never in Memory's or Disassembly's", function()
    require("dapper.tabs").open("memory")
    dapper.open()
    assert.equals(0, #list(), "none in the Memory tab page")
    vim.cmd("tabfirst")
    assert.equals(2, #list(), "they open in the code tab page entered")
    vim.cmd("tablast | tabclose")
  end)

  it("stay out of a Memory or Disassembly tab page opened while they wait to open", function()
    require("dapper.tabs").open("memory")
    dapper.open() -- (they wait for a code tab page)
    require("dapper.tabs").open("disassembly")
    assert.equals(0, #list(), "none in the Disassembly tab page")
    vim.cmd("tabfirst")
    assert.equals(2, #list(), "they open in the code tab page entered")
    vim.cmd("tablast | tabclose | tablast | tabclose")
  end)

  it("make a code window with a code window's options, not a pane's", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main(void) { return 0; }" }, file)
    vim.cmd("edit " .. file)
    local buf = vim.api.nvim_get_current_buf()
    dapper.open()
    vim.api.nvim_set_current_win(list()[1].win)
    vim.cmd("only") -- (no code window left)
    local win = require("dapper.util").show_location(buf, 1, 1, false)
    assert.equals("", vim.wo[win].winbar)
    assert.are_not.equal("no", vim.wo[win].signcolumn) -- (a pane's: the signs hidden)
    assert.is_false(vim.wo[win].winfixwidth)
    assert.is_false(vim.wo[win].winfixbuf)
  end)

  it("switch views with the letters from the REPL and Program I/O panes too", function()
    dapper.open()
    local top = list()[1].win
    press(top, "O")
    assert.equals("O", vim.fn.maparg("S", "n") ~= "" and "O" or "none")
    press(top, "S")
    assert.equals("scopes", views()[1])
    press(top, "R")
    press(top, "W")
    assert.equals("watches", views()[1])
  end)

  it("show a view where asked, in the current pane", function()
    dapper.show("repl")
    assert.equals("dap-repl", vim.bo[vim.api.nvim_win_get_buf(list()[1].win)].filetype)
  end)

  it("never put their keys on a file", function()
    local file = vim.fn.tempname() .. ".c"
    vim.fn.writefile({ "int main(void) { return 0; }" }, file)
    vim.cmd("edit " .. file)
    dapper.open()
    assert.equals("", vim.fn.maparg("q", "n"))
    assert.equals("", vim.fn.maparg("W", "n"))
  end)

  it("shorten their tabs when narrow", function()
    dapper.setup({ size = 36 })
    dapper.open()
    local bar = vim.wo[list()[1].win].winbar
    assert.truthy(bar:find("#DapperTab# B ", 1, true), bar) -- (the others: their key)
    assert.is_nil(bar:find("Watches", 1, true)) -- (the one shown: shorter)
    assert.truthy(bar:find("#DapperTabSelected# Watch ", 1, true), bar)
    dapper.setup({})
  end)

  it("open again as they were, after :tabclose or :only closed them all at once", function()
    vim.cmd("tabnew")
    dapper.open()
    vim.cmd("tabclose")
    vim.wait(50)
    dapper.open()
    assert.same({ "watches", "stack" }, views())
  end)

  it("leave a plain window when they are the last ones and close", function()
    dapper.open()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if not vim.wo[win].winbar:find("DapperTab", 1, true) then
        vim.api.nvim_win_close(win, true)
      end
    end
    panes.close()
    assert.same({}, views())
    local win = vim.api.nvim_get_current_win()
    assert.equals("", vim.wo[win].winbar)
    assert.is_false(vim.wo[win].winfixbuf)
  end)

  it("make a view's buffer again after :bd in its pane", function()
    dapper.open()
    vim.api.nvim_set_current_win(list()[1].win)
    vim.cmd("bdelete")
    dapper.show("watches")
    local buf = vim.fn.bufnr("dapper://watches")
    assert.is_true(vim.api.nvim_buf_is_loaded(buf))
    assert.truthy(vim.fn.maparg("i", "n", false, true).buffer == 1 or #vim.fn.win_findbuf(buf) > 0)
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(buf)[1])
    assert.equals(1, vim.fn.maparg("i", "n", false, true).buffer)
  end)

  it("take the new views' keys after setup() again", function()
    dapper.open()
    local buf = vim.api.nvim_win_get_buf(list()[1].win)
    dapper.setup({ views = { "watches", "stack" } })
    dapper.show("watches")
    vim.api.nvim_set_current_win(list()[1].win)
    assert.equals("", vim.fn.maparg("S", "n")) -- (Scopes is no view any more)
    assert.truthy(vim.fn.maparg("C", "n") ~= "" or vim.fn.maparg("C", "n", false, true).callback)
    assert.equals(buf, vim.api.nvim_get_current_buf())
    dapper.setup({})
  end)

  it("leave nvim-dap's REPL window to it (dap.repl.toggle() opens its own)", function()
    dapper.open()
    press(list()[1].win, "R")
    press(list()[1].win, "W")
    local ok, err = pcall(require("dap").repl.toggle)
    assert.is_true(ok, err)
    require("dap").repl.close({ mode = "toggle" })
  end)
end)
