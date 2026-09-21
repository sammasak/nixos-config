local is_nixos = (vim.uv or vim.loop).fs_stat("/etc/NIXOS") ~= nil
local ok, nix = pcall(dofile, vim.fn.stdpath("config") .. "/nix.lua")

if not is_nixos then
  return {}
end

local mason = { "jay-babu/mason-nvim-dap.nvim", enabled = false }

if not (ok and type(nix) == "table" and nix.debugpy_python) then
  return { mason }
end

return {
  mason,
  {
    "mfussenegger/nvim-dap-python",
    -- nix.debugpy_python is guaranteed to have debugpy installed; nvim-dap-python
    -- already re-resolves VIRTUAL_ENV per launch for the debuggee's pythonPath,
    -- so swapping the adapter itself onto an unvetted venv risked ModuleNotFoundError.
    config = function()
      require("dap-python").setup(nix.debugpy_python)
    end,
  },
}
