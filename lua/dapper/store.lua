--- What is kept from one Neovim to the next, per project (its git root, else the working
--- directory): the watched expressions, the pins and the function breakpoints.
--- In stdpath("data")/dapper.json. The lists follow the project: after :cd to another, they are
--- saved under the one before and the new one's are read.

local M = {}

local root -- the project the lists in use were read for
local tracked = {} -- key -> { list, save, load }
local augroup -- (its DirChanged autocmd, made once)

local function file()
  return vim.fn.stdpath("data") .. "/dapper.json"
end

local function project()
  local cwd = vim.fn.getcwd()
  return vim.fs.root(cwd, ".git") or cwd
end

-- the file's contents, read each time (another Neovim may have written it since)
local function read()
  local ok, decoded = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(file()), "\n"))
  end)
  return ok and type(decoded) == "table" and decoded or {}
end

--- the list `key` of the current project (a copy)
function M.get(key)
  root = root or project()
  return vim.deepcopy((read()[root] or {})[key] or {})
end

--- sets the list `key` of the current project, and writes the file (only that list changes in it)
function M.set(key, list)
  root = root or project()
  local all = read()
  local lists = all[root] or {}
  if vim.tbl_isempty(list) and lists[key] == nil then
    return -- (nothing kept, nothing to keep: no file written)
  end
  lists[key] = not vim.tbl_isempty(list) and list or nil
  all[root] = not vim.tbl_isempty(lists) and lists or nil
  pcall(vim.fn.mkdir, vim.fs.dirname(file()), "p")
  pcall(vim.fn.writefile, { vim.json.encode(all) }, file())
end

--- Fills `list` with the list `key` of the current project (each item made with `load`, if
--- given), and keeps it that project's: when the project changes, `save()` writes it, and it is
--- filled again with the new project's. Returns `list`.
function M.track(key, list, save, load)
  tracked[key] = { list = list, save = save, load = load }
  for i, item in ipairs(M.get(key)) do
    list[i] = load and load(item) or item
  end
  if not augroup then
    augroup = vim.api.nvim_create_augroup("dapper.store", {})
    vim.api.nvim_create_autocmd("DirChanged", {
      group = augroup,
      callback = function()
        if project() == root then
          return
        end
        for _, t in pairs(tracked) do
          t.save() -- (under the project before)
        end
        root = project()
        for k, t in pairs(tracked) do
          for i = #t.list, 1, -1 do
            t.list[i] = nil
          end
          for i, item in ipairs(M.get(k)) do
            t.list[i] = t.load and t.load(item) or item
          end
        end
        if package.loaded["dapper.pins"] then
          require("dapper.pins").draw()
        end
        if package.loaded["dapper.views"] then
          require("dapper.views").refresh()
        end
      end,
    })
  end
  return list
end

return M
