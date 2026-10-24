{ pkgs, ... }:
let
  relayConfig = pkgs.writeShellApplication {
    name = "native-otel-relay-config";
    runtimeInputs = [ pkgs.coreutils pkgs.gnugrep ];
    text = ''
      token_file="$CREDENTIALS_DIRECTORY/token"
      config_file="$RUNTIME_DIRECTORY/nginx.conf"
      token="$(cat "$token_file")"

      if ! printf '%s' "$token" | grep -Eq '^[A-Za-z0-9._~+/=-]+$'; then
        printf '%s\n' 'native-otel-relay: invalid bearer token format' >&2
        exit 1
      fi

      mkdir -p "$RUNTIME_DIRECTORY/client_body_temp" "$RUNTIME_DIRECTORY/proxy_temp"
      umask 077
      cat > "$config_file" <<EOF
      daemon off;
      pid $RUNTIME_DIRECTORY/nginx.pid;
      error_log stderr warn;
      events { worker_connections 32; }
      http {
        access_log off;
        client_body_temp_path $RUNTIME_DIRECTORY/client_body_temp;
        proxy_temp_path $RUNTIME_DIRECTORY/proxy_temp;
        server {
          listen 127.0.0.1:4319;
          server_tokens off;
          location = /v1/metrics {
            if (\$request_method != POST) { return 405; }
            client_max_body_size 1m;
            proxy_http_version 1.1;
            proxy_pass_request_headers off;
            proxy_set_header Host otlp.sammasak.dev;
            proxy_set_header Authorization "Bearer $token";
            proxy_set_header Content-Type \$http_content_type;
            proxy_set_header Content-Encoding \$http_content_encoding;
            proxy_set_header Accept \$http_accept;
            proxy_ssl_server_name on;
            proxy_ssl_name otlp.sammasak.dev;
            proxy_ssl_verify on;
            proxy_ssl_verify_depth 3;
            proxy_ssl_trusted_certificate ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt;
            proxy_pass https://otlp.sammasak.dev/v1/metrics;
          }
          location / { return 404; }
        }
      }
      EOF
      chmod 0600 "$config_file"
    '';
  };
in
{
  systemd.services.native-otel-relay = {
    description = "Credential-isolated OTLP metrics relay for Codex";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" "sops-nix.service" ];
    serviceConfig = {
      Type = "exec";
      DynamicUser = true;
      RuntimeDirectory = "native-otel-relay";
      RuntimeDirectoryMode = "0700";
      LoadCredential = [ "token:/run/secrets/native_otlp_auth" ];
      ExecStartPre = "${relayConfig}/bin/native-otel-relay-config";
      ExecStart = "${pkgs.nginx}/bin/nginx -c /run/native-otel-relay/nginx.conf -p /run/native-otel-relay/";
      ExecStopPost = "${pkgs.coreutils}/bin/rm -f /run/native-otel-relay/nginx.conf";
      Restart = "on-failure";
      RestartSec = 5;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
    };
  };
}
