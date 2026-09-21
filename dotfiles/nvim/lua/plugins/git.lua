-- Richer git diffs/history on top of LazyVim defaults (gitsigns inline hunks +
-- <leader>gg lazygit). diffview gives a side-by-side diff and file-history view.
return {
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
    keys = {
      { "<leader>gd", "<cmd>DiffviewOpen<cr>", desc = "Diff view (working tree)" },
      { "<leader>gS", "<cmd>DiffviewOpen --cached<cr>", desc = "Diff view (staged)" },
      { "<leader>gD", "<cmd>DiffviewClose<cr>", desc = "Diff view close" },
      { "<leader>gh", "<cmd>DiffviewFileHistory %<cr>", desc = "File history (current)" },
      { "<leader>gH", "<cmd>DiffviewFileHistory<cr>", desc = "File history (branch)" },
    },
    opts = {},
  },
}
