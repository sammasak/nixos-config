# The app repository's side of the contract: what the app is and needs, never what it is allowed. Host, hostnames,
# secrets and the memory ceiling it may have are the platform's grant (grant.nix), so no field here can name a host,
# a store path, a host path, a systemd setting or a Caddy directive; an unknown field fails as `does not exist'.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  names = import ./names.nix lib;
  inherit (names) keyed;
  inherit (types) strMatching submodule;
  service = submodule {
    options = {
      program = mkOption {
        type = strMatching names.attr;
        description = "The executable under the built package's bin/ that the unit starts, without arguments.";
      };
      port = mkOption {
        type = types.ints.between 1024 65535;
        description = "The TCP port the service listens on, on loopback; the edge proxies its ingress names to it.";
      };
      metricsPath = mkOption {
        type = types.nullOr (strMatching names.path);
        default = null;
        description = "The HTTP path on its port where the service serves Prometheus metrics; null: none is scraped.";
      };
      resources = mkOption {
        description = "The ceilings the platform's unit sets on the service.";
        type = submodule {
          options = {
            memoryMiB = mkOption {
              type = names.memoryMiB;
              description = "MemoryMax of the service in MiB; above its grant's memoryMiB it is refused.";
            };
            cpuPercent = mkOption {
              type = types.ints.between 5 200;
              description = "CPUQuota of the service, in percent of one core.";
            };
            tasks = mkOption {
              type = types.ints.between 1 512;
              default = 64;
              description = "TasksMax of the service: its processes and threads together.";
            };
          };
        };
      };
      secrets = mkOption {
        default = { };
        description = "The sops secrets the service reads, by name: each must be granted and declared on its host.";
        type = keyed names.secret (
          submodule (
            { name, ... }:
            {
              options.credential = mkOption {
                type = strMatching names.credential;
                default = baseNameOf name;
                defaultText = lib.literalExpression "baseNameOf name";
                description = "The file name the service reads it from in $CREDENTIALS_DIRECTORY.";
              };
            }
          )
        );
      };
      state = mkOption {
        default = { };
        description = "Named persistent volumes, each a directory the platform owns under the app's state; a host path cannot be named.";
        type = keyed names.label (submodule {
          options.backup = mkOption {
            type = types.enum [
              "none"
              "daily"
            ];
            description = "Whether the platform's backup copies it off the host every day.";
          };
        });
      };
    };
  };
in
{
  options = {
    apiVersion = mkOption {
      type = types.enum [ "v1alpha1" ];
      description = "The contract version this manifest is written against.";
    };
    owner = mkOption {
      type = strMatching names.login;
      description = "The GitHub login answerable for the app; it must be the owner its grant names.";
    };
    environment = mkOption {
      type = types.enum [
        "production"
        "staging"
      ];
      description = "The environment the app is deployed to.";
    };
    source = mkOption {
      description = "Where the app is built from: the platform derives the store path from these, it never takes one.";
      type = submodule {
        options = {
          repo = mkOption {
            type = strMatching names.repo;
            description = "The GitHub owner/name of the app's repository; it must be the repository its grant allowlists.";
          };
          rev = mkOption {
            type = strMatching "[0-9a-f]{40}";
            description = "The full commit the release is built from, never a branch, tag or short hash.";
          };
          package = mkOption {
            type = strMatching names.attr;
            default = "default";
            description = "The attribute under the repository flake's packages.<system> to build.";
          };
        };
      };
    };
    health = mkOption {
      description = "How the platform decides a release is serving.";
      type = submodule {
        options.path = mkOption {
          type = strMatching names.path;
          description = "The HTTP path that answers 2xx once the app serves.";
        };
      };
    };
    ingress = mkOption {
      default = { };
      description = "The names the app is served under, each a label under the edge's domain and each one granted.";
      type = keyed names.label (submodule {
        options.auth = mkOption {
          type = types.enum [
            "authentik"
            "public"
          ];
          description = "authentik: the edge's forward auth guards every request; public: none, only if its grant allows it.";
        };
      });
    };
    runtime = mkOption {
      description = "What runs: exactly one of a static site the edge serves or a service the platform's unit runs.";
      type = types.attrTag {
        static = mkOption {
          description = "A directory of files the edge serves from the built package.";
          type = submodule {
            options.spa = mkOption {
              type = types.bool;
              default = false;
              description = "A path that is no file is answered with /index.html (a single-page app).";
            };
          };
        };
        service = mkOption {
          description = "A process the platform's own unit runs from the built package.";
          type = service;
        };
      };
    };
  };
}
