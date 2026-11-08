-- nvim --headless --noplugin -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests"
-- (scripts/test.sh clones plenary.nvim and nvim-dap into tests/deps/, unless $PLENARY_PATH and
-- $DAP_PATH point at them)

vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.columns, vim.o.lines = 200, 50

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

for _, dep in ipairs({ { "PLENARY_PATH", "plenary.nvim" }, { "DAP_PATH", "nvim-dap" } }) do
  local path = vim.env[dep[1]] or (root .. "/tests/deps/" .. dep[2])
  if vim.fn.isdirectory(path) == 0 then
    error(dep[2] .. " not found at " .. path .. " -- run scripts/test.sh, or set $" .. dep[1])
  end
  vim.opt.runtimepath:prepend(path)
end

vim.cmd("runtime plugin/plenary.vim")
vim.cmd("runtime plugin/dapper.lua")
vim.cmd("filetype on")
