--- The panes: windows in a column (config.position), each showing one view, with the views as
--- tabs in its window bar. In a pane: a view's key shows it, ]v / [v the next / previous one,
--- <C-w>s / <C-w>v split the pane (below / to the side), :q closes it, g? lists the keys.

local config = require("dapper.config")
local views = require("dapper.views")

local M = {}

local api = vim.api

---@class dapper.Pane
---@field win integer
---@field view string

local panes = {} ---@type dapper.Pane[] the open ones, in the order they were made
local layout -- what they were when last closed: opened again like that
local splitting = false -- a split of ours is being made
local fixing = false -- a split not of ours is being redone
local closing = false -- we are closing them all (their WinClosed: not a :q)
local target -- the column's width (its height, "below"): kept when windows open and close
local snapshot -- the layout before the panes closed in this tick (:only, :tabclose close several)

local function open_panes()
  panes = vim.tbl_filter(function(p)
    return api.nvim_win_is_valid(p.win)
  end, panes)
  return panes
end

function M.is_open()
  return #open_panes() > 0
end

local function pane_of(win)
  for _, p in ipairs(open_panes()) do
    if p.win == win then
      return p
    end
  end
end

--- whether a pane shows view `name`
function M.shows(name)
  return vim.iter(open_panes()):any(function(p)
    return p.view == name
  end)
end

-- A tab: the key of its view ("W": what shows it), but the shown view's, its name ("Watches";
-- narrower: its short name, then its key too). Returns its text, for the bar, and its width.
local function tab(name, form, current)
  local view = views.get(name)
  local text = not current and view.key or form == 1 and view.label or form == 2 and (view.short or view.label) or view.key
  local bar = ("%%#%s# %s "):format(current and "DapperTabSelected" or "DapperTab", text)
  local width = vim.fn.strdisplaywidth(text) + 2
  if name == "io" and require("dapper.io").unseen then -- (the program printed, unseen)
    bar, width = bar .. "• ", width + 2
  end
  return bar, width
end

function M.refresh_bars()
  local names = config.values.views
  for _, p in ipairs(open_panes()) do
    local controls = config.values.controls and require("dapper.controls").bar() or ""
    local width = api.nvim_win_get_width(p.win) - 4 - api.nvim_eval_statusline(controls, {}).width -- (and g?)
    local form = 3
    for try = 1, 2 do
      local total = 0
      for _, name in ipairs(names) do
        total = total + select(2, tab(name, try, name == p.view))
      end
      if total <= width then
        form = try
        break
      end
    end
    local parts = {}
    for _, name in ipairs(names) do
      table.insert(parts, (tab(name, form, name == p.view)))
    end
    local bar = table.concat(parts) .. "%#DapperTabFill#%=" .. controls .. "%#DapperHint# g? " -- (the keys, at hand)
    vim.wo[p.win].winbar = bar
  end
end

local show

--- The keys every pane has, on buffer `buf`; they act on the pane they are pressed in. In a
--- window that is no pane (the REPL or a program's terminal shown elsewhere), they do what they do
--- in Vim.
local function pane_keys(buf)
  local names = config.values.views
  local made = vim.b[buf].dapper_pane_keys -- (the views they were made for)
  if vim.bo[buf].buftype == "" or vim.deep_equal(made, names) then
    return -- (never on a file: they edit text there)
  end
  for _, name in ipairs(made or {}) do -- (setup() again, other views: their keys go)
    pcall(vim.keymap.del, "n", views.get(name).key, { buffer = buf })
  end
  vim.b[buf].dapper_pane_keys = names
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, function()
      local p = pane_of(api.nvim_get_current_win())
      if p then
        fn(p)
      else -- (not a pane: Vim's own)
        api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
      end
    end, { buffer = buf, nowait = true, desc = "dapper: " .. desc })
  end
  for _, name in ipairs(names) do
    map(views.get(name).key, function(p)
      show(p, name)
    end, views.get(name).label)
  end
  local function step(by)
    return function(p)
      local all = config.values.views
      local i = vim.fn.index(all, p.view) + 1
      show(p, all[(i - 1 + by) % #all + 1])
    end
  end
  map("]v", step(1), "next view")
  map("[v", step(-1), "previous view")
  map("<C-w>s", function(p)
    M.split(p, "below")
  end, "split the pane (below)")
  map("<C-w>v", function(p)
    M.split(p, "right")
  end, "split the pane (to the side)")
  map("g?", function(p)
    require("dapper.help").show(p.view)
  end, "the keys")
end

--- shows view `name` in pane `p`
show = function(p, name)
  p.view = name
  -- the panes keep 'winfixbuf', so that nvim-dap never shows code in them; it is lifted only
  -- here, to switch views
  vim.wo[p.win].winfixbuf = false
  local ok, buf, drawn = pcall(views.buffer, name)
  if ok and buf then
    pcall(api.nvim_win_set_buf, p.win, buf)
  end
  vim.wo[p.win].winfixbuf = true
  if not ok then
    require("dapper.util").notify("dapper: " .. tostring(buf), vim.log.levels.WARN)
    return
  end
  pane_keys(api.nvim_win_get_buf(p.win))
  if drawn then
    views.refresh(name)
  end
  M.refresh_bars()
end

--- shows view `name` again in the panes showing it (its buffer changed)
function M.reshow(name)
  for _, p in ipairs(open_panes()) do
    if p.view == name then
      show(p, name)
    end
  end
end


--- a new pane from window `from`: "first" (the column), "below" or "right" of it (with
--- `size` lines or columns; default: half of `from`)
local function new_pane(from, split, view, at, size)
  local prev = api.nvim_get_current_win()
  local position = config.values.position
  -- the panes keep the column's size (winfixwidth, or winfixheight "below") when other windows
  -- open, close or are made equal; splits are given their size, so nothing else is resized
  local fix = position == "below" and "winfixheight" or "winfixwidth"
  if split == "first" then
    local total = position == "below" and vim.o.lines or vim.o.columns
    local n = config.values.size < 1 and math.floor(total * config.values.size) or config.values.size
    vim.cmd((position == "left" and "topleft " or "botright ") .. n .. (position == "below" and "split" or "vsplit"))
  else
    api.nvim_set_current_win(from)
    vim.wo[from][fix] = false -- (a pane that keeps its size, split, takes the new one's from the code)
    splitting = true
    local ok, err
    if split == "right" then
      ok, err = pcall(vim.cmd, "belowright " .. (size or math.floor(api.nvim_win_get_width(from) / 2)) .. "vsplit")
    else
      ok, err = pcall(vim.cmd, "belowright " .. (size or math.floor(api.nvim_win_get_height(from) / 2)) .. "split")
    end
    splitting = false
    vim.wo[from][fix] = true
    if not ok or api.nvim_get_current_win() == from then -- (no room: E36)
      api.nvim_set_current_win(prev)
      require("dapper.util").notify("Cannot split the pane: " .. tostring(err), vim.log.levels.WARN)
      return nil
    end
  end
  local p = { win = api.nvim_get_current_win(), view = view }
  for option, value in pairs(views.WINDOW_OPTIONS) do
    vim.wo[p.win][option] = value
  end
  vim.wo[p.win][fix] = true
  api.nvim_set_current_win(prev)
  table.insert(panes, at or (#panes + 1), p)
  show(p, view)
  return p
end

-- How the panes are arranged, from the windows' layout (|winlayout()|): a pane is { view },
-- the others { kind = "row"|"col", children }. Restored as it was, nesting and all.
local function capture(without)
  local views_of = {}
  local tab
  for _, p in ipairs(open_panes()) do
    if p.win ~= without then
      views_of[p.win] = p.view
      tab = tab or api.nvim_win_get_tabpage(p.win)
    end
  end
  if not tab then
    return nil
  end
  local function walk(node)
    if node[1] == "leaf" then
      return views_of[node[2]] and { view = views_of[node[2]] } or nil
    end
    local children = {}
    for _, child in ipairs(node[2]) do
      table.insert(children, walk(child))
    end
    if #children <= 1 then
      return children[1]
    end
    return { kind = node[1], children = children }
  end
  -- (the panes' own tab page: closing them from the Memory tab page keeps their layout)
  return walk(vim.fn.winlayout(api.nvim_tabpage_get_number(tab)))
end

local function first_view(node)
  return node.view or first_view(node.children[1])
end

-- fills pane window `win` with `node`: its view, or its children, splitting it evenly
local function build(node, win)
  if node.view then
    local p = pane_of(win)
    if p and p.view ~= node.view then
      show(p, node.view)
    end
    return
  end
  local row = node.kind == "row"
  local total = row and api.nvim_win_get_width(win) or api.nvim_win_get_height(win)
  local n, wins = #node.children, { win }
  for i = 2, n do
    local size = math.floor(total * (n - i + 1) / n) -- (the rest, for the panes after it)
    local p = new_pane(wins[i - 1], row and "right" or "below", first_view(node.children[i]), nil, size)
    if not p then
      break -- (no room for the rest)
    end
    wins[i] = p.win
  end
  for i, child in ipairs(node.children) do
    if wins[i] then
      build(child, wins[i])
    end
  end
end

-- the column's size: from the first pane's edge to the last one's
local function column_size()
  local below = config.values.position == "below"
  local first, last
  for _, p in ipairs(open_panes()) do
    local pos = api.nvim_win_get_position(p.win)
    local start = below and pos[1] or pos[2]
    local stop = start + (below and api.nvim_win_get_height(p.win) or api.nvim_win_get_width(p.win))
    first, last = math.min(first or start, start), math.max(last or stop, stop)
  end
  return first and (last - first), first, last
end

local function remember_size()
  target = column_size()
end

-- gives the column its size back, from the window next to it (the code's)
local function restore_size()
  local size, first, last = column_size()
  if not (target and size) or size == target then
    return
  end
  local position = config.values.position
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if not pane_of(win) and api.nvim_win_get_config(win).relative == "" then
      local pos = api.nvim_win_get_position(win)
      local width, height = api.nvim_win_get_width(win), api.nvim_win_get_height(win)
      if position == "right" and pos[2] + width + 1 == first then
        return api.nvim_win_set_width(win, width + size - target)
      elseif position == "left" and pos[2] == last + 1 then
        return api.nvim_win_set_width(win, width + size - target)
      elseif position == "below" and pos[1] + height + 1 >= first - 1 and pos[1] + height <= first then
        return api.nvim_win_set_height(win, height + size - target)
      end
    end
  end
end

--- a window was made (WinNew): a split of a pane that is not ours (:vsplit, :split, ...) is
--- redone as ours (a pane, the column's size kept)
function M.on_new_window()
  local new = api.nvim_get_current_win()
  local from = vim.fn.win_getid(vim.fn.winnr("#"))
  local p = not splitting and pane_of(from)
  if not p or api.nvim_win_get_config(new).relative ~= "" then
    return
  end
  fixing = true
  vim.schedule(function()
    fixing = false
    if not (api.nvim_win_is_valid(new) and api.nvim_win_is_valid(from)) then
      return
    end
    local plain = api.nvim_win_get_buf(new) == api.nvim_win_get_buf(from) -- (not :split file)
    local how = api.nvim_win_get_position(new)[1] == api.nvim_win_get_position(from)[1] and "right" or "below"
    if plain then
      api.nvim_win_close(new, true)
    else
      require("dapper.util").plain_window(new) -- (:split file: a code window, not a pane's look)
    end
    restore_size()
    if plain then
      M.split(p, how)
    end
  end)
end

--- windows were resized (WinResized): the column's new size is kept, if you resized it
function M.on_resized()
  if not (splitting or fixing or closing) and M.is_open() then
    remember_size()
    layout = capture() or layout
  end
end

--- a window is closing (WinClosed): a pane closed with :q, so the panes open again as they were
--- left (the last one: as it was)
function M.on_closed(win)
  if closing or not pane_of(win) then
    return
  end
  if not snapshot then -- (several closed at once, all of them: they open again as they were)
    snapshot = capture()
    local mine = snapshot
    vim.schedule(function()
      if snapshot == mine then
        layout = not M.is_open() and mine or layout
        snapshot = nil
      end
    end)
  end
  layout = (#open_panes() > 1 and capture(win)) or capture() or layout
end

--- splits pane `p`; the new one shows the first view no pane shows
function M.split(p, how)
  local shown = {}
  for _, other in ipairs(open_panes()) do
    shown[other.view] = true
  end
  local view = vim.iter(config.values.views):find(function(v)
    return not shown[v]
  end) or p.view
  local index = #panes
  for i, other in ipairs(panes) do
    if other == p then
      index = i
    end
  end
  if not new_pane(p.win, how, view, index + 1) then
    return
  end
  remember_size()
  M.refresh_bars()
end

--- opens the panes as they were last closed (at first: config.layout)
local pending -- asked to open in a tab page of dapper's (Memory, Disassembly): done in the next
-- tab page entered that is not one

function M.open()
  if M.is_open() then
    return
  end
  if vim.t.dapper_view then
    pending = true
    return
  end
  pending, snapshot = false, nil
  if layout then -- as they were left
    build(layout, new_pane(nil, "first", first_view(layout)).win)
  else -- config.layout: each split from the one before
    local previous
    for i, saved in ipairs(config.values.layout) do
      previous = new_pane(previous and previous.win, i == 1 and "first" or (saved.split or "below"), saved.view)
        or previous
    end
  end
  remember_size()
  M.refresh_bars()
end

function M.close()
  local open = open_panes()
  if #open == 0 then
    return
  end
  layout = capture() or layout
  closing = true
  -- (the panes are all the windows left: one becomes a plain window, as Neovim needs one)
  local tab = api.nvim_win_get_tabpage(open[1].win)
  local others = vim.tbl_filter(function(win)
    return not pane_of(win) and api.nvim_win_get_config(win).relative == ""
  end, api.nvim_tabpage_list_wins(tab))
  if #others == 0 and #api.nvim_list_tabpages() == 1 then
    local last = table.remove(open)
    require("dapper.util").plain_window(last.win)
    api.nvim_win_set_buf(last.win, api.nvim_create_buf(true, false))
  end
  for _, p in ipairs(open) do
    pcall(api.nvim_win_close, p.win, true)
  end
  closing = false
  panes = {}
end

--- setup() again: the panes open as config.layout says (how they were left is forgotten), and
--- the open ones take the new views' keys (one showing a view no longer there, the first)
function M.forget()
  layout, snapshot = nil, nil
  for _, p in ipairs(open_panes()) do
    show(p, vim.tbl_contains(config.values.views, p.view) and p.view or config.values.views[1])
  end
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

--- shows view `name` in a pane: the one showing it, else the current pane, else the first
--- (opening them if they are closed)
function M.show(name)
  M.open()
  if not M.is_open() then
    return nil -- (in a tab page of dapper's: they open in the next code one entered)
  end
  for _, p in ipairs(open_panes()) do
    if p.view == name then
      return p
    end
  end
  local p = pane_of(api.nvim_get_current_win()) or open_panes()[1]
  show(p, name)
  return p
end

--- the panes of another tab: closed there, opened here (follow_tab)
function M.follow()
  local open = open_panes()
  if vim.t.dapper_view or require("dapper.tabs").opening then
    return -- (never into the Memory or Disassembly tab page)
  end
  if #open > 0 and api.nvim_win_get_tabpage(open[1].win) ~= api.nvim_get_current_tabpage() then
    M.close()
    M.open()
  end
end

--- a tab page entered (TabEnter): the panes asked for in a tab page of dapper's open now
function M.on_tab_entered()
  if pending and not (vim.t.dapper_view or require("dapper.tabs").opening) then
    M.open()
  end
end

return M
