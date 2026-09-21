return {
  {
    "zbirenbaum/copilot.lua",
    opts = {
      panel = { enabled = false },
      suggestion = { enabled = false },
      server_opts_overrides = {
        settings = { telemetry = { telemetryLevel = "off" } },
      },
    },
  },
  {
    "fang2hou/blink-copilot",
    opts = { max_completions = 3 },
  },
}
