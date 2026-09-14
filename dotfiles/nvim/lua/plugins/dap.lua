-- DAP wiring for Mason-off NixOS.
--   Rust:   rustaceanvim auto-detects the `codelldb` Nix puts on PATH — no config.
--   Python: debugpy's interpreter comes from Nix (nix.lua). Off-Nix (the work
--           laptop) has no nix.lua, so dap.core's mason-nvim-dap supplies it and
--           this override is skipped, keeping the config portable.
local ok, nix = pcall(dofile, vim.fn.stdpath("config") .. "/nix.lua")

if not (ok and type(nix) == "table" and nix.debugpy_python) then
  return {}
end

return {
  {
    "mfussenegger/nvim-dap-python",
    config = function()
      require("dap-python").setup(nix.debugpy_python)
    end,
  },
}
