# The hosts table: one entry per nixosConfigurations output and deploy-rs node (30-configurations-options.nix).
{
  configurations.nixos = {
    # deploy-rs is only ever invoked from lenovo itself, so lenovo's own deploy is a loopback self-push, used to
    # prove the sudo/magic-rollback path before it is ever trusted against acer-swift, which has no BMC.
    lenovo = { hostDir = "lenovo-21CB001PMX"; roles = [ "base" "laptop" "homelab-server" ]; deploy.hostname = "localhost"; };

    # remoteBuild: lenovo, memory-constrained, has crashed building these closures; acer's
    # build I/O mid-deploy is the lesser risk to the cluster.
    acer-swift = { roles = [ "base" "laptop" "homelab-agent" "runtime-host" ]; deploy.remoteBuild = true; };

    # remoteBuild for the same reason; only reachable in its Mon-Fri ~09:00-21:00 power window.
    msi-ms7758 = { roles = [ "base" "homelab-agent" "runtime-host" ]; deploy.remoteBuild = true; };

    # remoteBuild, unlike acer: lenovo has no aarch64 builder, so the Pi builds its
    # own closure (untrusted lukas is enough: .drv and sources are CA paths).
    black-pi = { roles = [ "base" "homelab-agent" ]; deploy.remoteBuild = true; };

    # remoteBuild for the same no-aarch64-builder reason; rf-lab keeps the closure
    # to cache hits plus text/symlink derivations, so 1 GiB is enough.
    naked-pi = { roles = [ "base" "rf-lab" "embedded" ]; deploy.remoteBuild = true; };
  };
}
