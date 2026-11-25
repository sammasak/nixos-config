# The owner's ChatGPT login for the slots' Codex (nixos-config#808): one CODEX_HOME on this host, which only its refresh
# timer writes (a reused refresh token is lost for good, docs/records/execution-pool-credentials.md). The egress proxy
# reads the access token and account id derived from it; no guest sees either.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.sam.workers.codexLogin;
  dev = config.services.devEnvironments;
  inherit (cfg) home;
  auth = "${home}/auth.json";
  derived = dirOf cfg.tokens;
  ready = "${derived}/ready";
  textfile = "/run/node-exporter-textfile/codex-egress.prom";
  failedMarker = "/var/lib/codex-egress-refresh/failed";
  codex = lib.getExe pkgs.codex;
  # cd /: codex-egress may not enter the owner's home
  login = "cd / && sudo -u codex-egress env HOME=${home} CODEX_HOME=${home} /run/current-system/sw/bin/codex login --device-auth -c 'cli_auth_credentials_store=\"file\"'";

  # A partial auth.json (a write in flight) keeps the last tokens; only a missing login or one without tokens drops them.
  derive = pkgs.writeShellApplication {
    name = "codex-egress-token";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.systemd.package
    ];
    text = ''
      was=0; [[ -e ${ready} ]] && was=1
      install -d -m 0700 -o ${dev.user} -g root ${cfg.tokens}
      if [[ -e ${auth} ]] && ! jq -e . ${auth} >/dev/null 2>&1; then
        echo "codex-egress: ${auth} does not parse (a write in flight?); the last tokens stay" >&2
        exit 0
      fi
      umask 077
      if [[ -e ${auth} ]] && jq -e '(.tokens.access_token | type == "string") and (.tokens.account_id | type == "string")' ${auth} >/dev/null; then
        for f in access_token:access-token account_id:account-id; do
          jq -j ".tokens.''${f%%:*}" ${auth} > ${cfg.tokens}/.new
          chown ${dev.user} ${cfg.tokens}/.new
          chmod 0400 ${cfg.tokens}/.new
          mv -f ${cfg.tokens}/.new ${cfg.tokens}/''${f#*:}
        done
        install -m 0644 /dev/null ${ready}
        now=1
      else
        rm -f ${ready} ${cfg.tokens}/access-token ${cfg.tokens}/account-id
        echo ${lib.escapeShellArg "codex-egress: no ChatGPT login in ${home}; codex is not offered. Sign in with: ${login}"} >&2
        now=0
      fi
      # the runners advertise codex as of their start (exec-pool-runner.nix): only a change of the login restarts them,
      # and a restarted runner adopts its running attempt
      if (( was != now )); then
        systemctl try-restart 'exec-pool-runner-*.service' || true
      fi
    '';
  };

  # Upstream Codex refreshes through its own auth manager: app-server's account/read with refreshToken forces a refresh
  # (codex-rs app-server account_processor.rs, refresh_token_if_requested), and calls no model. It reports no outcome,
  # so success is auth.json's last_refresh moving. A failed or timed-out refresh may have spent the refresh token, so
  # it is not tried again until the login changes.
  refresh = pkgs.writers.writePython3Bin "codex-egress-refresh" { doCheck = false; } ''
    import base64
    import hashlib
    import json
    import os
    import pathlib
    import select
    import subprocess
    import sys
    import time

    AUTH = pathlib.Path(os.environ["CODEX_EGRESS_AUTH"])
    FAILED = pathlib.Path(os.environ["CODEX_EGRESS_FAILED"])
    TEXTFILE = pathlib.Path(os.environ["CODEX_EGRESS_TEXTFILE"])
    CODEX = os.environ["CODEX_EGRESS_CODEX"].split()
    TIMEOUT = int(os.environ.get("CODEX_EGRESS_TIMEOUT", "120"))


    def load():
        try:
            data = AUTH.read_bytes()
            return data, json.loads(data)
        except (OSError, ValueError):
            return None, None


    def claims(token):
        try:
            part = token.split(".")[1]
            part += "=" * (-len(part) % 4)
            return json.loads(base64.urlsafe_b64decode(part))
        except (IndexError, ValueError, AttributeError):
            return {}


    def last_refresh(a):
        return (a or {}).get("last_refresh")


    def stamp(text):
        try:
            from datetime import datetime
            return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
        except (AttributeError, ValueError):
            return 0


    def metrics(present, failed, a):
        c = claims(((a or {}).get("tokens") or {}).get("access_token"))
        lines = [
            "# HELP codex_egress_login_present The slots' ChatGPT login exists in the egress CODEX_HOME.",
            "# TYPE codex_egress_login_present gauge",
            f"codex_egress_login_present {int(present)}",
            "# HELP codex_egress_refresh_failed A refresh failed or timed out; none is tried until the login changes.",
            "# TYPE codex_egress_refresh_failed gauge",
            f"codex_egress_refresh_failed {int(failed)}",
            "# HELP codex_egress_access_token_expiry_timestamp_seconds When the access token the proxy sends expires.",
            "# TYPE codex_egress_access_token_expiry_timestamp_seconds gauge",
            f"codex_egress_access_token_expiry_timestamp_seconds {int(c.get('exp', 0))}",
            "# HELP codex_egress_last_refresh_timestamp_seconds The login's last refresh, as auth.json records it.",
            "# TYPE codex_egress_last_refresh_timestamp_seconds gauge",
            f"codex_egress_last_refresh_timestamp_seconds {int(stamp(last_refresh(a)))}",
        ]
        tmp = TEXTFILE.with_name("." + TEXTFILE.name)
        tmp.write_text("\n".join(lines) + "\n")
        tmp.chmod(0o644)
        tmp.replace(TEXTFILE)


    def due(a):
        c = claims(a["tokens"].get("access_token"))
        exp, iat = c.get("exp"), c.get("iat")
        if not isinstance(exp, (int, float)) or not isinstance(iat, (int, float)):
            return True
        return exp - time.time() < (exp - iat) / 2


    def converse():
        """initialize, initialized, account/read {refreshToken: true}; True once account/read answered."""
        proc = subprocess.Popen(CODEX + ["app-server"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + TIMEOUT

        def send(msg):
            proc.stdin.write((json.dumps(msg) + "\n").encode())
            proc.stdin.flush()

        def answer(rid):
            buf = b""
            while time.monotonic() < deadline:
                ready, _, _ = select.select([proc.stdout], [], [], max(0.0, deadline - time.monotonic()))
                if not ready:
                    break
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    return False
                buf += chunk
                *lines, buf = buf.split(b"\n")
                for line in lines:
                    try:
                        if json.loads(line).get("id") == rid:
                            return True
                    except ValueError:
                        pass
            return False

        try:
            info = {"name": "codex-egress-refresh", "version": "1"}
            send({"id": 1, "method": "initialize", "params": {"clientInfo": info}})
            if not answer(1):
                return False
            send({"method": "initialized"})
            send({"id": 2, "method": "account/read", "params": {"refreshToken": True}})
            return answer(2)
        except OSError:
            return False
        finally:
            try:
                proc.stdin.close()
            except OSError:
                pass
            try:
                proc.wait(10)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


    def main():
        raw, a = load()
        if a is None or not (a.get("tokens") or {}).get("refresh_token"):
            FAILED.unlink(missing_ok=True)
            metrics(False, False, None)
            print("no ChatGPT login to refresh", file=sys.stderr)
            return 0
        digest = hashlib.sha256(raw).hexdigest()
        if FAILED.exists():
            if FAILED.read_text().strip() == digest:
                metrics(True, True, a)
                print("an earlier refresh of this login failed: not retried until a new login", file=sys.stderr)
                return 0
            FAILED.unlink()
        if not due(a):
            metrics(True, False, a)
            return 0
        before = last_refresh(a)
        answered = converse()
        _, after = load()
        if after is not None and last_refresh(after) != before:
            metrics(True, False, after)
            print("refreshed", file=sys.stderr)
            return 0
        FAILED.write_text(digest + "\n")
        metrics(True, True, after or a)
        why = "it did not record a new refresh" if answered else "app-server did not answer in time"
        print(f"refresh failed: {why}; not retried until a new login", file=sys.stderr)
        return 0


    sys.exit(main())
  '';
in
{
  options.sam.workers.codexLogin = {
    enable = lib.mkEnableOption "the slots' Codex on the owner's ChatGPT login in home, which the egress proxy signs their calls with, instead of an API key (sam.workers.codexAuthFile)";
    home = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/codex-egress";
      readOnly = true;
      description = "The login's CODEX_HOME, codex-egress's alone.";
    };
    tokens = lib.mkOption {
      type = lib.types.str;
      default = "/run/codex-egress/tokens";
      readOnly = true;
      description = "access-token and account-id, derived from the login, readable by the egress proxy alone.";
    };
    loginCommand = lib.mkOption {
      type = lib.types.str;
      default = login;
      readOnly = true;
      description = "The owner's sign-in, on this host.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.codex-egress = {
      isSystemUser = true;
      group = "codex-egress";
      inherit home;
    };
    users.groups.codex-egress = { };
    systemd.tmpfiles.rules = [
      "d ${home} 0700 codex-egress codex-egress -"
      "d /var/lib/codex-egress-refresh 0700 root root -"
    ];
    environment.systemPackages = [ pkgs.codex ];

    systemd.services.codex-egress-token = {
      description = "Derive the egress proxy's ChatGPT access token and account id from the Codex login";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe derive;
        RuntimeDirectory = baseNameOf derived;
        RuntimeDirectoryMode = "0755";
        RuntimeDirectoryPreserve = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        NoNewPrivileges = true;
      };
    };
    systemd.paths.codex-egress-token = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = auth;
    };

    systemd.services.codex-egress-refresh = {
      description = "Let upstream Codex refresh the slots' ChatGPT login when half its access token's life is gone";
      after = [
        "network-online.target"
        "systemd-tmpfiles-setup.service"
      ];
      wants = [ "network-online.target" ];
      environment = {
        CODEX_EGRESS_AUTH = auth;
        CODEX_EGRESS_FAILED = failedMarker;
        CODEX_EGRESS_TEXTFILE = textfile;
        # the login's own user, its home and file store; root keeps the marker and the textfile
        CODEX_EGRESS_CODEX = "${pkgs.util-linux}/bin/setpriv --reuid=codex-egress --regid=codex-egress --clear-groups ${pkgs.coreutils}/bin/env -i HOME=${home} CODEX_HOME=${home} SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt ${codex} -c cli_auth_credentials_store=\"file\"";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${refresh}/bin/codex-egress-refresh";
        # the helper's own bound is 120 s; this one catches a hang outside it, and counts as no retry too
        TimeoutStartSec = 300;
        ProtectSystem = "strict";
        ReadWritePaths = [
          home
          "/var/lib/codex-egress-refresh"
          "/run/node-exporter-textfile"
        ];
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
    systemd.timers.codex-egress-refresh = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
      };
    };

    homelab.execPool.agentMarkers.codex = ready;

    assertions = [
      {
        assertion = config.sam.workers.codexAuthFile == null;
        message = "sam.workers.codexLogin signs the slots' Codex with the ChatGPT login; sam.workers.codexAuthFile (an API key) is the other way, not both.";
      }
    ];
  };
}
