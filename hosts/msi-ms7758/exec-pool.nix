# msi's execution-pool slots, each run by a runner claiming from acer's queue. Its own file so the pool-off tests
# (scripts/test-workers-eval.py) can evaluate msi without it through disabledModules.
{
  imports = [ ../../modules/homelab/exec-pool-runner.nix ];

  sam.workers.executionPool = {
    enable = true;
    slots = 4;
    agents = [ "claude" ];
    # the host's push key: a task hands its code back on its own branch, pool/<task id>
    credentials = [ "id_ed25519" ];
  };
  homelab.execPool.runner = {
    enable = true;
    queue = "exec-pool-db";
    store = "acer-swift";
  };
  homelab.execPool.sessionGc.enable = true;
}
