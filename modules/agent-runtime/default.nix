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
  dnsLabel = types.strMatching "^[a-z0-9][a-z0-9-]*$";

  dnsName = types.mkOptionType {
    name = "dnsName";
    description = "DNS name (lowercase labels and a TLD; no IP literal, no single label)";
    check = n: builtins.isString n && builtins.match "^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$" n != null;
    merge = lib.mergeEqualOption;
  };

  # Handed to git by #136: an option-like leading dash would be parsed as a flag.
  refName = types.mkOptionType {
    name = "gitRefName";
    description = "git ref name (starts with a letter or digit; components of letters, digits, `._-`, none starting with `.` or ending with `.` or `.lock`; no `..` or `//`)";
    check =
      r:
      builtins.isString r
      && builtins.match "^[A-Za-z0-9][A-Za-z0-9._/-]*$" r != null
      && builtins.match ".*\\.\\..*" r == null
      && builtins.all (c: c != "" && builtins.match "^\\..*|.*(\\.lock|\\.)$" c == null) (lib.splitString "/" r);
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

  within = root: p: p == root || lib.hasPrefix "${root}/" p;
  overlaps = a: b: within a b || within b a;

  # Owned by the runtime inside an instance, or holding host state no template may reach.
  reservedRoots = [ "/nix" "/etc" "/proc" "/sys" "/dev" "/run" "/usr" "/bin" "/lib" "/lib64" "/sbin" "/boot" "/root" "/var/lib" ];
  deniedHostRoots = [ "/nix" "/etc" "/proc" "/sys" "/dev" "/run" "/boot" "/root" "/home" ];

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
          The pinned flake input that is the authority for a locked ref: the manifest records
          `lock.rev`, and `ref.value` is the label the lock was taken at (not verified against the
          input). Required for a commit, where `lock.rev` must equal it; forbidden with
          `resolve = "assignment"`.
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
        description = "Named GitHub sources materialized inside the instance.";
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
                  description = "Host directory under a `host.allowedMountRoots` entry (#137 resolves symlinks and re-checks before binding).";
                };
                path = mkOption {
                  type = normalizedPath;
                  description = "Mount point inside the instance.";
                };
                writable = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Bind read-write; needs the most specific covering root to be `writable`.";
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
          description = "Private network namespace: no egress, or only the listed hosts (#137 enforces at resolution time).";
        };
        allow = mkOption {
          type = types.listOf dnsName;
          default = [ ];
          description = "Egress DNS names when `egress = \"allowlist\"`.";
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
  };

  # Every repository path sits under the workspace, so the workspace itself joins the overlap
  # set only when there is none to represent it.
  pathsOf =
    t:
    [ t.filesystem.home t.filesystem.tmp t.filesystem.cache t.filesystem.output ]
    ++ lib.optional (t.repositories == { }) { path = t.filesystem.workspace; }
    ++ lib.mapAttrsToList (_: r: { inherit (r) path; }) t.repositories
    ++ t.filesystem.mounts;

  overlapping =
    paths:
    let
      indexed = lib.imap0 (i: p: { inherit i; inherit (p) path; }) paths;
    in
    lib.concatMap (
      a: lib.concatMap (b: lib.optional (a.i < b.i && overlaps a.path b.path) "${a.path} vs ${b.path}") indexed
    ) indexed;

  onRoots = roots: paths: builtins.filter (p: builtins.any (root: overlaps root p.path) roots) paths;

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

  # The most specific allowed root covering a host path decides, whatever the list order.
  mountRootFor =
    hostPath:
    let
      covering = builtins.filter (root: within root.path hostPath) cfg.host.allowedMountRoots;
    in
    lib.findFirst (_: true) null (lib.sort (a: b: lib.stringLength a.path > lib.stringLength b.path) covering);

  repoChecks =
    at: r: [
      {
        assertion = r.ref.type != "commit" || sha40.check r.ref.value;
        message = "${at}: a commit ref must be a 40-hex revision, got `${r.ref.value}`";
      }
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
        message = "${at}: lock.rev ${r.lock.rev or ""} differs from the commit ${r.ref.value}";
      }
      {
        assertion = r.resolve != "assignment" || r.lock == null;
        message = "${at}: resolve = \"assignment\" records the revision per run; drop `lock`";
      }
    ];

  mountChecks =
    at: m:
    let
      root = mountRootFor m.hostPath;
    in
    [
      {
        assertion = root != null;
        message = "${at}: host path ${m.hostPath} is not under an allowed mount root (${lib.concatStringsSep ", " (map (r: r.path) cfg.host.allowedMountRoots)}); unauthorized host mount";
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
      identities = map (r: "${r.github}#${r.ref.type}:${r.ref.value}") repos;
      paths = pathsOf t;
      overlapsFound = overlapping paths;
      onReserved = map (p: p.path) (onRoots reservedRoots paths);
      known = skillsOf t.skillsSource;
    in
    lib.concatMap (r: repoChecks "${at}.repositories.${r.name}" r) repos
    ++ lib.concatMap (r: [
      {
        assertion = within t.filesystem.workspace r.path && r.path != t.filesystem.workspace;
        message = "${at}.repositories.${r.name}.path ${r.path} is not under filesystem.workspace ${t.filesystem.workspace}";
      }
    ]) repos
    ++ [
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
      {
        assertion = t.network.egress != "allowlist" || t.network.allow != [ ];
        message = "${at}.network: egress = \"allowlist\" needs a non-empty `allow`";
      }
      {
        assertion = t.network.allow == [ ] || t.network.egress == "allowlist";
        message = "${at}.network: `allow` needs egress = \"allowlist\"";
      }
    ]
    # Membership first: a name with `/` must never reach the path below.
    ++ lib.mapAttrsToList (n: _: {
      assertion = builtins.elem n known && builtins.pathExists "${t.skillsSource.outPath}/skills/${n}/SKILL.md";
      message = "${at}.skills.${n}: not in skills source ${t.skillsSource.rev} (known: ${lib.concatStringsSep ", " known})";
    }) t.skills
    ++ lib.concatMap (mountChecks "${at}.filesystem.mounts") t.filesystem.mounts;

  deniedRoots = map (r: r.path) (onRoots deniedHostRoots (map (r: { inherit (r) path; }) cfg.host.allowedMountRoots));

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
      {
        assertion = deniedRoots == [ ];
        message = "sam.agentRuntime.host.allowedMountRoots: ${lib.concatStringsSep ", " deniedRoots} is on a denied host root (${lib.concatStringsSep " " deniedHostRoots})";
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

  # Schema v1 is exactly the declared options: option groups pass through as they are.
  manifestOf =
    name: t:
    let
      body = {
        schemaVersion = 1;
        kind = "agent-runtime-template";
        template.name = name;
        inherit (t) role filesystem;
        sources = lib.mapAttrs (_: r: {
          inherit (r) github ref resolve path writable;
          locked = if r.lock == null then null else sourceRef r.lock;
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
          network = {
            inherit (t.network) egress;
            allow = lib.naturalSort (lib.unique t.network.allow);
          };
          capabilities = lib.naturalSort (lib.unique t.capabilities);
        };
      };
      lockedSources = {
        sources = lib.mapAttrs (_: s: if s.locked == null then null else { inherit (s.locked) rev narHash; }) body.sources;
        skills = { inherit (body.skills.source) rev narHash; };
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
        description = "Host directories templates may bind-mount from (none by default); a bare string is a read-only root; never on ${lib.concatStringsSep ", " deniedHostRoots}.";
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
