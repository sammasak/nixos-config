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
    ownRefsOnly = true;
    # each slot in its own uids; acer's slots follow once msi has run a day with it
    slot.privateUsers = true;
  };
}
