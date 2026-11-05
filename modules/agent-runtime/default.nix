# Typed agent-runtime templates: what an ephemeral nspawn instance would
# contain (sources, skills, packages, filesystem, policy) and the versioned
# manifest later milestones consume. Nothing here starts a container.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.sam.agentRuntime;

  sha40 = types.strMatching "^[0-9a-f]{40}$";
  narHash = types.strMatching "^sha256-[A-Za-z0-9+/]{43}=$";
  storePath = types.strMatching "^/nix/store/[a-z0-9]{32}-[^/]+$";
  githubRepo = types.strMatching "^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9._-]*$";
  dnsName = types.strMatching "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$";
  dnsLabel = types.strMatching "^[a-z0-9][a-z0-9-]*$";

  # A git branch or tag name the runtime may hand to git: no option-like
  # leading dash, no `..`, `//`, `@{`, trailing `/` or `.lock`.
  refName = types.mkOptionType {
    name = "gitRefName";
    description = "git ref name (letters, digits, `._/-`; no leading `-`, `..`, `//`, `@{`, trailing `/` or `.lock`)";
    check =
      r:
      builtins.isString r
      && builtins.match "^[A-Za-z0-9][A-Za-z0-9._/-]*$" r != null
      && builtins.match ".*(\\.\\.|//|@\\{).*" r == null
      && builtins.match ".*(/|\\.lock)$" r == null;
    merge = lib.mergeEqualOption;
  };

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

  # Paths the runtime itself owns inside an instance; no template path may sit on or under them.
  reservedRoots = [ "/nix" "/etc" "/proc" "/sys" "/dev" "/run" "/usr" "/bin" ];

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
        type = narHash;
        description = "NAR hash of the fetched tree.";
      };
      outPath = mkOption {
        type = storePath;
        description = "Store path of the fetched tree (a path literal is refused: it would copy into the store).";
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
          description = "Writable byte budget (MiB); admission input for #137.";
        };
        inodes = mkOption {
          type = types.ints.positive;
          default = 100000;
          description = "Writable inode budget; admission input for #137.";
        };
      };
    };

  mountRoot = types.coercedTo types.str (path: { inherit path; }) (
    types.submodule {
      options = {
        path = mkOption {
          type = normalizedPath;
          description = "Host directory templates may bind-mount from.";
        };
        writable = mkOption {
          type = types.bool;
          default = false;
          description = "Whether a template may bind it read-write.";
        };
      };
    }
  );

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
          type = refName;
          description = "Branch or tag name, or the 40-hex commit.";
        };
      };
      resolve = mkOption {
        type = types.enum [ "lock" "assignment" ];
        default = "lock";
        description = ''
          `lock`: the immutable revision is `lock.rev`, from the flake lock. `assignment`: an
          explicit opt-in (#136) to resolve a moving branch or tag once per run; the revision then
          lives in that run's manifest, never here.
        '';
      };
      lock = mkOption {
        type = types.nullOr lockedSource;
        default = null;
        description = ''
          The pinned flake input that is the authority for a locked branch or tag: the manifest
          records `lock.rev`, and `ref.value` is the label the lock was taken at (not verified
          against the input). Optional for a commit, where `lock.rev` must equal the commit.
        '';
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
    { config, ... }:
    {
      options = {
        role = {
          name = mkOption {
            type = dnsLabel;
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
                defaultText = lib.literalExpression "config.sam.agentRuntime.templates.<name>.skillsSource";
                description = "Pinned skills tree this skill is read from.";
              };
            }
          );
          default = { };
          description = "Explicitly named skills; a name that is not a directory of `<source>/skills` with a `SKILL.md` fails evaluation.";
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
                    description = "Host directory; must lie under a `host.allowedMountRoots` entry (#137 canonicalizes it before binding).";
                  };
                  path = mkOption {
                    type = normalizedPath;
                    description = "Mount point inside the instance.";
                  };
                  readOnly = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Bind read-only; read-write needs a root with `writable = true`.";
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
            description = "CPU quota in whole cores (cgroup ceiling, #137).";
          };
          memoryMiB = mkOption {
            type = types.ints.positive;
            description = "Hard memory ceiling (MiB; cgroup ceiling, #137).";
          };
          tasksMax = mkOption {
            type = types.ints.positive;
            default = 512;
            description = "Task (pid/thread) ceiling (cgroup ceiling, #137).";
          };
          timeoutMinutes = mkOption {
            type = types.ints.positive;
            description = "Wall-clock budget of one run (#138).";
          };
        };
        network = {
          egress = mkOption {
            type = types.enum [ "none" "allowlist" ];
            default = "none";
            description = "Private network namespace: no egress, or only the listed hosts (#137).";
          };
          allow = mkOption {
            type = types.listOf dnsName;
            default = [ ];
            description = "Egress DNS names when `egress = \"allowlist\"` (no IP literals, no single-label names).";
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
    ++ lib.optional (t.repositories == { }) { path = t.filesystem.workspace; }
    ++ lib.mapAttrsToList (_: r: { inherit (r) path; }) t.repositories
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

  reserved = paths: builtins.filter (p: builtins.any (root: overlaps root p.path) reservedRoots) paths;

  skillsOf =
    src:
    let
      dir = "${src.outPath}/skills";
    in
    if builtins.pathExists dir then
      builtins.attrNames (lib.filterAttrs (_: t: t == "directory") (builtins.readDir dir))
    else
      [ ];

  duplicates = xs: lib.filter (x: lib.count (y: y == x) xs > 1) (lib.unique xs);

  mountRootFor = m: lib.findFirst (root: overlaps root.path m.hostPath && lib.hasPrefix root.path m.hostPath) null cfg.host.allowedMountRoots;

  templateChecks =
    name: t:
    let
      at = "sam.agentRuntime.templates.${name}";
      repos = lib.mapAttrsToList (n: r: r // { name = n; }) t.repositories;
      identities = map (r: "${r.github}#${r.ref.type}:${r.ref.value}") repos;
    in
    lib.concatMap (r: [
      {
        assertion = r.ref.type != "commit" || sha40.check r.ref.value;
        message = "${at}.repositories.${r.name}: a commit ref must be a 40-hex revision, got `${r.ref.value}`";
      }
      {
        assertion = r.ref.type != "commit" || r.resolve == "lock";
        message = "${at}.repositories.${r.name}: a commit needs no resolution; use resolve = \"lock\"";
      }
      {
        assertion = r.ref.type != "commit" || r.lock == null || r.lock.rev == r.ref.value;
        message = "${at}.repositories.${r.name}: lock.rev ${r.lock.rev or ""} differs from the commit ${r.ref.value}";
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
        assertion = duplicates identities == [ ];
        message = "${at}: duplicate repository identity (same github + ref): ${lib.concatStringsSep ", " (duplicates identities)}";
      }
      {
        assertion = overlapping (pathsOf t) == [ ];
        message = "${at}: instance paths overlap: ${lib.concatStringsSep "; " (overlapping (pathsOf t))}";
      }
      {
        assertion = reserved (pathsOf t) == [ ];
        message = "${at}: instance path on a reserved root (${lib.concatStringsSep " " reservedRoots}): ${lib.concatStringsSep ", " (map (p: p.path) (reserved (pathsOf t)))}";
      }
      {
        assertion = (t.network.egress == "allowlist") == (t.network.allow != [ ]);
        message = "${at}.network: egress = \"allowlist\" needs a non-empty `allow`, and `allow` needs egress = \"allowlist\"";
      }
    ]
    ++ lib.mapAttrsToList (n: s: {
      assertion = builtins.elem n (skillsOf s.source) && builtins.pathExists "${s.source.outPath}/skills/${n}/SKILL.md";
      message = "${at}.skills.${n}: not in skills source ${s.source.rev} (known: ${lib.concatStringsSep ", " (skillsOf s.source)})";
    }) t.skills
    ++ lib.concatMap (m: [
      {
        assertion = mountRootFor m != null;
        message = "${at}.filesystem.mounts: host path ${m.hostPath} is not under an allowed mount root (${lib.concatStringsSep ", " (map (r: r.path) cfg.host.allowedMountRoots)}); unauthorized host mount";
      }
      {
        assertion = m.readOnly || (mountRootFor m).writable or false;
        message = "${at}.filesystem.mounts: ${m.hostPath} is bound read-write but its allowed mount root is read-only";
      }
    ]) t.filesystem.mounts;

  checks =
    lib.concatLists (lib.mapAttrsToList templateChecks cfg.templates)
    ++ map (n: {
      assertion = cfg.templates ? ${n};
      message = "sam.agentRuntime.host.eligibleTemplates names unknown template `${n}` (declared: ${lib.concatStringsSep ", " (builtins.attrNames cfg.templates)})";
    }) cfg.host.eligibleTemplates
    ++ [
      {
        assertion = cfg.host.eligibleTemplates == [ ] || cfg.host.enable;
        message = "sam.agentRuntime.host.eligibleTemplates is set but host.enable is false";
      }
    ];

  failures = map (c: c.message) (builtins.filter (c: !c.assertion) checks);

  # The manifest is unreachable while a check fails, so a consumer that reads
  # it without building a system toplevel still sees the message.
  guarded = v: if failures == [ ] then v else throw "agent-runtime: ${lib.concatStringsSep "\n" failures}";

  sourceRef = s: {
    inherit (s) rev narHash;
    storePath = s.outPath;
  };

  budget = m: { inherit (m) path sizeMiB inodes; };

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
            if r.lock != null then
              sourceRef r.lock
            else if r.ref.type == "commit" then
              { rev = r.ref.value; narHash = null; storePath = null; }
            else
              null;
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
          home = budget t.filesystem.home;
          tmp = budget t.filesystem.tmp;
          cache = budget t.filesystem.cache;
          output = budget t.filesystem.output;
        };
        policies = {
          resources = { inherit (t.resources) cpus memoryMiB tasksMax timeoutMinutes; };
          network = {
            inherit (t.network) egress;
            allow = lib.naturalSort (lib.unique t.network.allow);
          };
          capabilities = lib.naturalSort (lib.unique t.capabilities);
        };
      };
      lockedSources = {
        sources = lib.mapAttrs (_: s: if s.locked == null then null else { inherit (s.locked) rev narHash; }) body.sources;
        skills = lib.mapAttrs (_: s: { inherit (s.source) rev narHash; }) body.skills;
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
      enable = mkEnableOption "admitting agent-runtime instances on this host (required before any template is eligible; #138 starts nothing without it)";
      eligibleTemplates = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Templates this host may instantiate (#138).";
      };
      maxConcurrentInstances = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "Aggregate instance cap for this host (#138).";
      };
      reserve = {
        memoryMiB = mkOption {
          type = types.ints.positive;
          default = 2048;
          description = "Host memory kept free of instances (admission, #137).";
        };
        diskMiB = mkOption {
          type = types.ints.positive;
          default = 10240;
          description = "Host disk kept free of instances (admission, #137).";
        };
      };
      allowedMountRoots = mkOption {
        type = types.listOf mountRoot;
        default = [ ];
        description = "Host directories templates may bind-mount from; a bare string is a read-only root.";
      };
    };

    manifestData = mkOption {
      type = types.lazyAttrsOf types.raw;
      readOnly = true;
      description = "Evaluated `agent-runtime-template` manifests (schemaVersion 1), per template.";
    };
    manifestDir = mkOption {
      type = types.package;
      readOnly = true;
      description = "All manifests as `<name>.json` in one directory; its store references pin every template closure.";
    };
  };

  config = {
    assertions = checks;

    sam.agentRuntime = {
      manifestData = guarded (lib.mapAttrs manifestOf cfg.templates);
      manifestDir = pkgs.linkFarm "agent-runtime-manifests" (
        lib.mapAttrsToList (n: m: {
          name = "${n}.json";
          path = pkgs.writeText "agent-runtime-${n}.json" (builtins.toJSON m);
        }) cfg.manifestData
      );
    };
  };
}
