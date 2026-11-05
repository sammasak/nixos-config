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
    name = "branch-without-lock";
    expect = "a branch with resolve = \"lock\" needs `lock = inputs.<input>`";
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
    name = "private-locked-source";
    expect = "access = \"private\" is consumed only by an assignment-time prefetch";
    module = bad { repositories.factum = lockedMain { access = "private"; }; };
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
    name = "commit-without-lock";
    expect = "a commit with resolve = \"lock\" needs `lock = inputs.<input>`";
    module = bad {
      repositories.factum = lockedMain {
        ref = {
          type = "commit";
          value = factum.rev;
        };
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
    expect = "instance paths overlap: /workspace/same vs /workspace/same";
    module = bad {
      repositories = {
        a = lockedMain { path = "/workspace/same"; };
        # a different repo, so only the path collides and not the identity
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
    expect = "instance paths overlap: /workspace/factum/target vs /workspace; ";
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
    expect = "repositories.factum.path' is not of type `absolute normalized path";
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
    expect = "repositories.factum.lock.outPath' is not of type";
    module = bad { repositories.factum = lockedMain { lock = factum // { outPath = ./.; }; }; };
  }
  {
    name = "missing-skill";
    expect = "skills.no-such-skill: not in skills source";
    module = bad { skills.no-such-skill = { }; };
  }
  {
    name = "skill-name-traversal";
    expect = "skills.../agents: not in skills source";
    module = bad { skills."../agents" = { }; };
  }
  {
    name = "wrong-resource-type";
    expect = "templates.bad.resources.memoryMiB' is not of type";
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
    expect = "read-write but its allowed mount root /srv/agent-runtime/cache is read-only";
    module = bad {
      filesystem.mounts = [
        {
          hostPath = "/srv/agent-runtime/cache/shared";
          path = "/mnt/shared";
          writable = true;
        }
      ];
    };
  }
  {
    name = "nested-roots-most-specific-wins";
    expect = "read-write but its allowed mount root /srv/agent-runtime/scratch/locked is read-only";
    # merges with templates.nix's writable /srv/agent-runtime/scratch; the nested read-only root must win
    module = lib.recursiveUpdate (bad {
      filesystem.mounts = [
        {
          hostPath = "/srv/agent-runtime/scratch/locked/x";
          path = "/mnt/x";
          writable = true;
        }
      ];
    }) { sam.agentRuntime.host.allowedMountRoots = [ "/srv/agent-runtime/scratch/locked" ]; };
  }
  {
    name = "host-root-denied";
    expect = "/run/agent-cache is on a denied host root";
    module = { sam.agentRuntime.host.allowedMountRoots = [ "/run/agent-cache" ]; };
  }
  {
    name = "reserved-var-run";
    expect = "instance path on a reserved root";
    module = bad { filesystem.cache.path = "/var/run/agent"; };
  }
  {
    name = "host-root-ancestor";
    expect = "/var is on a denied host root";
    module = { sam.agentRuntime.host.allowedMountRoots = [ "/var" ]; };
  }
  {
    name = "host-root-var-lib";
    expect = "/var/lib/agent-cache is on a denied host root";
    module = { sam.agentRuntime.host.allowedMountRoots = [ "/var/lib/agent-cache" ]; };
  }
  {
    name = "duplicate-allowed-roots";
    expect = "duplicate root /srv/agent-runtime/cache";
    module = { sam.agentRuntime.host.allowedMountRoots = [ "/srv/agent-runtime/cache" ]; };
  }
  {
    name = "allow-ip-literal";
    expect = "is not of type `DNS name";
    module = bad { network.allow = [ "169.254.169.254" ]; };
  }
  {
    name = "allow-empty-list";
    expect = "network.allow' is not of type";
    module = bad { network.allow = [ ]; };
  }
  {
    name = "mount-under-workspace-with-repo";
    expect = "instance paths overlap: /workspace/home vs /workspace";
    module = bad {
      repositories.factum = lockedMain { };
      filesystem.home.path = "/workspace/home";
    };
  }
  {
    name = "template-name-invalid";
    expect = "template name `Bad_Name` must be lowercase";
    module = { sam.agentRuntime.templates."Bad_Name" = minimal; };
  }
  {
    name = "repository-name-invalid";
    expect = "repositories: names must be lowercase";
    module = bad { repositories."Factum Main" = lockedMain { }; };
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
