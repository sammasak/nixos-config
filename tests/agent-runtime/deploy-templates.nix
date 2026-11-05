# One template module consumed unchanged by every host that runs it (#140): the
# deploy VM test's two hosts and the real-host compatibility check. `version`
# stands in for a template change (a package added), never for a host change.
{ skills, version ? 1 }:
{ lib, pkgs, ... }:
{
  sam.agentRuntime.templates.tiny = {
    role = {
      name = "quality";
      harness = "codex";
    };
    skillsSource = skills;
    skills.lean-code = { };
    packages = [ pkgs.bash pkgs.coreutils ] ++ lib.optional (version >= 2) pkgs.hello ++ lib.optional (version >= 3) pkgs.gnugrep;
    filesystem = {
      workspaceBudget = { sizeMiB = 16; inodes = 1000; };
      home = { sizeMiB = 16; inodes = 1000; };
      tmp = { sizeMiB = 16; inodes = 1000; };
      cache = { sizeMiB = 16; inodes = 1000; };
      output = { sizeMiB = 16; inodes = 1000; };
    };
    resources = {
      cpus = 1;
      memoryMiB = 64;
      tasksMax = 64;
      timeoutMinutes = 5;
    };
  };
}
