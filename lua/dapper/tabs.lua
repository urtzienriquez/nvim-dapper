--- Views in tab pages of their own (Memory, Disassembly): the code's tab page stays as it is.

local views = require("dapper.views")

local M = {}

local api = vim.api

--- the tab page showing view `name`, or nil
function M.find(name)
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if vim.t[tab].dapper_view == name then
      return tab
    end
  end
end

--- goes to the tab page of view `name` (made if there is none) and draws it
function M.open(name)
  local tab = M.find(name)
  if tab then
    api.nvim_set_current_tabpage(tab)
  else
    vim.cmd("tabnew")
    vim.t.dapper_view = name
    local win = api.nvim_get_current_win()
    local scratch = api.nvim_get_current_buf()
    local buf = views.buffer(name, win)
    api.nvim_win_set_buf(win, buf)
    if api.nvim_buf_is_valid(scratch) and scratch ~= buf then
      pcall(api.nvim_buf_delete, scratch, { force = true })
    end
    for option, value in pairs({
      number = false,
      relativenumber = false,
      signcolumn = "no",
      foldcolumn = "0",
      spell = false,
      list = false,
      wrap = false,
      cursorline = true,
      winfixbuf = true,
    }) do
      vim.wo[win][option] = value
    end
    vim.keymap.set("n", "g?", function()
      require("dapper.help").show(name)
    end, { buffer = buf, nowait = true, desc = "dapper: the keys" })
  end
  views.refresh(name)
end

return M
