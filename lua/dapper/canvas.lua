--- Drawing a view: lines made of highlighted chunks, each line maybe with the item it shows
--- (what the keys act on). Written to the buffer at once, when done.

local M = {}
M.__index = M

local ns = vim.api.nvim_create_namespace("dapper")
M.ns = ns

function M.new()
  return setmetatable({ lines = {}, marks = {}, items = {}, extras = {} }, M)
end

--- Adds a line: chunks is a string, or a list of { text, hl? }; item is what keys on it act on.
--- opts: virt (chunks shown after the line's end), line_hl (a highlight for the whole line).
function M:add(chunks, item, opts)
  if type(chunks) == "string" then
    chunks = { { chunks } }
  end
  local text, row = "", #self.lines
  for _, chunk in ipairs(chunks) do
    local piece = (chunk[1] or ""):gsub("\n", "\\n")
    if chunk[2] and #piece > 0 then
      local last = self.marks[#self.marks]
      if last and last[1] == row and last[3] == #text and last[4] == chunk[2] then
        last[3] = #text + #piece -- (one mark for a run of the same highlight: Memory's bytes)
      else
        table.insert(self.marks, { row, #text, #text + #piece, chunk[2] })
      end
    end
    text = text .. piece
  end
  table.insert(self.lines, text)
  self.items[row + 1] = item
  if opts then
    self.extras[row] = opts
  end
end

--- A dimmed line: an explanation, or why there is nothing to show.
function M:note(text)
  self:add({ { text, "DapperMuted" } })
end

--- Writes it to buf, keeping the cursor of the windows that show it.
function M:write(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local cursors = {}
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    cursors[win] = vim.api.nvim_win_get_cursor(win)
  end
  -- the same as the last write: nothing written (no flicker, no work), the cursor still placed
  local parts = { table.concat(self.lines, "\n") }
  for _, m in ipairs(self.marks) do
    table.insert(parts, table.concat(m, ","))
  end
  for row, opts in pairs(self.extras) do
    table.insert(parts, row .. vim.inspect(opts))
  end
  local signature = table.concat(parts, "\0")
  local same = M.signatures[buf] == signature
  M.signatures[buf] = signature
  M.items_of[buf] = self.items
  if same then
    self:place_cursor(buf, cursors)
    return
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, self.lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(self.marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  for row, opts in pairs(self.extras) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
      virt_text = opts.virt,
      line_hl_group = opts.line_hl,
      hl_mode = "combine",
    })
  end
  self:place_cursor(buf, cursors)
end

function M:place_cursor(buf, cursors)
  local count = math.max(#self.lines, 1)
  -- (a view may say where the cursor goes: self.cursor = { line, column }; with a
  -- self.cursor_key, only when the key changed since the last write: a new current instruction)
  local move = self.cursor and (self.cursor_key == nil or vim.b[buf].dapper_cursor_key ~= self.cursor_key)
  if self.cursor_key then
    vim.b[buf].dapper_cursor_key = self.cursor_key
  end
  for win, pos in pairs(cursors) do
    local target = move and self.cursor or pos
    pcall(vim.api.nvim_win_set_cursor, win, { math.min(target[1], count), target[2] })
    if move and self.center then -- (self.center: the cursor's line in the middle of the window)
      vim.api.nvim_win_call(win, function()
        vim.cmd("normal! zz")
      end)
    end
  end
end

M.items_of = {} -- buf -> { [line] = item }
M.signatures = {} -- buf -> what was last written to it

--- the item on the cursor's line of the current window
function M.item()
  local buf = vim.api.nvim_get_current_buf()
  return (M.items_of[buf] or {})[vim.api.nvim_win_get_cursor(0)[1]]
end

return M
