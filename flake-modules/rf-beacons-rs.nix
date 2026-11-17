{ lib, inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      src = inputs.rf-proto;
      # exactly what the parity check reads: a whole-repo source would give it a new drvPath on every change (#502)
      paritySrc = lib.fileset.toSource {
        root = ../.;
        fileset = lib.fileset.unions [
          ../modules/rf-lab/fixtures/beacon.pcap
          ../modules/rf-lab/fixtures/beacon-hidden.pcap
          ../modules/rf-lab/fixtures/beacon-escape.pcap
          ../scripts/rf-beacons-table.sh
        ];
      };
      # the Rust beacon table of sammasak/rf-proto (slice 6, #42): reads a capture file only, opens no
      # interface, captures and sends nothing. The crate is zero-dependency; its own tests run in its repo.
      rfBeaconsRs = pkgs.rustPlatform.buildRustPackage {
        pname = "rf-beacons-rs";
        version = "0-${builtins.substring 0 7 src.rev}";
        inherit src;
        cargoLock.lockFile = "${src}/Cargo.lock";
        cargoBuildFlags = [
          "--example"
          "beacons"
        ];
        doCheck = false;
        installPhase = ''
          runHook preInstall
          install -Dm755 "$(find target -path '*/release/examples/beacons' -type f | head -1)" $out/bin/rf-beacons-rs
          install -Dm644 ${src}/fixtures/oui-sample.csv $out/share/rf-beacons-rs/oui-sample.csv
          runHook postInstall
        '';
        meta.mainProgram = "rf-beacons-rs";
      };
    in
    {
      packages.rf-beacons-rs = rfBeaconsRs;
      # #42 DoD ("replicates behavior … with captured baseline and tests"): the Rust table must equal the
      # one rf:beacons prints (tshark + scripts/rf-beacons-table.sh) on this repo's crafted fixtures
      checks = lib.optionalAttrs (system == "x86_64-linux") {
        rf-beacons-parity =
          pkgs.runCommand "rf-beacons-parity"
            {
              nativeBuildInputs = with pkgs; [
                bash
                wireshark-cli
                gawk
                coreutils
                gnugrep
                diffutils
                rfBeaconsRs
              ];
            }
            ''
              cd ${paritySrc}
              for f in beacon beacon-hidden beacon-escape; do
                p=modules/rf-lab/fixtures/$f.pcap
                rust=$(rf-beacons-rs "$p" ${rfBeaconsRs}/share/rf-beacons-rs/oui-sample.csv --text)
                shark=$(bash scripts/rf-beacons-table.sh "$p")
                diff -u <(printf '%s\n' "$shark") <(printf '%s\n' "$rust") || { echo "rf-beacons parity: $f differs (- tshark, + rust)" >&2; exit 1; }
                echo "parity ok: $f ($(printf '%s\n' "$rust" | grep -c .) rows)"
              done
              touch $out
            '';
      };
    };
}
