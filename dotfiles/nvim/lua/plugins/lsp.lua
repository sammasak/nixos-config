-- Language servers, portable across NixOS and non-Nix (work) machines.
--
-- Mason downloads prebuilt, dynamically-linked binaries. NixOS has no FHS
-- loader for them, so Mason is DISABLED there and every server is resolved
-- from PATH: each repo's devshell (loaded by direnv) provides the
-- project-versioned server, and the system provides a few fallbacks.
--
-- Everywhere else (the work laptop) Mason is ENABLED as the safety net that
-- makes any repo "just work" even with no devshell. Where a project *does*
-- provide its own tools, direnv prepends that project's bin dir to PATH per
-- buffer, so the project's server still wins over Mason's copy.
--
-- One runtime check drives the whole difference; the rest of the config is
-- identical on every machine.
local is_nixos = (vim.uv or vim.loop).fs_stat("/etc/NIXOS") ~= nil
local nix_ok, nix = pcall(dofile, vim.fn.stdpath("config") .. "/nix.lua")

local rustacean_opts = {
  server = {
    default_settings = {
      ["rust-analyzer"] = {
        cargo = { allFeatures = true, buildScripts = { enable = true } },
        check = { command = "clippy" },
        checkOnSave = true,
        diagnostics = { enable = true },
        inlayHints = { bindingModeHints = { enable = true }, closingBraceHints = { minLines = 20 }, parameterHints = { enable = true }, typeHints = { enable = true } },
        procMacro = { enable = true },
        files = { exclude = { ".direnv", ".git", "target", "node_modules", ".venv", "venv" } },
      },
    },
  },
}

if nix_ok and type(nix) == "table" and nix.codelldb and nix.liblldb then
  rustacean_opts.dap = {
    adapter = function()
      return require("rustaceanvim.config").get_codelldb_adapter(nix.codelldb, nix.liblldb)
    end,
  }
end

return {
  { "mason-org/mason.nvim", enabled = not is_nixos },
  { "mason-org/mason-lspconfig.nvim", enabled = not is_nixos },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        nil_ls = {},
        marksman = {},
        basedpyright = {
          settings = {
            basedpyright = {
              analysis = {
                autoImportCompletions = true,
                autoSearchPaths = true,
                diagnosticMode = "workspace",
                inlayHints = { callArgumentNames = true, functionReturnTypes = true, variableTypes = true },
                typeCheckingMode = "standard",
                useLibraryCodeForTypes = true,
              },
            },
          },
        },
        ruff = {},
      },
    },
  },
  {
    "mrcjkb/rustaceanvim",
    keys = {
      { "<leader>dR", "<cmd>RustLsp debuggables<cr>", ft = "rust", desc = "Rust debuggables" },
    },
    opts = rustacean_opts,
  },
}
