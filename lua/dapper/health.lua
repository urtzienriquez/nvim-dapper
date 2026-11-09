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

  local configured = {}
  for _, ft in ipairs({ "c", "cpp" }) do
    if dap.configurations[ft] and #dap.configurations[ft] > 0 then
      table.insert(configured, ft)
    end
  end
  if #configured == 0 then
    health.warn("No debug configurations for C or C++: nvim-dap does not know how to start them", {
      "Add some to require('dap').configurations.c (see :help dap-configuration)",
      "build.nvim gives one that builds first: require('build.dap').configuration()",
    })
  else
    health.ok("Debug configurations for " .. table.concat(configured, ", "))
  end

  health.start("dapper: the program being debugged")
  local session = dap.session()
  if not session then
    health.info("Not debugging now (run this while debugging to check the program too)")
    return
  end
  local program = session.config and session.config.program
  if type(program) ~= "string" or program == "" then
    health.info("The session has no program file to check")
    return
  end
  local info = has_debug_info(program)
  if info == false then
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
