local dapper = require("dapper")

-- the configurations nvim-dap's list gets from dapper, for a new buffer of filetype `ft`
local function configs(ft)
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].filetype = ft
  return require("dap").providers.configs.dapper(buf)
end

-- what config[field]() gives, in a coroutine (as nvim-dap calls it), with these answers typed
local function call(config, field, answers)
  local input = vim.ui.input
  vim.ui.input = function(_, cb)
    cb(table.remove(answers, 1))
  end
  local result
  coroutine.wrap(function()
    result = { config[field]() }
  end)()
  vim.ui.input = input
  return result[1]
end

describe("nvim-dap's list", function()
  after_each(function()
    dapper.setup({})
  end)

  it("has Launch and Attach to process for gdb in C", function()
    dapper.setup({})
    local list = configs("c")
    assert.same({ "Launch", "Attach to process" }, vim.tbl_map(function(c)
      return c.name
    end, list))
    assert.equals("gdb", list[1].type)
  end)

  it("asks Launch's program and arguments, offering the last ones again", function()
    dapper.setup({})
    local launch = configs("cpp")[1]
    assert.equals("/tmp/a.out", call(launch, "program", { "/tmp/a.out" }))
    assert.same({ "in.txt", "two words", "-v" }, call(launch, "args", { "in.txt 'two words' -v" }))
    local default, input = nil, vim.ui.input
    vim.ui.input = function(opts, cb)
      default = opts.default
      cb(nil)
    end
    coroutine.wrap(function()
      assert.equals(require("dap").ABORT, launch.program())
    end)()
    vim.ui.input = input
    assert.equals("/tmp/a.out", default)
  end)

  it("has none elsewhere, or with configurations = false", function()
    dapper.setup({})
    assert.same({}, configs("lua"))
    dapper.setup({ configurations = false })
    assert.same({}, configs("c"))
    dapper.setup({ configurations = { "zig" } })
    assert.same({}, configs("c"))
    assert.equals(2, #configs("zig"))
  end)
end)
