--- :checkhealth dapper: what debugging needs, each with the fix when it is missing.

local M = {}

local health = vim.health

local function gdb_version()
  if vim.fn.executable("gdb") ~= 1 then
    return nil
  end
  return tonumber(vim.fn.system({ "gdb", "--version" }):match("GNU gdb [^%d]*(%d+)") or "")
end

--- whether `program` has debug information; nil: no way to tell (no readelf, or not a binary:
--- a Python script, ...)
local function has_debug_info(program)
  if vim.fn.executable("readelf") ~= 1 then
    return nil
  end
  local out = vim.system({ "readelf", "-S", "--wide", program }, { text = true }):wait()
  if out.code ~= 0 then
    return nil
  end
  return out.stdout:find("%.debug_info") ~= nil
end

--- the adapters besides gdb (yours, or a plugin's: rdap's r, ...): each with the filetypes whose
--- configurations use it, and whether its program can be found
local function other_debuggers(dap)
  health.start("dapper: other debuggers")
  local names = vim.tbl_filter(function(name)
    return name ~= "gdb"
  end, vim.tbl_keys(dap.adapters))
  table.sort(names)
  if #names == 0 then
    return health.info("None besides gdb")
  end
  for _, name in ipairs(names) do
    local filetypes = {}
    for ft, configs in pairs(dap.configurations) do
      for _, c in ipairs(type(configs) == "table" and configs or {}) do
        if type(c) == "table" and c.type == name then
          table.insert(filetypes, ft)
          break
        end
      end
    end
    table.sort(filetypes)
    local suffix = #filetypes > 0 and (" (for " .. table.concat(filetypes, ", ") .. ")") or ""
    local adapter = dap.adapters[name]
    if type(adapter) == "function" then
      health.ok(name .. ": a function (it runs when a session starts)" .. suffix)
    elseif type(adapter) == "table" and adapter.type == "executable" and type(adapter.command) == "string" then
      if vim.fn.executable(adapter.command) == 1 then
        health.ok(name .. ": " .. adapter.command .. suffix)
      else
        health.error(name .. ": " .. adapter.command .. " is not on $PATH" .. suffix, {
          "Install it, or give its full path as the adapter's command",
        })
      end
    elseif type(adapter) == "table" and adapter.type == "server" then
      local where = ("%s:%s"):format(adapter.host or "127.0.0.1", tostring(adapter.port or "?"))
      health.ok(name .. ": a server at " .. where .. suffix)
    else
      health.ok(name .. suffix)
    end
    if #filetypes == 0 then
      health.warn(name .. ": no debug configurations use it", {
        "Add some to require('dap').configurations.<filetype> (see :help dap-configuration)",
      })
    end
  end
end

function M.check()
  health.start("dapper")

  if vim.fn.has("nvim-0.12") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.12 or later is needed")
  end

  local ok, dap = pcall(require, "dap")
  if not ok then
    health.error("nvim-dap is not installed", { "Install https://github.com/mfussenegger/nvim-dap" })
    return
  end
  health.ok("nvim-dap is installed")

  if require("dapper").is_set_up() then
    health.ok("setup() called")
  else
    health.warn("setup() not called: dapper does not follow nvim-dap until it is (or :Dapper is used)", {
      "Call require('dapper').setup() in your config",
    })
  end

  health.start("dapper: gdb (C, C++, Fortran, Zig, ...)")
  local version = gdb_version()
  if not version then
    health.warn("gdb is not installed: C and C++ cannot be debugged", { "Install gdb 14 or later" })
  elseif version < 14 then
    health.error(("gdb %d speaks no DAP"):format(version), { "Install gdb 14 or later" })
  elseif version < 16 then
    health.warn(
      ("gdb %d starts the program before the breakpoints are set: some set beforehand can be missed"):format(version),
      { "Install gdb 16 or later (it waits for them)" }
    )
  else
    health.ok(("gdb %d (it speaks DAP)"):format(version))
  end

  local adapter = dap.adapters.gdb
  if adapter == nil then
    health.warn("No gdb adapter in nvim-dap", {
      "Call require('dapper').setup(): it adds one, if you have none",
      "or: require('dap').adapters.gdb = require('dapper').gdb()",
    })
  else
    health.ok(
      "gdb adapter: "
        .. (type(adapter) == "function" and "a function (dapper's gives programs a terminal)" or "your own")
    )
  end

  -- yours, or those of a configuration provider (dapper's, build.nvim's, ...), for a buffer of
  -- each filetype
  local configured = {}
  for _, ft in ipairs({ "c", "cpp" }) do
    local found = dap.configurations[ft] and #dap.configurations[ft] > 0
    if not found and type(dap.providers) == "table" and type(dap.providers.configs) == "table" then
      local buf = vim.api.nvim_create_buf(false, true)
      local eventignore = vim.o.eventignore
      vim.o.eventignore = "all" -- (no FileType: nothing attaches to this buffer)
      vim.bo[buf].filetype = ft
      vim.o.eventignore = eventignore
      for key, provider in pairs(dap.providers.configs) do
        if key ~= "dap.launch.json" then
          local ok, configs = pcall(provider, buf)
          found = found or (ok and type(configs) == "table" and #configs > 0)
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
    end
    if found then
      table.insert(configured, ft)
    end
  end
  if #configured == 0 then
    health.warn("No debug configurations for C or C++: nvim-dap does not know how to start them", {
      "dapper's (Launch, Attach to process) are in its list after setup(), unless configurations = false",
      "build.nvim adds one that builds first, Build & debug",
      "or add yours to require('dap').configurations.c (see :help dap-configuration)",
    })
  else
    health.ok("Debug configurations for " .. table.concat(configured, ", "))
  end

  other_debuggers(dap)

  health.start("dapper: the program being debugged")
  local session = dap.session()
  if not session then
    health.info("Not debugging now (run this while debugging to check the program too)")
    return
  end
  local program = session.config and session.config.program
  if type(program) ~= "string" or program == "" then
    health.info(("The session (%s) has no program file to check"):format(session.config.name or session.id))
    return
  end
  health.info(("Debugging %s (%s)"):format(program, session.config.type or "?"))
  if not vim.uv.fs_stat(program) then
    health.warn(program .. " does not exist")
    return
  end
  local info = has_debug_info(program)
  if info == nil and vim.fn.executable("readelf") == 1 then -- (an R or Python script, ...)
    health.info("Not a compiled program: no debug information to check")
  elseif info == false then
    health.error(program .. " has no debug information: variables and lines cannot be shown", {
      "Build it with -g (and -O0, so that the code follows the lines)",
    })
  elseif info then
    health.ok(program .. " has debug information")
  elseif vim.fn.executable("readelf") ~= 1 then
    health.info("Install readelf to check the program's debug information")
  end
end

return M
