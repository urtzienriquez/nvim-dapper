--- nvim-dap configurations for gdb, in its list (dap.continue()) in the filetypes of the
--- `configurations` option: "Launch" (a program, asked, with its arguments) and "Attach to
--- process". setup() registers provider() as a configuration provider (:help
--- dap-providers-configs), so your own dap.configurations are left alone.

local M = {}

-- what was typed last (offered the next time)
local last = { program = nil, args = "" }

--- "a 'b c' d" -> { "a", "b c", "d" }
function M.split_args(s)
  local out, cur, quote = {}, nil, nil
  for ch in (s or ""):gmatch(".") do
    if quote then
      if ch == quote then
        quote = nil
      else
        cur = cur .. ch
      end
    elseif ch == "'" or ch == '"' then
      quote, cur = ch, cur or ""
    elseif ch:match("%s") then
      if cur then
        table.insert(out, cur)
        cur = nil
      end
    else
      cur = (cur or "") .. ch
    end
  end
  if cur then
    table.insert(out, cur)
  end
  return out
end

local function launch()
  return {
    name = "Launch",
    type = "gdb",
    request = "launch",
    program = function() -- (in nvim-dap's coroutine, as are args: dapper's prompt waits)
      local util = require("dapper.util")
      local path = util.input({
        prompt = "Path to executable: ",
        default = last.program or (vim.fn.getcwd() .. "/"),
        completion = "file",
      })
      path = path and vim.trim(path)
      if not path or path == "" then
        return require("dap").ABORT
      end
      last.program = path
      return vim.fn.fnamemodify(path, ":p")
    end,
    args = function()
      local args = require("dapper.util").input({ prompt = "Arguments: ", default = last.args })
      if not args then
        return require("dap").ABORT
      end
      last.args = vim.trim(args)
      return M.split_args(last.args)
    end,
    cwd = "${workspaceFolder}",
    stopAtBeginningOfMainSubprogram = false,
  }
end

local function attach()
  return {
    name = "Attach to process",
    type = "gdb",
    request = "attach",
    pid = function()
      return require("dap.utils").pick_process()
    end,
  }
end

--- the configurations for buffer `bufnr`: none outside the `configurations` filetypes
function M.provider(bufnr)
  local filetypes = require("dapper.config").values.configurations
  if not filetypes or not vim.tbl_contains(filetypes, vim.bo[bufnr].filetype) then
    return {}
  end
  return { launch(), attach() }
end

return M
