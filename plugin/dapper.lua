-- Only the :Dapper command is defined here; everything else loads on use (or on setup()).

if vim.g.loaded_dapper then
  return
end
vim.g.loaded_dapper = 1

local SUBCOMMANDS = {
  "toggle",
  "open",
  "close",
  "show",
  "watch",
  "hover",
  "memory",
  "disassembly",
  "break",
  "break-change",
  "condition",
  "log",
  "pin",
  "jump",
  "virtual-text",
}
local VIEWS = { "watches", "scopes", "exceptions", "breakpoints", "stack", "threads", "sessions", "repl", "io" }
local TAKE_EXPRESSIONS = { watch = true, hover = true, memory = true, ["break-change"] = true, pin = true }

vim.api.nvim_create_user_command("Dapper", function(o)
  local dapper = require("dapper")
  local sub, rest = o.args:match("^%s*(%S*)%s*(.-)%s*$")
  local mode = vim.api.nvim_get_mode().mode
  if rest == "" and o.range > 0 and not mode:match("^[vV\22]") then -- :'<,'>Dapper watch
    local lines = vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.visualmode() })
    rest = vim.trim(table.concat(lines, "\n"))
  end
  local arg = rest ~= "" and rest or nil
  if sub == "" then
    dapper.palette()
  elseif sub == "toggle" then
    dapper.toggle()
  elseif sub == "open" then
    dapper.open()
  elseif sub == "close" then
    dapper.close()
  elseif sub == "show" then
    dapper.show(rest)
  elseif sub == "watch" then
    dapper.watch(arg)
  elseif sub == "hover" then
    dapper.hover(arg)
  elseif sub == "memory" then
    dapper.memory(arg)
  elseif sub == "disassembly" then
    dapper.disassembly(arg)
  elseif sub == "break" then
    if arg then
      dapper.break_on(arg)
    else
      vim.notify(":Dapper break {function}", vim.log.levels.WARN)
    end
  elseif sub == "break-change" then
    dapper.break_on_change(arg)
  elseif sub == "condition" then
    dapper.conditional_breakpoint()
  elseif sub == "log" then
    dapper.log_point()
  elseif sub == "pin" then
    dapper.pin(arg)
  elseif sub == "jump" then
    dapper.jump()
  elseif sub == "virtual-text" then
    dapper.toggle_virtual_text()
  else
    vim.notify("Unknown :Dapper subcommand: " .. sub .. " (:Dapper alone lists the actions)", vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  range = true, -- (from a visual selection: :Dapper watch / hover / pin act on it)
  complete = function(arglead, cmdline)
    local words = vim.split(cmdline:sub(1, #cmdline - #arglead), "%s+", { trimempty = true })
    if #words == 1 then
      return vim.tbl_filter(function(item)
        return vim.startswith(item, arglead)
      end, SUBCOMMANDS)
    elseif words[2] == "show" and #words == 2 then
      return vim.tbl_filter(function(item)
        return vim.startswith(item, arglead)
      end, VIEWS)
    elseif words[2] == "break" then
      return require("dapper.complete").functions(arglead)
    elseif TAKE_EXPRESSIONS[words[2]] then
      return require("dapper.complete").expressions(arglead)
    end
    return {}
  end,
  desc = "dapper: alone, the actions to pick from; or toggle, show {view}, watch, hover, memory, disassembly, break {function}, break-change, pin, jump, ...",
})
