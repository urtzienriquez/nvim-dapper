-- Only the :Dapper command is defined here; everything else loads on use (or on setup()).

if vim.g.loaded_dapper then
  return
end
vim.g.loaded_dapper = 1

-- subcommand -> the function of require("dapper") it calls (with the argument, if any), and what
-- its argument completes to
local SUBCOMMANDS = {
  toggle = { "toggle" },
  open = { "open" },
  close = { "close" },
  show = { "show", complete = "views" },
  watch = { "watch", complete = "expressions" },
  hover = { "hover", complete = "expressions" },
  memory = { "memory", complete = "expressions" },
  disassembly = { "disassembly", complete = "functions expressions" },
  ["break"] = { "break_on", complete = "functions", usage = ":Dapper break {function}" },
  ["break-change"] = { "break_on_change", complete = "expressions" },
  condition = { "conditional_breakpoint" },
  log = { "log_point" },
  pin = { "pin", complete = "expressions" },
  jump = { "jump" },
  ["virtual-text"] = { "toggle_virtual_text" },
}

local function matching(list, lead)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, lead)
  end, list)
end

vim.api.nvim_create_user_command("Dapper", function(o)
  local sub, rest = o.args:match("^%s*(%S*)%s*(.-)%s*$")
  local mode = vim.api.nvim_get_mode().mode
  if rest == "" and o.range > 0 and not mode:match("^[vV\22]") then -- :'<,'>Dapper watch
    local lines = vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.visualmode() })
    rest = vim.trim(table.concat(lines, "\n"))
  end
  local dapper = require("dapper")
  if sub == "" then
    return dapper.palette()
  end
  local command = SUBCOMMANDS[sub]
  if not command then
    return vim.notify("Unknown :Dapper subcommand: " .. sub .. " (:Dapper alone lists the actions)", vim.log.levels.ERROR)
  elseif command.usage and rest == "" then
    return vim.notify(command.usage, vim.log.levels.WARN)
  end
  dapper[command[1]](rest ~= "" and rest or nil)
end, {
  nargs = "*",
  range = true, -- (from a visual selection: :Dapper watch / hover / pin act on it)
  complete = function(lead, cmdline)
    local words = vim.split(cmdline:sub(1, #cmdline - #lead), "%s+", { trimempty = true })
    if #words == 1 then
      local names = vim.tbl_keys(SUBCOMMANDS)
      table.sort(names)
      return matching(names, lead)
    end
    local kinds = SUBCOMMANDS[words[2]] and SUBCOMMANDS[words[2]].complete or ""
    local items = {}
    if kinds:find("views") and #words == 2 then
      items = matching(require("dapper.config").values.views, lead)
    end
    if kinds:find("functions") then
      vim.list_extend(items, require("dapper.complete").functions(lead))
    end
    if kinds:find("expressions") then
      vim.list_extend(items, require("dapper.complete").expressions(lead))
    end
    return items
  end,
  desc = "dapper: alone, the actions to pick from; or toggle, show {view}, watch, hover, memory, disassembly, break {function}, break-change, pin, jump, ...",
})
