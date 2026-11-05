# Typed agent-runtime templates: what an ephemeral nspawn instance would
# contain (sources, skills, packages, filesystem, policy) and the versioned
# manifest later milestones consume. Nothing here starts a container.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.sam.agentRuntime;

  sha40 = types.strMatching "^[0-9a-f]{40}$";
  githubRepo = types.strMatching "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$";
  hostName = types.strMatching "^[A-Za-z0-9.-]+$";

  normalizedPath = types.mkOptionType {
    name = "normalizedPath";
    description = "absolute normalized path (no `.`/`..` components, no `//`, no trailing slash)";
    check =
      p:
      builtins.isString p
      && builtins.match "^(/[A-Za-z0-9._-]+)+$" p != null
      && !builtins.any (c: c == "." || c == "..") (lib.splitString "/" p);
    merge = lib.mergeEqualOption;
  };

  # A flake input (`inputs.<name>` with `flake = false`) is accepted as is:
  # `rev`, `narHash` and `outPath` are typed, the rest passes through.
  lockedSource = types.submodule {
    freeformType = types.attrsOf types.anything;
    options = {
      rev = mkOption {
        type = sha40;
        description = "Immutable git revision the flake lock resolved.";
      };
      narHash = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "NAR hash of the fetched tree.";
      };
      outPath = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Store path of the fetched tree.";
      };
    };
  };

  budgetedMount =
    path:
    types.submodule {
      options = {
        path = mkOption {
          type = normalizedPath;
          default = path;
          description = "Mount point inside the instance.";
        };
        sizeMiB = mkOption {
          type = types.ints.positive;
          description = "Writable byte budget (MiB).";
        };
        inodes = mkOption {
          type = types.ints.positive;
          default = 100000;
          description = "Writable inode budget.";
        };
      };
    };

  repository = types.submodule {
    options = {
      github = mkOption {
        type = githubRepo;
        description = "GitHub `owner/repo`.";
      };
      ref = {
        type = mkOption {
          type = types.enum [ "branch" "tag" "commit" ];
          description = "What `ref.value` names.";
        };
        value = mkOption {
          type = types.nonEmptyStr;
          description = "Branch or tag name, or the 40-hex commit.";
        };
      };
      resolve = mkOption {
        type = types.enum [ "lock" "assignment" ];
        default = "lock";
        description = ''
          `lock`: the immutable revision comes from `lock` (a flake input) at
          evaluation time. `assignment`: a moving branch/tag is resolved once
          per run by the runtime adapter and recorded in the run manifest.
        '';
      };
      lock = mkOption {
        type = types.nullOr lockedSource;
        default = null;
        description = "The pinned flake input that locks this ref (required for `resolve = \"lock\"` on a branch or tag).";
      };
      path = mkOption {
        type = normalizedPath;
        description = "Checkout path inside the instance, under `filesystem.workspace`.";
      };
      writable = mkOption {
        type = types.bool;
        default = false;
        description = "Private writable copy (true) or read-only store path (false). Never implies push rights.";
      };
    };
  };

  template = types.submodule (
    { name, config, ... }:
    {
      options = {
        role = {
          name = mkOption {
            type = types.strMatching "^[a-z0-9-]+$";
            description = "Role contract name (skills `agents/<role>` once skills#63 lands).";
          };
          harness = mkOption {
            type = types.enum [ "claude-code" "codex" "pi" ];
            description = "Harness that loads the role and skills.";
          };
        };
        repositories = mkOption {
          type = types.attrsOf repository;
          default = { };
          description = "Named GitHub sources materialized inside the instance.";
        };
        skillsSource = mkOption {
          type = lockedSource;
          description = "The pinned skills tree (`inputs.skills`); every skill below is a directory of its `skills/`.";
        };
        skills = mkOption {
          type = types.attrsOf (
            types.submodule {
              options.source = mkOption {
                type = lockedSource;
                default = config.skillsSource;
                description = "Pinned skills tree this skill is read from.";
              };
            }
          );
          default = { };
          description = "Explicitly named skills; unknown names fail evaluation.";
        };
        packages = mkOption {
          type = types.listOf types.package;
          default = [ ];
          description = "Nix packages on the instance PATH (`with pkgs; [ ... ]`).";
        };
        filesystem = {
          workspace = mkOption {
            type = normalizedPath;
            default = "/workspace";
            description = "Parent of every repository path.";
          };
          home = mkOption {
            type = budgetedMount "/home/agent";
            description = "Private HOME.";
          };
          tmp = mkOption {
            type = budgetedMount "/tmp";
            description = "Private TMPDIR.";
          };
          cache = mkOption {
            type = budgetedMount "/var/cache/agent";
            description = "Private cache (cargo, nix eval caches).";
          };
          output = mkOption {
            type = budgetedMount "/output";
            description = "Artifact export directory.";
          };
          mounts = mkOption {
            type = types.listOf (
              types.submodule {
                options = {
                  hostPath = mkOption {
                    type = normalizedPath;
                    description = "Host directory; must lie under `host.allowedMountRoots`.";
                  };
                  path = mkOption {
                    type = normalizedPath;
                    description = "Mount point inside the instance.";
                  };
                  readOnly = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Bind read-only.";
                  };
                };
              }
            );
            default = [ ];
            description = "Extra host bind mounts, each authorized by the host policy.";
          };
        };
        resources = {
          cpus = mkOption {
            type = types.ints.positive;
            description = "CPU quota in whole cores.";
          };
          memoryMiB = mkOption {
            type = types.ints.positive;
            description = "Hard memory ceiling (MiB).";
          };
          tasksMax = mkOption {
            type = types.ints.positive;
            default = 512;
            description = "Task (pid/thread) ceiling.";
          };
          timeoutMinutes = mkOption {
            type = types.ints.positive;
            description = "Wall-clock budget of one run.";
          };
        };
        network = {
          egress = mkOption {
            type = types.enum [ "none" "allowlist" ];
            default = "none";
            description = "Private network namespace: no egress, or only the listed hosts.";
          };
          allow = mkOption {
            type = types.listOf hostName;
            default = [ ];
            description = "Egress hosts when `egress = \"allowlist\"`.";
          };
        };
        capabilities = mkOption {
          type = types.listOf (
            types.enum [
              "github-read"
              "github-comment"
              "github-push"
            ]
          );
          default = [ ];
          description = "Declared capabilities; credential grants are separate and never in the store.";
        };
      };
    }
  );

  pathsOf =
    t:
    [ t.filesystem.home t.filesystem.tmp t.filesystem.cache t.filesystem.output ]
    ++ lib.mapAttrsToList (n: r: { path = r.path; }) t.repositories
    ++ t.filesystem.mounts;

  overlaps = a: b: a == b || lib.hasPrefix "${a}/" b || lib.hasPrefix "${b}/" a;

  overlapping =
    paths:
    let
      indexed = lib.imap0 (i: p: { inherit i; inherit (p) path; }) paths;
    in
    lib.concatMap (
      a: lib.concatMap (b: lib.optional (a.i < b.i && overlaps a.path b.path) "${a.path} vs ${b.path}") indexed
    ) indexed;

  skillsOf = src: builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir "${src.outPath}/skills"));

  templateChecks =
    name: t:
    let
      at = "sam.agentRuntime.templates.${name}";
      repos = lib.mapAttrsToList (n: r: r // { name = n; }) t.repositories;
      identities = map (r: "${r.github}#${r.ref.type}:${r.ref.value}") repos;
    in
    lib.concatMap (r: [
      {
        assertion = r.ref.type != "commit" || builtins.match "^[0-9a-f]{40}$" r.ref.value != null;
        message = "${at}.repositories.${r.name}: a commit ref must be a 40-hex revision, got `${r.ref.value}`";
      }
      {
        assertion = r.ref.type != "commit" || r.resolve == "lock";
        message = "${at}.repositories.${r.name}: a commit needs no resolution; use resolve = \"lock\"";
      }
      {
        assertion = r.ref.type != "commit" || r.lock == null || r.lock.rev == r.ref.value;
        message = "${at}.repositories.${r.name}: lock.rev ${toString (r.lock.rev or "")} differs from the commit ${r.ref.value}";
      }
      {
        assertion = r.ref.type == "commit" || r.resolve != "lock" || r.lock != null;
        message = "${at}.repositories.${r.name}: a ${r.ref.type} with resolve = \"lock\" needs `lock = inputs.<name>` (a flake input pinned to that ${r.ref.type})";
      }
      {
        assertion = r.resolve != "assignment" || r.lock == null;
        message = "${at}.repositories.${r.name}: resolve = \"assignment\" records the revision per run; drop `lock`";
      }
      {
        assertion = lib.hasPrefix "${t.filesystem.workspace}/" r.path;
        message = "${at}.repositories.${r.name}.path ${r.path} is not under filesystem.workspace ${t.filesystem.workspace}";
      }
    ]) repos
    ++ [
      {
        assertion = lib.unique identities == identities;
        message = "${at}: duplicate repository identity (same github + ref): ${lib.concatStringsSep ", " identities}";
      }
      {
        assertion = overlapping (pathsOf t) == [ ];
        message = "${at}: instance paths overlap: ${lib.concatStringsSep "; " (overlapping (pathsOf t))}";
      }
      {
        assertion = t.skillsSource.outPath != null;
        message = "${at}.skillsSource needs outPath (pass the flake input itself)";
      }
      {
        assertion = (t.network.egress == "allowlist") == (t.network.allow != [ ]);
        message = "${at}.network: egress = \"allowlist\" needs a non-empty `allow`, and `allow` needs egress = \"allowlist\"";
      }
    ]
    ++ lib.mapAttrsToList (n: s: {
      assertion = s.source.outPath != null && builtins.pathExists "${s.source.outPath}/skills/${n}/SKILL.md";
      message = "${at}.skills.${n}: not in skills source ${s.source.rev} (known: ${lib.concatStringsSep ", " (skillsOf s.source)})";
    }) t.skills
    ++ map (m: {
      assertion = builtins.any (root: m.hostPath == root || lib.hasPrefix "${root}/" m.hostPath) cfg.host.allowedMountRoots;
      message = "${at}.filesystem.mounts: host path ${m.hostPath} is not under an allowed mount root (${lib.concatStringsSep ", " cfg.host.allowedMountRoots}); unauthorized host mount";
    }) t.filesystem.mounts;

  checks =
    lib.concatLists (lib.mapAttrsToList templateChecks cfg.templates)
    ++ map (n: {
      assertion = cfg.templates ? ${n};
      message = "sam.agentRuntime.host.eligibleTemplates names unknown template `${n}` (declared: ${lib.concatStringsSep ", " (builtins.attrNames cfg.templates)})";
    }) cfg.host.eligibleTemplates;

  failures = map (c: c.message) (builtins.filter (c: !c.assertion) checks);

  # The manifest is unreachable while a check fails, so a consumer that reads
  # it without building a system toplevel still sees the message.
  guarded = v: if failures == [ ] then v else throw "agent-runtime: ${lib.concatStringsSep "\n" failures}";

  sourceRef = s: {
    inherit (s) rev narHash;
    storePath = if s.outPath == null then null else "${s.outPath}";
  };

  manifestOf =
    name: t:
    let
      body = {
        schemaVersion = 1;
        kind = "agent-runtime-template";
        template.name = name;
        role = { inherit (t.role) name harness; };
        sources = lib.mapAttrs (_: r: {
          inherit (r) github resolve path writable;
          ref = { inherit (r.ref) type value; };
          locked =
            if r.ref.type == "commit" then
              { rev = r.ref.value; narHash = r.lock.narHash or null; storePath = if r.lock == null then null else (sourceRef r.lock).storePath; }
            else if r.lock == null then
              null
            else
              sourceRef r.lock;
        }) t.repositories;
        skills = lib.mapAttrs (n: s: {
          source = sourceRef s.source;
          path = "${s.source.outPath}/skills/${n}";
        }) t.skills;
        packages = map (p: {
          name = lib.getName p;
          storePath = "${p}";
        }) t.packages;
        filesystem = {
          inherit (t.filesystem) workspace mounts;
          home = { inherit (t.filesystem.home) path sizeMiB inodes; };
          tmp = { inherit (t.filesystem.tmp) path sizeMiB inodes; };
          cache = { inherit (t.filesystem.cache) path sizeMiB inodes; };
          output = { inherit (t.filesystem.output) path sizeMiB inodes; };
        };
        policies = {
          resources = { inherit (t.resources) cpus memoryMiB tasksMax timeoutMinutes; };
          network = { inherit (t.network) egress allow; };
          inherit (t) capabilities;
        };
      };
      lockedSources = {
        sources = lib.mapAttrs (_: s: if s.locked == null then null else s.locked.rev) body.sources;
        skills = lib.mapAttrs (_: s: s.source.rev) body.skills;
      };
    in
    body
    // {
      digests = {
        template = builtins.hashString "sha256" (builtins.toJSON body);
        lockedSources = builtins.hashString "sha256" (builtins.toJSON lockedSources);
      };
    };
in
{
  options.sam.agentRuntime = {
    templates = mkOption {
      type = types.attrsOf template;
      default = { };
      description = "Named templates; each describes possible ephemeral instances, never a booted container.";
    };

    host = {
      enable = mkEnableOption "admitting agent-runtime instances on this host";
      eligibleTemplates = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Templates this host may instantiate.";
      };
      maxConcurrentInstances = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Aggregate instance cap for this host.";
      };
      reserve = {
        memoryMiB = mkOption {
          type = types.ints.positive;
          default = 2048;
          description = "Host memory kept free of instances.";
        };
        diskMiB = mkOption {
          type = types.ints.positive;
          default = 10240;
          description = "Host disk kept free of instances.";
        };
      };
      allowedMountRoots = mkOption {
        type = types.listOf normalizedPath;
        default = [ ];
        description = "Host directories templates may bind-mount from.";
      };
    };

    manifestData = mkOption {
      type = types.attrsOf types.attrs;
      readOnly = true;
      description = "Evaluated `agent-runtime-template` manifests (schemaVersion 1), per template.";
    };
    manifests = mkOption {
      type = types.attrsOf types.package;
      readOnly = true;
      description = "Each manifest as a JSON file; its store references pin the template closure.";
    };
    manifestDir = mkOption {
      type = types.package;
      readOnly = true;
      description = "All manifests as `<name>.json` in one directory.";
    };
  };

  config = {
    assertions = checks;

    sam.agentRuntime = {
      manifestData = guarded (lib.mapAttrs manifestOf cfg.templates);
      manifests = lib.mapAttrs (
        n: m: pkgs.writeText "agent-runtime-${n}.json" (builtins.toJSON m)
      ) cfg.manifestData;
      manifestDir = pkgs.linkFarm "agent-runtime-manifests" (
        lib.mapAttrsToList (n: m: {
          name = "${n}.json";
          path = m;
        }) cfg.manifests
      );
    };
  };
}
