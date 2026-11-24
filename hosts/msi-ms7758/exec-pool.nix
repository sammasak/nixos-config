# msi's execution-pool slots, each run by a runner claiming from acer's queue. Its own file so the pool-off tests
# (scripts/test-workers-eval.py) can evaluate msi without it through disabledModules.
{
  imports = [ ../../modules/homelab/exec-pool-runner.nix ];

  homelab.execPool = {
    enable = true;
    roles = [ "runner" ];
    slots = 4;
    agents = [ "claude" ];
    queueListener = "exec-pool-db";
  };
}
