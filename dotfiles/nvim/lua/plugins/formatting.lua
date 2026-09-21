return {
  {
    "stevearc/conform.nvim",
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
        markdown = { "prettier" },
        python = { "ruff_format" },
        rust = { "rustfmt", lsp_format = "fallback" },
        sh = { "shfmt" },
      },
    },
  },
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = {
        markdown = { "markdownlint-cli2" },
      },
    },
  },
}
