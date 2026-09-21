local markers = {
  ".git",
  "Cargo.toml",
  "pyproject.toml",
  "package.json",
  "flake.nix",
  "justfile",
  "Justfile",
  "Makefile",
}

local tools = {
  "rust-analyzer",
  "rustfmt",
  "cargo",
  "basedpyright-langserver",
  "ruff",
  "pytest",
  "uv",
  "node",
  "nil",
  "marksman",
}

local function display_path(path)
  return vim.fn.fnamemodify(path, ":~")
end

local function project_info()
  local cwd = vim.fn.getcwd()
  local root = vim.fs.root(0, markers) or cwd
  local lines = {
    "root: " .. display_path(root),
    "cwd: " .. display_path(cwd),
    "direnv: " .. (vim.env.DIRENV_DIR and "loaded (" .. display_path(vim.env.DIRENV_DIR) .. ")" or "not loaded"),
    "virtualenv: " .. (vim.env.VIRTUAL_ENV and display_path(vim.env.VIRTUAL_ENV) or "none"),
    "",
    "tools on Neovim PATH:",
  }

  for _, tool in ipairs(tools) do
    local path = vim.fn.exepath(tool)
    table.insert(lines, string.format("%-28s %s", tool, path ~= "" and display_path(path) or "missing"))
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "Project Info", timeout = 10000 })
end

vim.api.nvim_create_user_command("ProjectInfo", project_info, { desc = "Show project root, environment, and tool provenance" })
