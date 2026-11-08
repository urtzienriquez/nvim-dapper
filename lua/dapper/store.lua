--- What is kept from one Neovim to the next, per project (its git root, else the working
--- directory): the watched expressions, the pins and the function breakpoints.
--- In stdpath("data")/dapper.json.

local M = {}

local data -- root -> { watches = {...}, pins = {...}, functions = {...} }

local function file()
  return vim.fn.stdpath("data") .. "/dapper.json"
end

function M.root()
  local cwd = vim.fn.getcwd()
  return vim.fs.root(cwd, ".git") or cwd
end

local function load()
  if not data then
    local ok, decoded = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(file()), "\n"))
    end)
    data = ok and type(decoded) == "table" and decoded or {}
  end
  return data
end

--- the list `key` of the current project (a copy)
function M.get(key)
  local project = load()[M.root()] or {}
  return vim.deepcopy(project[key] or {})
end

--- sets the list `key` of the current project, and writes the file
function M.set(key, list)
  local all = load()
  local root = M.root()
  if vim.tbl_isempty(list) and not (all[root] and all[root][key]) then
    return -- (nothing kept, nothing to keep: no file written)
  end
  all[root] = all[root] or {}
  all[root][key] = list
  if vim.tbl_isempty(list) then
    all[root][key] = nil
    if vim.tbl_isempty(all[root]) then
      all[root] = nil
    end
  end
  pcall(vim.fn.mkdir, vim.fs.dirname(file()), "p")
  pcall(vim.fn.writefile, { vim.json.encode(all) }, file())
end

return M
