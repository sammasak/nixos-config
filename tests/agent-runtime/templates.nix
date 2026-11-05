# A consumer's templates; docs-reviewer's role name differs from its template
# name on purpose. `factum` and `skills` are flake = false inputs.
{ factum, skills }:
{ pkgs, ... }:
{
  sam.agentRuntime = {
    host = {
      enable = true;
      eligibleTemplates = [ "rust-worker" ];
      maxConcurrentInstances = 2;
      allowedMountRoots = [
        "/srv/agent-runtime/cache"
        {
          path = "/srv/agent-runtime/scratch";
          writable = true;
        }
      ];
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
          {
            hostPath = "/srv/agent-runtime/scratch/rust-worker";
            path = "/mnt/scratch";
            writable = true;
          }
        ];
      };
      resources = {
        cpus = 2;
        memoryMiB = 3072;
        timeoutMinutes = 90;
      };
      network.allow = [
        "github.com"
        "crates.io"
        "static.crates.io"
      ];
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
