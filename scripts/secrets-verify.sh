#!/usr/bin/env bash
# Sanity-checks the decrypted wifi credentials without ever printing a value.
# Exists because a placeholder tail concatenated onto the real PSK
# ("-run-sops-edit") survives a partial `sops edit` unnoticed and WRONG_KEYs
# wifi on every boot.
set -euo pipefail
cd "$(dirname "$0")/.."

# Machines without the personal age key (workers, throwaway clones) cannot run
# this gate; a visible skip beats a `check` that fails for reasons unrelated to
# configuration correctness. Machines with the key get no such out.
age_key="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
if [[ ! -r $age_key && -z ${SOPS_AGE_KEY:-} ]]; then
  echo "secrets-verify: SKIP - no readable age key at $age_key, gate not enforced here" >&2
  exit 0
fi

blob="$(sops --decrypt --extract '["env"]' secrets/homelab/wifi.yaml)"

fail=0

# Single process, no `| head`: under pipefail a duplicate key would SIGPIPE
# sed into a silent non-zero exit.
value_of() { printf '%s\n' "$blob" | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }

has_placeholder() {
  local v="${1,,}"
  [[ $v == *changeme* || $v == *replace_me* || $v == *run-sops-edit* ]]
}

for key in HOME_WIFI_SSID HOME_WIFI_PSK; do
  if ! printf '%s\n' "$blob" | grep -q "^$key="; then
    echo "FAIL: $key is missing from the wifi env blob" >&2
    fail=1
  fi
done

psk="$(value_of HOME_WIFI_PSK)"
ssid="$(value_of HOME_WIFI_SSID)"

if ((${#psk} < 8 || ${#psk} > 63)); then
  echo "FAIL: HOME_WIFI_PSK length ${#psk} is outside the WPA-PSK range 8..63" >&2
  fail=1
fi
if ((${#ssid} < 1 || ${#ssid} > 32)); then
  echo "FAIL: HOME_WIFI_SSID length ${#ssid} is outside 1..32" >&2
  fail=1
fi
if has_placeholder "$psk"; then
  echo "FAIL: HOME_WIFI_PSK contains placeholder residue" >&2
  fail=1
fi
if has_placeholder "$ssid"; then
  echo "FAIL: HOME_WIFI_SSID contains placeholder residue" >&2
  fail=1
fi
if [[ $psk =~ ^[[:space:]] || $psk =~ [[:space:]]$ ]]; then
  echo "FAIL: HOME_WIFI_PSK has leading or trailing whitespace" >&2
  fail=1
fi
if [[ $ssid =~ ^[[:space:]] || $ssid =~ [[:space:]]$ ]]; then
  echo "FAIL: HOME_WIFI_SSID has leading or trailing whitespace" >&2
  fail=1
fi

((fail == 0)) && echo "secrets-verify: OK"
exit "$fail"
