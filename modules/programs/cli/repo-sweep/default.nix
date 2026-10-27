# Weekly reclaim of idle checkouts in ~ and ~/wt (see repo-sweep.sh for the
# rules). Run `repo-sweep` by hand for a dry run first.
{ pkgs, ... }:
let
  repoSweep = pkgs.writeShellApplication {
    name = "repo-sweep";
    runtimeInputs = with pkgs; [ coreutils findutils git gnugrep ];
    text = builtins.readFile ./repo-sweep.sh;
  };
in
{
  home.packages = [ repoSweep ];

  systemd.user.services.repo-sweep = {
    Unit.Description = "Reclaim idle git checkouts and build caches";
    Service = {
      Type = "oneshot";
      ExecStart = "${repoSweep}/bin/repo-sweep --apply";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.user.timers.repo-sweep = {
    Unit.Description = "Weekly repo-sweep";
    Timer = {
      OnCalendar = "Sun 06:00";
      # Laptops are often asleep at the scheduled time; run on next boot.
      Persistent = true;
      RandomizedDelaySec = "30m";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
