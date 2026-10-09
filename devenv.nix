{ pkgs, ... }:

{
  packages = [ pkgs.sysstat pkgs.lm_sensors pkgs.jq pkgs.hyperfine ];

  tasks."system:record" = {
    input = {
      label = "manual";
      duration = 300;
      interval = 2;
    };
    exec = ''bash scripts/system-record.sh "$DEVENV_TASK_INPUT"'';
  };

  tasks."system:benchmark" = {
    input = {
      label = "manual";
      command = "";
      runs = 7;
      warmup = 2;
    };
    exec = ''bash scripts/system-benchmark.sh "$DEVENV_TASK_INPUT"'';
  };

  tasks."system:compare" = {
    input = {
      before = "";
      after = "";
    };
    exec = ''bash scripts/system-compare.sh "$DEVENV_TASK_INPUT"'';
  };
}
