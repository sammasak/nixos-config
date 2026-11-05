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
  branch = {
    type = "branch";
    value = "main";
  };
  # A locked checkout of factum's main; each case shows only what it changes.
  lockedMain =
    extra:
    {
      github = "sammasak/factum";
      ref = branch;
      lock = factum;
      path = "/workspace/factum";
    }
    // extra;
  bad = overrides: { sam.agentRuntime.templates.bad = lib.recursiveUpdate minimal overrides; };
in
[
  {
    name = "invalid-ref-type";
    expect = "ref.type' is not of type";
    module = bad {
      repositories.factum = lockedMain {
        ref = {
          type = "sha";
          value = "main";
        };
      };
    };
  }
  {
    name = "commit-value-not-sha";
    expect = "a commit ref must be a 40-hex revision";
    module = bad {
      repositories.factum = lockedMain {
        ref = {
          type = "commit";
          value = "main";
        };
      };
    };
  }
  {
    name = "branch-without-lock";
    expect = "needs `lock = inputs.<name>`";
    module = bad { repositories.factum = lockedMain { lock = null; }; };
  }
  {
    name = "lock-rev-differs-from-commit";
    expect = "differs from the commit";
    module = bad {
      repositories.factum = lockedMain {
        ref = {
          type = "commit";
          value = "0000000000000000000000000000000000000000";
        };
      };
    };
  }
  {
    name = "assignment-with-lock";
    expect = "drop `lock`";
    module = bad {
      repositories.factum = lockedMain {
        ref = {
          type = "tag";
          value = "v1";
        };
        resolve = "assignment";
      };
    };
  }
  {
    name = "commit-with-assignment";
    expect = "a commit needs no resolution";
    module = bad {
      repositories.factum = lockedMain {
        ref = {
          type = "commit";
          value = factum.rev;
        };
        resolve = "assignment";
        lock = null;
      };
    };
  }
  {
    name = "ref-value-injection";
    expect = "ref.value' is not of type `git ref name";
    module = bad {
      repositories.factum = lockedMain {
        ref = {
          type = "branch";
          value = "--upload-pack=x";
        };
      };
    };
  }
  {
    name = "duplicate-paths";
    expect = "instance paths overlap";
    module = bad {
      repositories = {
        a = lockedMain { path = "/workspace/same"; };
        b = lockedMain {
          github = "sammasak/skills";
          lock = skills;
          path = "/workspace/same";
        };
      };
    };
  }
  {
    name = "nested-path-overlap";
    expect = "instance paths overlap";
    module = bad {
      repositories.factum = lockedMain { };
      filesystem.tmp.path = "/workspace/factum/target";
    };
  }
  {
    name = "reserved-instance-path";
    expect = "instance path on a reserved root";
    module = bad { filesystem.cache.path = "/nix/store"; };
  }
  {
    name = "duplicate-repository-identity";
    expect = "duplicate repository identity";
    module = bad {
      repositories = {
        a = lockedMain { path = "/workspace/a"; };
        b = lockedMain { path = "/workspace/b"; };
      };
    };
  }
  {
    name = "path-outside-workspace";
    expect = "is not under filesystem.workspace";
    module = bad { repositories.factum = lockedMain { path = "/opt/factum"; }; };
  }
  {
    name = "path-traversal";
    expect = "absolute normalized path";
    module = bad { repositories.factum = lockedMain { path = "/workspace/../etc"; }; };
  }
  {
    name = "missing-repo-path";
    expect = "repositories.factum.path' was accessed but has no value defined";
    module = bad {
      repositories.factum = {
        github = "sammasak/factum";
        ref = branch;
        lock = factum;
      };
    };
  }
  {
    name = "lock-is-a-path-literal";
    expect = "outPath' is not of type";
    module = bad { repositories.factum = lockedMain { lock = factum // { outPath = ./.; }; }; };
  }
  {
    name = "missing-skill";
    expect = "not in skills source";
    module = bad { skills.no-such-skill = { }; };
  }
  {
    name = "skill-name-traversal";
    expect = "not in skills source";
    module = bad { skills."../agents" = { }; };
  }
  {
    name = "wrong-resource-type";
    expect = "memoryMiB' is not of type";
    module = bad { resources.memoryMiB = "4G"; };
  }
  {
    name = "unauthorized-host-mount";
    expect = "unauthorized host mount";
    module = bad {
      filesystem.mounts = [
        {
          hostPath = "/home/lukas/.ssh";
          path = "/mnt/ssh";
        }
      ];
    };
  }
  {
    name = "writable-mount-under-read-only-root";
    expect = "read-write but its allowed mount root is read-only";
    module = bad {
      filesystem.mounts = [
        {
          hostPath = "/srv/agent-runtime/cache/shared";
          path = "/mnt/shared";
          readOnly = false;
        }
      ];
    };
  }
  {
    name = "egress-allowlist-empty";
    expect = "needs a non-empty `allow`";
    module = bad { network.egress = "allowlist"; };
  }
  {
    name = "allow-without-allowlist";
    expect = "`allow` needs egress";
    module = bad { network.allow = [ "github.com" ]; };
  }
  {
    name = "allow-ip-literal";
    expect = "network.allow";
    module = bad {
      network = {
        egress = "allowlist";
        allow = [ "169.254.169.254" ];
      };
    };
  }
  {
    name = "host-eligible-unknown-template";
    expect = "names unknown template";
    module = { sam.agentRuntime.host.eligibleTemplates = [ "no-such-template" ]; };
  }
  {
    name = "host-eligible-without-enable";
    expect = "host.enable is false";
    module = { sam.agentRuntime.host.enable = lib.mkForce false; };
  }
]
