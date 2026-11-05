# Typed agent-runtime templates: what an ephemeral nspawn instance would
# contain (sources, skills, packages, filesystem, policy) and the versioned
# manifest later milestones consume. Nothing here starts a container.
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption types;
  cfg = config.sam.agentRuntime;
  json = pkgs.formats.json { };

  sha40 = types.strMatching "^[0-9a-f]{40}$";
  narHash = types.strMatching "^sha256-[A-Za-z0-9+/]{43}=$";
  storePath = types.strMatching "^/nix/store/[a-z0-9]{32}-[^/]+$";
  githubRepo = types.strMatching "^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9._-]*$";
  labelPattern = "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$";
  dnsLabel = types.strMatching labelPattern;
  isLabel = s: lib.match labelPattern s != null;

  dnsName = types.mkOptionType {
    name = "dnsName";
    description = "DNS name (lowercase labels of at most 63 chars and a TLD, at most 253 chars; no IP literal, no single label)";
    check =
      n:
      lib.isString n
      && lib.stringLength n <= 253
      && lib.match "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$" n != null
      && lib.all (l: lib.stringLength l <= 63) (lib.splitString "." n);
    merge = lib.mergeEqualOption;
  };

  # Handed to git by #136: an option-like leading dash would be parsed as a flag.
  refName = types.mkOptionType {
    name = "gitRefName";
    description = "git ref name (starts with a letter or digit; components of letters, digits, `._-`, none starting with `.` or ending with `.` or `.lock`; no `..` or `//`)";
    check =
      r:
      lib.isString r
      && lib.match "^[A-Za-z0-9][A-Za-z0-9._/-]*$" r != null
      && lib.match ".*\\.\\..*" r == null
      && lib.all (c: c != "" && lib.match "^\\..*|.*(\\.lock|\\.)$" c == null) (lib.splitString "/" r);
    merge = lib.mergeEqualOption;
  };

  normalizedPath = types.mkOptionType {
    name = "normalizedPath";
    description = "absolute normalized path (no `.`/`..` components, no `//`, no trailing slash)";
    check =
      p:
      lib.isString p
      && lib.match "^(/[A-Za-z0-9._-]+)+$" p != null
      && !lib.any (c: c == "." || c == "..") (lib.splitString "/" p);
    merge = lib.mergeEqualOption;
  };

  within = root: p: p == root || lib.hasPrefix "${root}/" p;
  overlaps = a: b: within a b || within b a;

  # Owned by the runtime inside an instance.
  reservedRoots = [
    "/nix"
    "/etc"
    "/proc"
    "/sys"
    "/dev"
    "/run"
    "/usr"
    "/bin"
    "/lib"
    "/lib64"
    "/sbin"
    "/boot"
    "/root"
    "/var/lib"
    "/var/run"
  ];
  # Host state no template may reach, nor any directory containing it.
  deniedHostRoots = [
    "/nix"
    "/etc"
    "/proc"
    "/sys"
    "/dev"
    "/run"
    "/var/run"
    "/var/lib"
    "/var/tmp"
    "/var/log"
    "/usr"
    "/tmp"
    "/boot"
    "/root"
    "/home"
  ];

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
      # The issue's literal shape, kept for schema stability.
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
          The pinned flake input that is the authority for a locked ref: the manifest records
          `lock.rev`, and `ref.value` is the label the lock was taken at (not verified against the
          input). Required for a commit, where `lock.rev` must equal it; forbidden with
          `resolve = "assignment"`.
        '';
      };
      path = mkOption {
        type = normalizedPath;
        description = "Checkout path inside the instance, strictly under `filesystem.workspace`.";
      };
      writable = mkOption {
        type = types.bool;
        default = false;
        description = "Private writable copy (true) or read-only store path (false). Never implies push rights.";
      };
      access = mkOption {
        type = types.enum [ "public" "private" ];
        default = "public";
        description = ''
          `public`: prefetched anonymously, `GH_TOKEN` is ignored. `private`: the assignment-time
          prefetch needs `GH_TOKEN` in the assigner's environment and fails closed without it; the
          token never enters a manifest or the store. Only `resolve = "assignment"` prefetches, so a
          locked source must stay `public` (its lock was fetched with the evaluator's credentials).
          Either way the tree lands world-readable in the host's `/nix/store`.
        '';
      };
    };
  };

  template = types.submodule {
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
        description = "Named GitHub sources materialized inside the instance (names are lowercase labels).";
      };
      skillsSource = mkOption {
        type = lockedSource;
        description = "The pinned skills tree (`inputs.skills`); every skill below is a directory of its `skills/`.";
      };
      skills = mkOption {
        type = types.attrsOf (types.submodule { });
        default = { };
        description = "Explicitly named skills (`skills.<dir-name> = { }`); a name without `<skillsSource>/skills/<name>/SKILL.md` fails evaluation.";
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
          description = "Parent of every repository path; no other mount may sit on or under it.";
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
                  description = "Host directory under a `host.allowedMountRoots` entry (#137 resolves symlinks and re-checks before binding).";
                };
                path = mkOption {
                  type = normalizedPath;
                  description = "Mount point inside the instance.";
                };
                writable = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Bind read-write; needs the most specific covering root to be `writable`. Shared by every instance that binds it.";
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
      network.allow = mkOption {
        type = types.nullOr (types.nonEmptyListOf dnsName);
        default = null;
        description = "Private network namespace: `null` is no egress; a non-empty list is the egress allowlist (#137 enforces at resolution time).";
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
  };

  # Every path an instance mounts; repositories are checked against the workspace by their
  # own rule, so that one pair is exempt from the overlap check.
  pathsOf =
    t:
    [ t.filesystem.home t.filesystem.tmp t.filesystem.cache t.filesystem.output ]
    ++ [ { path = t.filesystem.workspace; workspace = true; } ]
    ++ map (r: { inherit (r) path; repo = true; }) (lib.attrValues t.repositories)
    ++ t.filesystem.mounts;

  overlapping =
    paths:
    let
      indexed = lib.imap0 (i: p: p // { inherit i; }) paths;
      exempt = a: b: (a.workspace or false && b.repo or false) || (b.workspace or false && a.repo or false);
    in
    lib.concatMap (
      a:
      lib.concatMap (
        b: lib.optional (a.i < b.i && !exempt a b && overlaps a.path b.path) "${a.path} vs ${b.path}"
      ) indexed
    ) indexed;

  onRoots = roots: paths: lib.filter (p: lib.any (root: overlaps root p.path) roots) paths;

  skillsOf =
    src:
    let
      dir = "${src.outPath}/skills";
    in
    if lib.pathIsDirectory dir then
      lib.attrNames (lib.filterAttrs (_: t: t == "directory" || t == "symlink") (lib.readDir dir))
    else
      [ ];

  duplicates = xs: lib.filter (x: lib.count (y: y == x) xs > 1) (lib.unique xs);

  # The most specific allowed root covering a host path decides, whatever the list order.
  mountRootFor =
    hostPath:
    let
      covering = lib.filter (root: within root.path hostPath) cfg.host.allowedMountRoots;
    in
    if covering == [ ] then null else lib.last (lib.sortOn (r: lib.stringLength r.path) covering);

  repoChecks =
    at: workspace: r: [
      {
        assertion = r.ref.type != "commit" || r.resolve == "lock";
        message = "${at}: a commit needs no resolution; use resolve = \"lock\"";
      }
      {
        assertion = r.resolve != "lock" || r.lock != null;
        message = "${at}: a ${r.ref.type} with resolve = \"lock\" needs `lock = inputs.<input>` (a flake input pinned to it)";
      }
      {
        assertion = r.ref.type != "commit" || r.lock == null || r.lock.rev == r.ref.value;
        message = "${at}: lock.rev ${r.lock.rev or ""} differs from the commit ${r.ref.value} (the 40-hex revision)";
      }
      {
        assertion = r.resolve != "assignment" || r.lock == null;
        message = "${at}: resolve = \"assignment\" records the revision per run; drop `lock`";
      }
      {
        assertion = r.access == "public" || r.resolve == "assignment";
        message = "${at}: access = \"private\" is consumed only by an assignment-time prefetch; a locked source is fetched by the flake lock's own credentials";
      }
      {
        assertion = lib.hasPrefix "${workspace}/" r.path;
        message = "${at}.path ${r.path} is not under filesystem.workspace ${workspace}";
      }
    ];

  mountChecks =
    at: m:
    let
      root = mountRootFor m.hostPath;
      roots = lib.concatStringsSep ", " (map (r: r.path) cfg.host.allowedMountRoots);
    in
    [
      {
        assertion = root != null;
        message = "${at}: host path ${m.hostPath} is not under an allowed mount root (${roots}); unauthorized host mount";
      }
      {
        assertion = !m.writable || root == null || root.writable;
        message = "${at}: ${m.hostPath} is bound read-write but its allowed mount root ${root.path or ""} is read-only";
      }
    ];

  templateChecks =
    name: t:
    let
      at = "sam.agentRuntime.templates.${name}";
      repos = lib.mapAttrsToList (n: r: r // { name = n; }) t.repositories;
      identities = map (r: "${lib.toLower r.github}#${r.ref.type}:${r.ref.value}") repos;
      paths = pathsOf t;
      overlapsFound = overlapping paths;
      onReserved = map (p: p.path) (onRoots reservedRoots paths);
      known = skillsOf t.skillsSource;
      badNames = lib.filter (n: !isLabel n) (lib.attrNames t.repositories);
    in
    lib.concatMap (r: repoChecks "${at}.repositories.${r.name}" t.filesystem.workspace r) repos
    ++ [
      {
        assertion = isLabel name;
        message = "sam.agentRuntime.templates: template name `${name}` must be lowercase letters, digits and `-`";
      }
      {
        assertion = badNames == [ ];
        message = "${at}.repositories: names must be lowercase letters, digits and `-`: ${lib.concatStringsSep ", " badNames}";
      }
      {
        assertion = duplicates identities == [ ];
        message = "${at}: duplicate repository identity (same github + ref): ${lib.concatStringsSep ", " (duplicates identities)}";
      }
      {
        assertion = overlapsFound == [ ];
        message = "${at}: instance paths overlap: ${lib.concatStringsSep "; " overlapsFound}";
      }
      {
        assertion = onReserved == [ ];
        message = "${at}: instance path on a reserved root (${lib.concatStringsSep " " reservedRoots}): ${lib.concatStringsSep ", " onReserved}";
      }
    ]
    # Membership first: a name with `/` must never reach the path below.
    ++ lib.mapAttrsToList (n: _: {
      assertion = lib.elem n known && lib.pathExists "${t.skillsSource.outPath}/skills/${n}/SKILL.md";
      message = "${at}.skills.${n}: not in skills source ${t.skillsSource.rev} (known: ${lib.concatStringsSep ", " known})";
    }) t.skills
    ++ lib.concatLists (lib.imap0 (i: mountChecks "${at}.filesystem.mounts.${toString i}") t.filesystem.mounts);

  rootPaths = map (r: r.path) cfg.host.allowedMountRoots;
  deniedRoots = map (r: r.path) (onRoots deniedHostRoots cfg.host.allowedMountRoots);

  checks =
    lib.concatLists (lib.mapAttrsToList templateChecks cfg.templates)
    ++ map (n: {
      assertion = cfg.templates ? ${n};
      message = "sam.agentRuntime.host.eligibleTemplates names unknown template `${n}` (declared: ${lib.concatStringsSep ", " (lib.attrNames cfg.templates)})";
    }) cfg.host.eligibleTemplates
    ++ [
      {
        assertion = cfg.host.eligibleTemplates == [ ] || cfg.host.enable;
        message = "sam.agentRuntime.host.eligibleTemplates is set but host.enable is false";
      }
      {
        assertion = deniedRoots == [ ];
        message = "sam.agentRuntime.host.allowedMountRoots: ${lib.concatStringsSep ", " deniedRoots} is on a denied host root (${lib.concatStringsSep " " deniedHostRoots})";
      }
      {
        assertion = duplicates rootPaths == [ ];
        message = "sam.agentRuntime.host.allowedMountRoots: duplicate root ${lib.concatStringsSep ", " (duplicates rootPaths)} (declare it once with the intended `writable`)";
      }
    ];

  failures = map (c: c.message) (lib.filter (c: !c.assertion) checks);

  # The manifest is unreachable while a check fails, so a consumer that reads
  # it without building a system toplevel still sees the message.
  guarded = v: if failures == [ ] then v else throw "agent-runtime: ${lib.concatStringsSep "\n" failures}";

  sourceRef = s: {
    inherit (s) rev narHash;
    storePath = s.outPath;
  };

  # An added field moves `digests.template` and stays schemaVersion 1 (a reader keys on
  # names, not shape); a removed, renamed or retyped field bumps `schemaVersion`.
  manifestOf =
    name: t:
    let
      body = {
        schemaVersion = 1;
        kind = "agent-runtime-template";
        template.name = name;
        inherit (t) role filesystem;
        sources = lib.mapAttrs (_: r: {
          inherit (r) github ref resolve access path writable;
          locked = lib.mapNullable sourceRef r.lock;
        }) t.repositories;
        skills = {
          source = sourceRef t.skillsSource;
          names = lib.mapAttrs (n: _: { path = "${t.skillsSource.outPath}/skills/${n}"; }) t.skills;
        };
        packages = map (p: {
          name = lib.getName p;
          storePath = "${p}";
        }) t.packages;
        policies = {
          inherit (t) resources;
          privateSources = lib.naturalSort (lib.attrNames (lib.filterAttrs (_: r: r.access == "private") t.repositories));
          network = {
            egress = if t.network.allow == null then "none" else "allowlist";
            allow = lib.naturalSort (lib.unique (lib.optionals (t.network.allow != null) t.network.allow));
          };
          capabilities = lib.naturalSort (lib.unique t.capabilities);
        };
      };
      lockedSources = {
        sources = lib.mapAttrs (_: s: lib.mapNullable (l: { inherit (l) rev narHash; }) s.locked) body.sources;
        skills = { inherit (body.skills.source) rev narHash; };
      };
    in
    body
    // {
      digests = {
        template = lib.hashString "sha256" (lib.toJSON body);
        lockedSources = lib.hashString "sha256" (lib.toJSON lockedSources);
      };
    };
in
{
  options.sam.agentRuntime = {
    templates = mkOption {
      type = types.attrsOf template;
      default = { };
      description = "Named templates (names are lowercase labels); each describes possible ephemeral instances, never a booted container.";
    };

    host = {
      enable = mkEnableOption "admitting agent-runtime instances on this host (required before any template is eligible; #138 starts nothing without it)";
      eligibleTemplates = mkOption {
        type = types.listOf dnsLabel;
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
        description = "Host directories templates may bind-mount from (none by default); a bare string is a read-only root; each path once; never on or containing ${lib.concatStringsSep ", " deniedHostRoots}.";
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
          path = json.generate "agent-runtime-${n}.json" m;
        }) cfg.manifestData
      );
    };
  };
}
