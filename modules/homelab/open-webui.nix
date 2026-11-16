# chat.sammasak.dev as a host service: Traefik (forward auth through Authentik, as before) reaches it at the node
# address through a selectorless Service (homelab-gitops). open-webui signs in whoever sends X-authentik-email, so
# only pods may reach it: the socket admits pod addresses alone (not the nodes' Cilium ones), a cluster policy
# admits only Traefik's pods, and the app serves on a Unix socket in a 0700 directory, out of reach of every local
# user. The proxy exits when idle and the app stops with it, as the pod scaled to zero. Caddy (edge.nix) connects through
# a second socket only its user may open.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.open-webui;
  address = config.sam.fleet.hosts.${config.sam.profile.hostname}.address;
  port = 8090;
  # The pod CIDR without each node's Cilium host address (CiliumInternalIP: kubectl get ciliumnodes), which any
  # process on that node may bind as its source; a node that gets a new one opens a hole until it is listed here.
  ciliumHosts = [
    "10.42.0.136" # acer-swift
    "10.42.1.227" # lenovo
    "10.42.2.65" # msi-ms7758
    "10.42.3.52" # black-pi
  ];
  pow2 = k: lib.foldl (a: _: a * 2) 1 (lib.range 1 k);
  toInt = s: lib.foldl (a: o: a * 256 + lib.toInt o) 0 (lib.splitString "." s);
  toDotted =
    n: lib.concatMapStringsSep "." (i: toString (lib.mod (n / pow2 (24 - 8 * i)) 256)) (lib.range 0 3);
  # blocks minus one address: the block holding it splits into halves until the address is a /32 of its own
  without =
    hole:
    lib.concatMap (
      b:
      if hole < b.base || hole >= b.base + pow2 (32 - b.len) then
        [ b ]
      else if b.len == 32 then
        [ ]
      else
        without hole [
          {
            inherit (b) base;
            len = b.len + 1;
          }
          {
            base = b.base + pow2 (31 - b.len);
            len = b.len + 1;
          }
        ]
    );
  podSources = map (b: "${toDotted b.base}/${toString b.len}") (
    lib.foldr (h: without (toInt h)) [
      {
        base = toInt "10.42.0.0";
        len = 16;
      }
    ] ciliumHosts
  );
  socket = "/run/open-webui/http.sock";
  edgeSocket = "/run/open-webui-edge.sock";
  # uvicorn on the Unix socket, as `open-webui serve` runs it on a TCP port (backend/open_webui/__init__.py)
  python = pkgs.python3.withPackages (ps: [ (ps.toPythonModule cfg.package) ]);
  backup = pkgs.writers.writePython3Bin "open-webui-backup" { doCheck = false; } (
    builtins.readFile ./open-webui-backup.py
  );
  sopsFile = ../../secrets/homelab/open-webui.yaml;
  gateway = "http://127.0.0.1:8081"; # the llm-gateway's API listener on this host (llm-gateway.nix)
in
{
  sops.secrets = {
    open_webui_gateway_key.sopsFile = sopsFile;
    open_webui_secret_key.sopsFile = sopsFile;
  };
  sops.templates."open-webui.env" = {
    content = ''
      OPENAI_API_KEY=${config.sops.placeholder.open_webui_gateway_key}
      OLLAMA_API_CONFIGS={"0":{"enable":true,"key":"${config.sops.placeholder.open_webui_gateway_key}"}}
      WEBUI_SECRET_KEY=${config.sops.placeholder.open_webui_secret_key}
    '';
  };

  services.open-webui = {
    enable = true;
    environmentFile = config.sops.templates."open-webui.env".path;
    # The pod's settings (homelab-gitops apps/chat/deployment.yaml); the keys come from the file above.
    environment = {
      # the image's; at 0.12.2 the default `dev` serves /docs and /openapi.json
      ENV = "prod";
      SCARF_NO_ANALYTICS = "True";
      DO_NOT_TRACK = "True";
      ANONYMIZED_TELEMETRY = "False";
      OLLAMA_BASE_URL = gateway;
      ENABLE_OPENAI_API = "True";
      OPENAI_API_BASE_URL = "${gateway}/v1";
      # Git stays authoritative for provider wiring and auth settings.
      ENABLE_PERSISTENT_CONFIG = "False";
      WEBUI_URL = "https://chat.sammasak.dev";
      WEBUI_AUTH = "True";
      BYPASS_MODEL_ACCESS_CONTROL = "True";
      WEBUI_AUTH_TRUSTED_EMAIL_HEADER = "X-authentik-email";
      WEBUI_AUTH_TRUSTED_NAME_HEADER = "X-authentik-name";
      WEBUI_AUTH_TRUSTED_GROUPS_HEADER = "X-authentik-groups";
      ENABLE_LOGIN_FORM = "False";
      # The trusted-header sign-in still goes through the password endpoint.
      ENABLE_PASSWORD_AUTH = "True";
      DEFAULT_USER_ROLE = "user";
      ENABLE_SIGNUP = "False";
      # Speech stays in the browser: text-to-speech defaults to its Web API already, but the default speech-to-text
      # engine runs Whisper inside the app and fetches its model at first use.
      AUDIO_STT_ENGINE = "web";
      # what `open-webui serve` sets before importing the app
      FROM_INIT_PY = "true";
      FRONTEND_BUILD_DIR = "${cfg.package.frontend}/share/open-webui";
      # the image's cache paths, inside the migrated data dir, so the embedding model is not fetched again
      HF_HOME = "${cfg.stateDir}/data/cache/embedding/models";
      SENTENCE_TRANSFORMERS_HOME = "${cfg.stateDir}/data/cache/embedding/models";
      TIKTOKEN_CACHE_DIR = "${cfg.stateDir}/data/cache/tiktoken";
    };
  };

  systemd.services.open-webui = {
    # started by the proxy, never at boot
    wantedBy = lib.mkForce [ ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      ExecStart = lib.mkForce "${python}/bin/python -m uvicorn open_webui.main:app --uds ${socket} --forwarded-allow-ips '*'";
      # Ready when it answers: the proxy starts after this, so the first request waits instead of failing.
      ExecStartPost = "${lib.getExe pkgs.curl} --silent --fail --output /dev/null --unix-socket ${socket} --retry 300 --retry-delay 1 --retry-all-errors http://localhost/health";
      TimeoutStartSec = "6min";
      # uvicorn makes the socket 0666; the directory keeps it to root and the app's dynamic user, which the proxy shares.
      RuntimeDirectoryMode = lib.mkForce "0700";
      # Not the pod's 1Gi: 0.12.2 peaked at 1.45G in its first start on acer. k3s does not count this unit, so an
      # OOM takes it before any pod.
      MemoryMax = "2G";
      MemorySwapMax = 0;
      CPUQuota = "100%";
      OOMScoreAdjust = 1000;
    };
  };

  systemd.sockets.open-webui-proxy = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [
      "${address}:${toString port}"
      edgeSocket
    ];
    socketConfig = {
      # the Unix stream only
      SocketUser = config.services.caddy.user;
      SocketMode = "0600";
      FreeBind = true; # the Wi-Fi address can appear after the socket
      IPAddressDeny = "any";
      IPAddressAllow = podSources;
    };
  };
  # switch-to-configuration never restarts a changed .socket (nixpkgs#74899), and the proxy behind it is idle (so
  # skipped) most of the time: this unit restarts with the socket's text, so a new ListenStream binds at the switch
  systemd.services.open-webui-proxy-rebind = {
    wantedBy = [ "multi-user.target" ];
    after = [ "open-webui-proxy.socket" ];
    restartTriggers = [ config.systemd.units."open-webui-proxy.socket".unit ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # systemd refuses to start a socket whose service still runs (the proxy, for 5 min after a request)
      ExecStart = [
        "${config.systemd.package}/bin/systemctl stop open-webui-proxy.service"
        "${config.systemd.package}/bin/systemctl restart open-webui-proxy.socket"
      ];
    };
  };
  # Caddy's upstream, from the listener table: a connection would start the app (a ~50 s cold start), and black-pi's
  # probe sees only forward auth's 302. EdgeSocketDown (rules/homelab.yaml) reads the metric.
  systemd.services.open-webui-edge-check = {
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      ProtectSystem = "strict";
      ReadWritePaths = [ "/run/node-exporter-textfile" ];
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
    };
    script = ''
      up=0
      [ -n "$(ss -xlH src ${edgeSocket})" ] && up=1
      out=/run/node-exporter-textfile/open-webui-edge.prom
      printf 'homelab_edge_socket_listening{socket="%s"} %d\n' ${edgeSocket} "$up" > "$out.tmp"
      mv "$out.tmp" "$out"
    '';
  };
  systemd.timers.open-webui-edge-check = {
    wantedBy = [ "timers.target" ];
    timerConfig.OnCalendar = "minutely";
  };
  systemd.services.open-webui-proxy = {
    requires = [ "open-webui.service" ];
    after = [ "open-webui.service" ];
    serviceConfig = {
      ExecStart = "${config.systemd.package}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5min ${socket}";
      # the app's own dynamic user, so it may enter the 0700 directory; it opens no network socket of its own
      DynamicUser = true;
      User = "open-webui";
      CapabilityBoundingSet = "";
      PrivateNetwork = true;
      RestrictAddressFamilies = "AF_UNIX";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
    };
  };

  # The host twin of the pod's daily on-node backup: on the same disk, so it guards against a bad write or upgrade,
  # not a dead disk.
  systemd.services.open-webui-backup = {
    description = "Back up open-webui's database and uploads, with a restore check";
    unitConfig.ConditionPathExists = "/var/lib/private/open-webui/data/webui.db";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${lib.getExe backup} backup /var/lib/private/open-webui/data /var/lib/open-webui-backup";
      StateDirectory = "open-webui-backup";
      StateDirectoryMode = "0700";
      PrivateNetwork = true;
      ProtectSystem = "strict";
      # writable on purpose: SQLite cannot open a WAL database read-only once the app has shut down cleanly
      ReadWritePaths = [ "/var/lib/private/open-webui/data" ];
      ProtectHome = true;
      PrivateTmp = true;
    };
  };
  systemd.timers.open-webui-backup = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:30:00";
      Persistent = true;
    };
  };
  environment.systemPackages = [ backup ];

  assertions = [
    {
      assertion = config.services.prometheus.exporters.node.enable;
      message = "modules/homelab/open-webui.nix: the edge check writes a textfile metric; import monitoring/node-exporter.nix.";
    }
    {
      assertion = config.sam.hostSecrets.enable;
      message = "modules/homelab/open-webui.nix: its keys are sops secrets; set sam.hostSecrets.enable.";
    }
    {
      assertion = config.services.caddy.enable;
      message = "modules/homelab/open-webui.nix: ${edgeSocket} belongs to Caddy's user; enable services.caddy (edge.nix).";
    }
    {
      assertion =
        !cfg.openFirewall
        && (import ../../lib/firewall.nix lib).anySourceTcp config.networking.firewall [ port ] == [ ];
      message = "modules/homelab/open-webui.nix: open-webui trusts X-authentik-email; keep port ${toString port} unopened, only the socket's pod CIDR may reach it.";
    }
  ];
}
