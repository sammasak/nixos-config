# Negative cases: each adds one template (or host setting) on top of
# templates.nix and must fail evaluation with `expect` in the message.
{ lib, factum, skills }:
let
  minimal = {
    role = {
      name = "rust-worker";
      harness = "claude-code";
    };
    skillsSource = skills;
    filesystem = {
      home.sizeMiB = 64;
      tmp.sizeMiB = 64;
      cache.sizeMiB = 64;
      output.sizeMiB = 64;
    };
    resources = {
      cpus = 1;
      memoryMiB = 512;
      timeoutMinutes = 10;
    };
  };
  repo = extra: {
    github = "sammasak/factum";
    path = "/workspace/factum";
  } // extra;
  bad = overrides: { sam.agentRuntime.templates.bad = lib.recursiveUpdate minimal overrides; };
in
[
  {
    name = "invalid-ref-type";
    expect = "one of \"branch\", \"tag\", \"commit\"";
    module = bad { repositories.factum = repo { ref = { type = "sha"; value = "main"; }; lock = factum; }; };
  }
  {
    name = "commit-value-not-sha";
    expect = "a commit ref must be a 40-hex revision";
    module = bad { repositories.factum = repo { ref = { type = "commit"; value = "main"; }; }; };
  }
  {
    name = "branch-without-lock";
    expect = "needs `lock = inputs.<name>`";
    module = bad { repositories.factum = repo { ref = { type = "branch"; value = "main"; }; }; };
  }
  {
    name = "lock-rev-differs-from-commit";
    expect = "differs from the commit";
    module = bad {
      repositories.factum = repo {
        ref = { type = "commit"; value = "0000000000000000000000000000000000000000"; };
        lock = factum;
      };
    };
  }
  {
    name = "assignment-with-lock";
    expect = "drop `lock`";
    module = bad { repositories.factum = repo { ref = { type = "tag"; value = "v1"; }; resolve = "assignment"; lock = factum; }; };
  }
  {
    name = "duplicate-paths";
    expect = "instance paths overlap";
    module = bad {
      repositories = {
        a = repo { ref = { type = "branch"; value = "main"; }; lock = factum; };
        b = repo { github = "sammasak/skills"; ref = { type = "branch"; value = "main"; }; lock = skills; };
      };
    };
  }
  {
    name = "nested-path-overlap";
    expect = "instance paths overlap";
    module = bad {
      repositories.factum = repo { ref = { type = "branch"; value = "main"; }; lock = factum; };
      filesystem.tmp.path = "/workspace/factum/target";
    };
  }
  {
    name = "duplicate-repository-identity";
    expect = "duplicate repository identity";
    module = bad {
      repositories = {
        a = repo { ref = { type = "branch"; value = "main"; }; lock = factum; path = "/workspace/a"; };
        b = repo { ref = { type = "branch"; value = "main"; }; lock = factum; path = "/workspace/b"; };
      };
    };
  }
  {
    name = "path-outside-workspace";
    expect = "is not under filesystem.workspace";
    module = bad { repositories.factum = repo { ref = { type = "branch"; value = "main"; }; lock = factum; path = "/opt/factum"; }; };
  }
  {
    name = "path-traversal";
    expect = "absolute normalized path";
    module = bad { repositories.factum = repo { ref = { type = "branch"; value = "main"; }; lock = factum; path = "/workspace/../etc"; }; };
  }
  {
    name = "missing-skill";
    expect = "not in skills source";
    module = bad { skills.no-such-skill = { }; };
  }
  {
    name = "wrong-resource-type";
    expect = "is not of type";
    module = bad { resources.memoryMiB = "4G"; };
  }
  {
    name = "unauthorized-host-mount";
    expect = "unauthorized host mount";
    module = bad {
      filesystem.mounts = [ { hostPath = "/home/lukas/.ssh"; path = "/mnt/ssh"; } ];
    };
  }
  {
    name = "egress-allowlist-empty";
    expect = "needs a non-empty `allow`";
    module = bad { network.egress = "allowlist"; };
  }
  {
    name = "host-eligible-unknown-template";
    expect = "names unknown template";
    module = { sam.agentRuntime.host.eligibleTemplates = [ "no-such-template" ]; };
  }
]
