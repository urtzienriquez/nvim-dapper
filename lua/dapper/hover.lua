--- The value of an expression (under the cursor, or selected) in a float, as a tree. Called again,
--- the cursor goes into it (<CR> expands, s sets a value, q closes it); it closes when the cursor
--- moves on.

local canvas = require("dapper.canvas")
local tree = require("dapper.tree")
local util = require("dapper.util")

local M = {}

local api = vim.api
local float -- { win, buf, expr, tree }

local function close()
  if float and api.nvim_win_is_valid(float.win) then
    api.nvim_win_close(float.win, true)
  end
  float = nil
end

local function draw()
  util.run(function()
    local session = require("dap").session()
    if not (float and session) then
      return
    end
    local c = canvas.new()
    local mine = float
    local result, err = util.evaluate(session, float.expr, "hover")
    if float ~= mine then
      return -- (closed, or another, while it was asked)
    end
    if not result then
      c:add({ { err, "DapperError" } })
    else
      float.tree.expanded["hover"] = float.tree.expanded["hover"] ~= false
      local var =
        { name = float.expr, value = result.result, type = result.type, variablesReference = result.variablesReference }
      float.tree:variable(c, session, var, "hover", nil, 0)
    end
    if not (float and api.nvim_win_is_valid(float.win)) then
      return
    end
    c:write(float.buf)
    local width = 0
    for _, line in ipairs(c.lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    api.nvim_win_set_config(float.win, {
      width = math.max(math.min(width + 1, math.floor(vim.o.columns * 0.8)), 10),
      height = math.max(math.min(#c.lines, math.floor(vim.o.lines * 0.6)), 1),
    })
  end)
end

function M.show(expr)
  if float and api.nvim_win_is_valid(float.win) then
    api.nvim_set_current_win(float.win) -- (a second time: into it, as Neovim's own hover)
    return
  end
  expr = expr or util.expression()
  if not require("dap").session() then
    return util.notify("Not debugging")
  elseif expr == "" then
    return
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "dapper"
  local win = api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = 20,
    height = 1,
    style = "minimal",
  })
  float = { win = win, buf = buf, expr = expr, tree = tree.new() }
  for _, key in ipairs(tree.keys(draw)) do
    vim.keymap.set("n", key[1], function()
      key[3](canvas.item())
    end, { buffer = buf, nowait = true, desc = "dapper hover: " .. key[2] })
  end
  vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "dapper hover: close" })
  vim.keymap.set("n", "g?", function()
    require("dapper.help").show_keys("Hover (q closes it)", tree.keys(draw))
  end, { buffer = buf, nowait = true, desc = "dapper hover: the keys" })
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    callback = vim.schedule_wrap(function()
      if not vim.w[api.nvim_get_current_win()].dapper_help then -- (its help, g?: it stays)
        close()
        return true
      end
    end),
  })
  -- like an LSP hover: it closes when the cursor moves on, unless it went into it
  local source = api.nvim_get_current_buf()
  api.nvim_create_autocmd({ "CursorMoved", "BufLeave", "InsertEnter" }, {
    buffer = source,
    once = true,
    callback = function()
      vim.schedule(function()
        if float and api.nvim_get_current_win() ~= float.win then
          close()
        end
      end)
    end,
  })
  draw()
end

return M
