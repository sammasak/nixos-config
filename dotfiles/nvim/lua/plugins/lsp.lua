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

return {
  { "mason-org/mason.nvim", enabled = not is_nixos },
  { "mason-org/mason-lspconfig.nvim", enabled = not is_nixos },
  {
    "neovim/nvim-lspconfig",
    opts = {
      -- Declared so lspconfig knows to attach; the binary itself always comes
      -- from PATH (direnv/devshell first, Mason fallback off-Nix).
      servers = {
        nil_ls = {},
        marksman = {},
        rust_analyzer = {},
      },
    },
  },
}
