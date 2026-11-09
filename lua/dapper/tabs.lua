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
    local buf = views.buffer(name)
    M.opening = true -- (its TabEnter comes before it is marked dapper's)
    vim.cmd.sbuffer({ buf, mods = { tab = 1 } })
    M.opening = false
    vim.t.dapper_view = name
    local win = api.nvim_get_current_win()
    -- (the window copies the one it was opened from: a pane's bar, its fixed size, ...)
    for option, value in pairs(vim.tbl_extend("force", views.WINDOW_OPTIONS, {
      winbar = "",
      winfixwidth = false,
      winfixheight = false,
      winfixbuf = true,
    })) do
      vim.wo[win][option] = value
    end
    vim.keymap.set("n", "g?", function()
      require("dapper.help").show(name)
    end, { buffer = buf, nowait = true, desc = "dapper: the keys" })
  end
  views.refresh(name)
end

return M
