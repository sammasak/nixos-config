# msi's one execution-pool slot, run by a runner claiming from acer's queue. Its own file so the pool-off tests
# (scripts/test-workers-eval.py) can evaluate msi without it through disabledModules.
{
  imports = [ ../../modules/homelab/exec-pool-runner.nix ];

  sam.workers.executionPool = {
    enable = true;
    slots = 1;
    agents = [ "claude" ];
    # the key m1 and m2 push with: a task hands its code back on its own branch, pool/<task id>
    credentials = [ "id_ed25519" ];
  };
  homelab.execPool.runner = {
    enable = true;
    queue = "exec-pool-db";
    store = "acer-swift";
  };
}
