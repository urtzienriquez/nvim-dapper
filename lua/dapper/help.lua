--- g?: the keys of a pane and of its view, in a float.

local config = require("dapper.config")
local views = require("dapper.views")

local M = {}

--- the keys `keys` ({ lhs, description, ... }), titled `title`
local function listing(title, keys)
  local lines = { title, "" }
  for _, key in ipairs(keys or {}) do
    table.insert(lines, ("  %-8s %s"):format(key[1], key[2]))
  end
  return lines
end

--- g? in the hover float, or anything else with keys of its own
function M.show_keys(title, keys)
  M.float(listing(title, keys))
end

function M.show(name)
  local view = views.get(name)
  local lines = listing(view.label, view.keys)
  if view.keys then
    table.insert(lines, "")
  end
  if vim.t.dapper_view then -- (a tab page's view: not a pane; closed with :q, as any window)
    table.remove(lines)
    return M.float(lines)
  end
  table.insert(lines, "Every pane")
  for _, other in ipairs(config.values.views) do
    table.insert(lines, ("  %-8s %s"):format(views.get(other).key, views.get(other).label))
  end
  for _, key in ipairs({
    { "]v [v", "next / previous view" },
    { "<C-w>s", "split the pane (below)" },
    { "<C-w>v", "split the pane (to the side)" },
    { ":q", "close the pane (it is a window)" },
  }) do
    table.insert(lines, ("  %-8s %s"):format(key[1], key[2]))
  end
  M.float(lines)
end

function M.float(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_extmark(
    buf,
    require("dapper.canvas").ns,
    0,
    0,
    { end_col = #lines[1], hl_group = "DapperTitle" }
  )
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width + 2,
    height = #lines,
    style = "minimal",
    -- (a title needs a border: 'winborder' gives it, if set, in recent versions)
    border = (vim.fn.exists("+winborder") == 1 and vim.o.winborder ~= "") and vim.o.winborder or "rounded",
    title = " dapper ",
  })
  for _, lhs in ipairs({ "q", "<Esc>", "g?" }) do -- (and :q; it closes when left too)
    vim.keymap.set("n", lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
  vim.w[win].dapper_help = true -- (the hover float stays open under it)
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = vim.schedule_wrap(function()
      pcall(vim.api.nvim_win_close, win, true)
    end),
  })
end

return M
