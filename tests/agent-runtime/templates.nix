# Two templates a consumer would declare. `rust-worker` checks out one real
# Rust repo three ways (locked branch, exact commit, tag resolved per
# assignment) with two real skills; `docs-reviewer` is a read-only reviewer
# whose template name and role name differ on purpose. Only rust-worker is
# host-eligible. `factum` and `skills` are flake inputs (flake = false).
{ factum, skills }:
{ pkgs, ... }:
{
  sam.agentRuntime = {
    host = {
      enable = true;
      eligibleTemplates = [ "rust-worker" ];
      maxConcurrentInstances = 2;
      allowedMountRoots = [ "/srv/agent-runtime/cache" ];
    };

    templates.rust-worker = {
      role = {
        name = "rust-worker";
        harness = "claude-code";
      };
      repositories = {
        factum = {
          github = "sammasak/factum";
          ref = {
            type = "branch";
            value = "main";
          };
          lock = factum;
          path = "/workspace/factum";
          writable = true;
        };
        factum-pinned = {
          github = "sammasak/factum";
          ref = {
            type = "commit";
            value = factum.rev;
          };
          lock = factum;
          path = "/workspace/factum-pinned";
        };
        factum-release = {
          github = "sammasak/factum";
          ref = {
            type = "tag";
            value = "v0.2.0";
          };
          resolve = "assignment";
          path = "/workspace/factum-release";
        };
      };
      skillsSource = skills;
      skills = {
        rust-engineering = { };
        nix-flake-development = { };
      };
      packages = with pkgs; [
        cargo
        rustc
        gcc
        git
      ];
      filesystem = {
        home.sizeMiB = 512;
        tmp.sizeMiB = 1024;
        cache.sizeMiB = 4096;
        output.sizeMiB = 256;
        mounts = [
          {
            hostPath = "/srv/agent-runtime/cache/cargo-registry";
            path = "/var/cache/cargo-registry";
          }
        ];
      };
      resources = {
        cpus = 2;
        memoryMiB = 3072;
        timeoutMinutes = 90;
      };
      network = {
        egress = "allowlist";
        allow = [
          "github.com"
          "crates.io"
          "static.crates.io"
        ];
      };
      capabilities = [
        "github-read"
        "github-comment"
      ];
    };

    templates.docs-reviewer = {
      role = {
        name = "quality";
        harness = "codex";
      };
      repositories.factum = {
        github = "sammasak/factum";
        ref = {
          type = "tag";
          value = "v0.2.0";
        };
        resolve = "assignment";
        path = "/workspace/factum";
      };
      skillsSource = skills;
      skills.lean-code = { };
      packages = [ pkgs.jq ];
      filesystem = {
        home.sizeMiB = 128;
        tmp.sizeMiB = 256;
        cache.sizeMiB = 256;
        output.sizeMiB = 64;
      };
      resources = {
        cpus = 1;
        memoryMiB = 1024;
        timeoutMinutes = 30;
      };
    };
  };
}
