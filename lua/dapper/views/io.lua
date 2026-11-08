--- Program I/O: the terminal of the program being debugged (type in it to give it input).

local M = { label = "Program I/O", short = "I/O", key = "O" }

local placeholder

--- the buffer to show in `win`
function M.buffer()
  local buf = require("dapper.io").buffer()
  if buf then
    require("dapper.io").unseen = false
    return buf
  end
  if not (placeholder and vim.api.nvim_buf_is_valid(placeholder)) then
    placeholder = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(
      placeholder,
      0,
      -1,
      false,
      { "The program's input and output show here when you debug." }
    )
    vim.bo[placeholder].modifiable = false
  end
  return placeholder
end

return M
