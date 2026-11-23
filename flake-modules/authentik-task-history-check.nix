# A consumed blueprint task can outlive its blueprint; exercise the actual package and broker against PostgreSQL.
{ config, lib, ... }:
let
  acer = config.flake.nixosConfigurations.acer-swift.config;
  services = acer.systemd.services;
  package = services.authentik-worker.serviceConfig.WorkingDirectory;
  python = lib.head (lib.splitString " " services.authentik-migrate.serviceConfig.ExecStart);
  sameImports =
    lib.all
      (
        name:
        services.${name}.serviceConfig.WorkingDirectory == package
        && services.${name}.environment.PYTHONPATH == services.authentik-worker.environment.PYTHONPATH
      )
      [
        "authentik"
        "authentik-worker"
        "authentik-migrate"
      ];
in
{
  perSystem =
    { system, pkgs, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      checks.authentik-task-history =
        let
          originalPython = builtins.head pkgs.authentik.worker.buildInputs;
          originalPackage = originalPython.pkgs.authentik-django;
          originalEnv = originalPython.withPackages (_: [ originalPackage ]);
        in
        assert lib.assertMsg sameImports
          "authentik-task-history: server, worker and migration import paths differ";
        pkgs.runCommand "authentik-task-history"
          {
            nativeBuildInputs = [ pkgs.ruff ];
          }
          ''
            export HOME="$TMPDIR/home" PYTHONDONTWRITEBYTECODE=1 AUTHENTIK_LOG_LEVEL=warning
            mkdir -p "$HOME" "$TMPDIR/original" "$TMPDIR/patched"
            ruff check --isolated --no-cache --select E4,E7,E9,F,B ${../scripts/test-authentik-task-history.py}
            ${originalEnv}/bin/python -I ${../scripts/test-authentik-task-history.py} \
              ${originalPackage} "$TMPDIR/original" ${acer.services.postgresql.package}/bin > original.jsonl
            ${python} -I ${../scripts/test-authentik-task-history.py} \
              ${package} "$TMPDIR/patched" ${acer.services.postgresql.package}/bin --expect-fixed > patched.jsonl
            mkdir "$out"
            cp original.jsonl patched.jsonl "$out/"
          '';
    };
}
