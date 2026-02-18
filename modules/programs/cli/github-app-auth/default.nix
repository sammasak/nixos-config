# GitHub App authentication for workstation VMs.
# Physical hosts are not affected: all behaviour is gated on the presence of
# /etc/workstation/github-app-env, which only exists on KubeVirt workstations.
{ pkgs, lib, ... }:
let
  tokenRefreshScript = pkgs.writeShellApplication {
    name = "github-app-token-refresh";
    runtimeInputs = [ pkgs.openssl pkgs.curl pkgs.jq ];
    text = ''
      env_file="/etc/workstation/github-app-env"

      # No-op on physical hosts where the env file is absent.
      if [ ! -f "$env_file" ]; then
        exit 0
      fi

      set -a
      # shellcheck disable=SC1090
      . "$env_file"
      set +a

      : "''${GITHUB_APP_ID:?GITHUB_APP_ID not set in $env_file}"
      : "''${GITHUB_APP_INSTALLATION_ID:?GITHUB_APP_INSTALLATION_ID not set in $env_file}"
      : "''${GITHUB_APP_PRIVATE_KEY_PATH:?GITHUB_APP_PRIVATE_KEY_PATH not set in $env_file}"

      if [ ! -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]; then
        echo "github-app-token-refresh: private key not found at $GITHUB_APP_PRIVATE_KEY_PATH" >&2
        exit 1
      fi

      # base64url encode (no padding, RFC 4648 §5 alphabet)
      b64url() {
        openssl base64 -A | tr '+/' '-_' | tr -d '='
      }

      # Build JWT header and payload
      header='{"alg":"RS256","typ":"JWT"}'
      now=$(date +%s)
      iat=$(( now - 60 ))
      exp=$(( iat + 540 ))
      payload="{\"iss\":\"''${GITHUB_APP_ID}\",\"iat\":''${iat},\"exp\":''${exp}}"

      header_b64=$(printf '%s' "$header"   | b64url)
      payload_b64=$(printf '%s' "$payload" | b64url)
      signing_input="''${header_b64}.''${payload_b64}"

      signature=$(printf '%s' "$signing_input" \
        | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_PATH" \
        | b64url)

      jwt="''${signing_input}.''${signature}"

      # Exchange JWT for an installation access token (valid ~1 h)
      response=$(curl -s -X POST \
        -H "Authorization: Bearer ''${jwt}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/installations/''${GITHUB_APP_INSTALLATION_ID}/access_tokens")

      token=$(printf '%s' "$response" | jq -r '.token // empty')

      if [ -z "$token" ]; then
        echo "github-app-token-refresh: failed to obtain token. Response: $response" >&2
        exit 1
      fi

      # Write to tmpfs with restricted permissions
      token_file="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/github-token"
      printf '%s' "$token" > "$token_file"
      chmod 0600 "$token_file"
    '';
  };
in
{
  home.packages = [ tokenRefreshScript ];

  # Systemd user service that runs the refresh script
  systemd.user.services.github-app-token-refresh = {
    Unit = {
      Description = "Refresh GitHub App installation access token";
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${tokenRefreshScript}/bin/github-app-token-refresh";
    };
  };

  # Timer: first run 10 s after boot, then every 50 min (token expires in 1 h)
  systemd.user.timers.github-app-token-refresh = {
    Unit = {
      Description = "Periodically refresh GitHub App installation access token";
    };
    Timer = {
      OnBootSec = "10s";
      OnUnitActiveSec = "50min";
      Unit = "github-app-token-refresh.service";
    };
    Install = {
      WantedBy = [ "timers.target" ];
    };
  };

  # Bash: export GH_TOKEN and set bot git identity when env file is present
  programs.bash.enable = true;
  programs.bash.initExtra = lib.mkAfter ''
    if [ -f /etc/workstation/github-app-env ]; then
      _tf="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/github-token"
      if [ -f "$_tf" ]; then
        GH_TOKEN="$(cat "$_tf")"
        export GH_TOKEN
      fi
      while IFS='=' read -r _k _v; do
        case "$_k" in
          GITHUB_APP_BOT_NAME)  git config --global user.name  "$_v" ;;
          GITHUB_APP_BOT_EMAIL) git config --global user.email "$_v" ;;
        esac
      done < /etc/workstation/github-app-env
      unset _tf _k _v
    fi
  '';

  # Git: use GH_TOKEN for HTTPS authentication to github.com
  programs.git.extraConfig = {
    credential."https://github.com".helper =
      "!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f";
  };
}
