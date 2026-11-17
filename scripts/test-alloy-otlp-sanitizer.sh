#!/usr/bin/env bash
# alloy-otlp's sanitizer (modules/homelab/monitoring/alloy-otlp.alloy), ported from homelab-gitops
# scripts/test-native-otlp-sanitizer.sh: sentinels sent through acer's deployed config, run with acer's Alloy and the
# unit's own arguments (scripts/alloy_otlp_argv.py), must not reach its exporters.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
argv_of() { python3 "$repo_root/scripts/alloy_otlp_argv.py" "$@"; }
deployed_config=$(argv_of config)

for executable in python3 jq curl grep mktemp rm rmdir cat sed awk seq sleep head tail tr cmp cp; do
  command -v "$executable" >/dev/null || {
    printf 'required executable not found: %s\n' "$executable" >&2
    exit 2
  }
done

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/native-otlp-sanitizer.XXXXXX")
config_file="$work_dir/test.alloy"
rewritten_file="$work_dir/rewritten.alloy"
alloy_log="$work_dir/alloy.log"
storage_dir="$work_dir/storage"
sum_storage_dir="$work_dir/sum-storage"
oversized_payload_file="$work_dir/oversized.json"
near_limit_payload_file="$work_dir/near-limit.json"
oversized_response_file="$work_dir/oversized-response"
alloy_pid=

cleanup() {
  if [[ -n "$alloy_pid" ]]; then
    kill -INT "$alloy_pid" 2>/dev/null || true
    wait "$alloy_pid" 2>/dev/null || true
  fi
  # rm, not unlink: unlink takes one operand and removed none of these
  rm -f "$config_file" "$rewritten_file" "$alloy_log" "$oversized_payload_file" "$near_limit_payload_file" \
    "$oversized_response_file"
  # what alloy run leaves in its storage path, so the directories can go
  for dir in "$storage_dir" "$sum_storage_dir"; do
    rm -f "$dir/alloy_seed.json"
    rm -rf "$dir/remotecfg"
  done
  rmdir "$storage_dir" "$sum_storage_dir" "$work_dir" 2>/dev/null || true
}
trap cleanup EXIT

otlp_port=$((20000 + $$ % 20000))
server_port=$((otlp_port + 1))
test_token="native-otlp-smoke-${$}"
export OTLP_BEARER_TOKEN=$test_token

# Metrics skip the session-sum chain, so the sanitizer's own output reaches the debug exporter. Each rewrite must
# change the file, so a config that moved on fails here instead of testing something else.
cp "$deployed_config" "$rewritten_file"
chmod u+w "$rewritten_file"
for rewrite in \
  "s/127.0.0.1:4318/127.0.0.1:$otlp_port/" \
  's/metrics = \[otelcol.processor.cumulativetodelta.native.input\]/metrics = [otelcol.processor.transform.native_sanitize.input]/' \
  's/metrics = \[otelcol.processor.batch.native_serialize.input\]/metrics = [otelcol.exporter.debug.test.input]/' \
  's/otelcol.exporter.otlphttp.native.input/otelcol.exporter.debug.test.input/g' \
  's/otelcol.exporter.loki.native.input/otelcol.exporter.debug.test.input/g'; do
  cp "$rewritten_file" "$config_file"
  sed -i -e "$rewrite" "$rewritten_file"
  if cmp -s "$rewritten_file" "$config_file"; then
    printf 'rewrite matched nothing in %s: %s\n' "$deployed_config" "$rewrite" >&2
    exit 1
  fi
done
grep -q '^otelcol.exporter.loki "native" {' "$rewritten_file" || {
  printf 'no otelcol.exporter.loki "native" block to cut at in %s\n' "$deployed_config" >&2
  exit 1
}
awk '/^otelcol.exporter.loki "native" \{/ { skip = 1 } !skip { print }' "$rewritten_file" > "$config_file"
cat >> "$config_file" <<'EOF'
otelcol.exporter.debug "test" {
  verbosity = "detailed"
}
EOF

# the unit's own argv, its listener, storage and config pointed here
mapfile -d '' alloy_argv < <(argv_of "127.0.0.1:$server_port" "$storage_dir" "$config_file")
[[ ${#alloy_argv[@]} -gt 3 ]] || { printf 'no alloy-otlp argv\n' >&2; exit 1; }
"${alloy_argv[0]}" validate --stability.level=experimental "$config_file" >/dev/null
"${alloy_argv[@]}" > "$alloy_log" 2>&1 &
alloy_pid=$!

endpoint="http://127.0.0.1:$otlp_port"
unauthenticated_payload='{"resourceMetrics":[]}'
unauthenticated_status=
# Alloy can take longer than 5 s to listen on a busy gate host (msi, 17 Nov: 000 after 8 s); wait up to 30 s
deadline=$((SECONDS + 30))
while ((SECONDS < deadline)); do
  unauthenticated_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 2 -H 'Content-Type: application/json' -d "$unauthenticated_payload" \
    "$endpoint/v1/metrics" || true)
  [[ "$unauthenticated_status" == 401 ]] && break
  kill -0 "$alloy_pid" 2>/dev/null || {
    printf 'Alloy exited during startup; see %s\n' "$alloy_log" >&2
    exit 1
  }
  sleep 0.1
done
[[ "$unauthenticated_status" == 401 ]] || {
  printf 'expected unauthenticated OTLP response 401, got %s after 30 s; the end of the Alloy log:\n' "$unauthenticated_status" >&2
  tail -n 20 "$alloy_log" >&2
  exit 1
}

metric_payload=$(cat <<'EOF'
{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"codex"}},{"key":"host.name","value":{"stringValue":"lenovo-21cb001pmx"}},{"key":"session.id","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_RESOURCE"}}]},"scopeMetrics":[{"scope":{"name":"smoke"},"metrics":[{"name":"codex.api_request","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"attributes":[{"key":"model","value":{"stringValue":"gpt-NATIVE_OTLP_SMOKE_SENTINEL_MODEL"}},{"key":"success","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_SUCCESS"}},{"key":"tool","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_TOOL"}},{"key":"request.id","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_ID"}}],"asInt":"1","startTimeUnixNano":"1761270000000000000","timeUnixNano":"1761270001000000000"}]}},{"name":"codex.tool.call","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"attributes":[{"key":"model","value":{"stringValue":"gpt-5.4"}},{"key":"success","value":{"stringValue":"true"}},{"key":"tool","value":{"stringValue":"exec_command"}}],"asInt":"1","startTimeUnixNano":"1761270000000000000","timeUnixNano":"1761270001000000000"}]}},{"name":"codex.private.secret_metric","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asInt":"1","startTimeUnixNano":"1761270000000000000","timeUnixNano":"1761270001000000000"}]}}]}]}]}
EOF
)
histogram_payload=$(cat <<'EOF'
{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"codex"}},{"key":"host.name","value":{"stringValue":"asus-b460m"}}]},"scopeMetrics":[{"scope":{"name":"smoke"},"metrics":[{"name":"codex.turn.token_usage","histogram":{"aggregationTemporality":2,"dataPoints":[{"attributes":[{"key":"model","value":{"stringValue":"gpt-mini"}},{"key":"token_type","value":{"stringValue":"input"}}],"startTimeUnixNano":"1761270000000000000","timeUnixNano":"1761270001000000000","count":"2","sum":37,"bucketCounts":["1","1"],"explicitBounds":[10]}]}}]}]}]}
EOF
)
log_payload=$(cat <<'EOF'
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}},{"key":"host.name","value":{"stringValue":"asus-b460m"}},{"key":"worker.name","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_WORKER"}},{"key":"user.id","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_RESOURCE_LOG"}}]},"scopeLogs":[{"scope":{"name":"smoke"},"logRecords":[{"timeUnixNano":"1761270001000000000","severityText":"INFO","body":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_BODY"},"attributes":[{"key":"event.name","value":{"stringValue":"tool_result"}},{"key":"tool_name","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_TOOL_NAME"}},{"key":"success","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_SUCCESS_LOG"}},{"key":"duration_ms","value":{"stringValue":"17"}},{"key":"tool_result_size_bytes","value":{"stringValue":"4242"}},{"key":"output","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_OUTPUT"}},{"key":"user.email","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_EMAIL"}},{"key":"tool_parameters","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_PARAMETERS"}},{"key":"tool_input","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_INPUT"}}]}]}]}]}
EOF
)
log_payload=$(jq -c '.resourceLogs[0].schemaUrl = "https://NATIVE_OTLP_SMOKE_SENTINEL_RESOURCE_SCHEMA.invalid"
  | .resourceLogs[0].scopeLogs[0] |= (.schemaUrl = "https://NATIVE_OTLP_SMOKE_SENTINEL_SCOPE_SCHEMA.invalid"
    | .scope = {name:"NATIVE_OTLP_SMOKE_SENTINEL_SCOPE_NAME",version:"NATIVE_OTLP_SMOKE_SENTINEL_SCOPE_VERSION",
      attributes:[{key:"private",value:{stringValue:"NATIVE_OTLP_SMOKE_SENTINEL_SCOPE_ATTRIBUTE"}}]}
    | .logRecords[0] |= (.severityText = "NATIVE_OTLP_SMOKE_SENTINEL_SEVERITY"
      | .traceId = "abcdef0123456789abcdef0123456789" | .spanId = "abcdef0123456789"))' <<< "$log_payload")
codex_log_payload=$(cat <<'EOF'
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"codex"}}]},"scopeLogs":[{"scope":{"name":"smoke"},"logRecords":[{"timeUnixNano":"1761270001000000000","body":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_CODEX_LOG"},"attributes":[{"key":"event.name","value":{"stringValue":"tool_result"}}]}]}]}]}
EOF
)
non_tool_log_payload=$(cat <<'EOF'
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}}]},"scopeLogs":[{"scope":{"name":"smoke"},"logRecords":[{"timeUnixNano":"1761270001000000000","body":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_NON_TOOL"},"attributes":[{"key":"event.name","value":{"stringValue":"user_prompt"}},{"key":"prompt","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_PROMPT"}}]}]}]}]}
EOF
)
usage_log_payload=$(cat <<'EOF'
{"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}},{"key":"host.name","value":{"stringValue":"black-pi"}},{"key":"worker.name","value":{"stringValue":"nspawn-a1"}}]},"scopeLogs":[{"scope":{"name":"smoke"},"logRecords":[{"timeUnixNano":"1761270001000000000","body":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_API_BODY"},"attributes":[{"key":"event.name","value":{"stringValue":"api_request"}},{"key":"session.id","value":{"stringValue":"smoke-session"}},{"key":"model","value":{"stringValue":"claude-opus-5-5"}},{"key":"query_source","value":{"stringValue":"subagent"}},{"key":"input_tokens","value":{"intValue":"321"}},{"key":"cost_usd","value":{"doubleValue":0.5}},{"key":"user.email","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_API_EMAIL"}},{"key":"request_id","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_REQUEST_ID"}}]},{"timeUnixNano":"1761270001000000001","body":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_SKILL_BODY"},"attributes":[{"key":"event.name","value":{"stringValue":"skill_activated"}},{"key":"skill.name","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_SKILL; rm -rf"}},{"key":"skill.source","value":{"stringValue":"userSettings"}}]},{"timeUnixNano":"1761270001000000002","body":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_HOOK_BODY"},"attributes":[{"key":"event.name","value":{"stringValue":"hook_execution_complete"}},{"key":"hook_name","value":{"stringValue":"PreToolUse:Bash"}},{"key":"total_duration_ms","value":{"stringValue":"45"}}]}]}]}]}
EOF
)
cost_metric_payload=$(cat <<'EOF'
{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"claude-code"}},{"key":"host.name","value":{"stringValue":"msi-ms7758"}},{"key":"worker.name","value":{"stringValue":"nspawn-a1"}}]},"scopeMetrics":[{"scope":{"name":"smoke"},"metrics":[{"name":"claude_code.cost.usage","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"attributes":[{"key":"model","value":{"stringValue":"claude-opus-5-5"}},{"key":"query_source","value":{"stringValue":"subagent"}},{"key":"effort","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_EFFORT"}},{"key":"session.id","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_METRIC_SESSION"}},{"key":"user.email","value":{"stringValue":"NATIVE_OTLP_SMOKE_SENTINEL_METRIC_EMAIL"}}],"asDouble":0.5,"startTimeUnixNano":"1761270000000000000","timeUnixNano":"1761270001000000000"}]}}]}]}]}
EOF
)
write_sized_payload() {
  local path=$1 padding_bytes=$2
  {
    printf '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"codex"}},{"key":"session.id","value":{"stringValue":"'
    head -c "$padding_bytes" /dev/zero | tr '\0' x
    printf '"}}]},"scopeMetrics":[{"scope":{"name":"smoke"},"metrics":[{"name":"codex.api_request","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asInt":"1","startTimeUnixNano":"1761270000000000000","timeUnixNano":"1761270001000000000"}]}}]}]}]}'
  } > "$path"
}
write_sized_payload "$near_limit_payload_file" 1048000
write_sized_payload "$oversized_payload_file" 1048580
jq -e . >/dev/null <<< "$metric_payload"
jq -e . >/dev/null <<< "$histogram_payload"
jq -e . >/dev/null <<< "$log_payload"
jq -e . >/dev/null <<< "$codex_log_payload"
jq -e . >/dev/null <<< "$non_tool_log_payload"
jq -e . >/dev/null <<< "$usage_log_payload"
jq -e . >/dev/null <<< "$cost_metric_payload"
jq -e . "$near_limit_payload_file" >/dev/null
jq -e . "$oversized_payload_file" >/dev/null

post_otlp() {
  local signal=$1 payload=$2 token=${3:-$test_token}
  local -a headers=(-H 'Content-Type: application/json')
  [[ -n "$token" ]] && headers+=(-H "Authorization: Bearer $token")
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time 5 "${headers[@]}" -d "$payload" "$endpoint/v1/$signal"
}

post_otlp_file() {
  local signal=$1 payload_file=$2 token=${3:-$test_token}
  curl --silent --show-error --output "$oversized_response_file" --write-out '%{http_code}' \
    --max-time 5 -H 'Content-Type: application/json' -H "Authorization: Bearer $token" \
    --data-binary "@$payload_file" "$endpoint/v1/$signal"
}

metric_status=$(post_otlp metrics "$metric_payload")
histogram_status=$(post_otlp metrics "$histogram_payload")
log_status=$(post_otlp logs "$log_payload")
codex_log_status=$(post_otlp logs "$codex_log_payload")
non_tool_log_status=$(post_otlp logs "$non_tool_log_payload")
usage_log_status=$(post_otlp logs "$usage_log_payload")
cost_metric_status=$(post_otlp metrics "$cost_metric_payload")
invalid_token_status=$(post_otlp metrics "$unauthenticated_payload" 'not-the-smoke-token')
near_limit_status=$(post_otlp_file metrics "$near_limit_payload_file")
oversized_payload_status=$(post_otlp_file metrics "$oversized_payload_file")
[[ "$metric_status" == 200 && "$histogram_status" == 200 && "$log_status" == 200 \
  && "$codex_log_status" == 200 && "$non_tool_log_status" == 200 \
  && "$usage_log_status" == 200 && "$cost_metric_status" == 200 \
  && "$invalid_token_status" == 401 && "$near_limit_status" == 200 \
  && "$oversized_payload_status" == 400 ]] || {
  printf 'unexpected statuses: metrics=%s histogram=%s logs=%s codex_logs=%s other_logs=%s usage_logs=%s cost=%s invalid_token=%s near_limit=%s oversized=%s\n' \
    "$metric_status" "$histogram_status" "$log_status" "$codex_log_status" "$non_tool_log_status" \
    "$usage_log_status" "$cost_metric_status" \
    "$invalid_token_status" "$near_limit_status" "$oversized_payload_status" >&2
  printf 'oversized request response: ' >&2
  cat "$oversized_response_file" >&2
  exit 1
}
jq -e '.message == "http: request body too large"' "$oversized_response_file" >/dev/null || {
  printf 'oversized request was rejected for an unexpected reason\n' >&2
  exit 1
}

for _ in $(seq 1 50); do
  # Histogram, cost and near-limit requests emit one point each; the main
  # metric request emits two (codex.api_request + codex.tool.call).
  metrics_emitted=$(grep -c 'Metrics component_path=.*data_points=1' "$alloy_log" || true)
  tool_metrics_emitted=$(grep -c 'Metrics component_path=.*data_points=2' "$alloy_log" || true)
  logs_emitted=$(grep -c 'Logs component_path=.*log_records=1' "$alloy_log" || true)
  usage_logs_emitted=$(grep -c 'Logs component_path=.*log_records=3' "$alloy_log" || true)
  if [[ "$metrics_emitted" == 3 && "$tool_metrics_emitted" == 1 && "$logs_emitted" == 1 \
    && "$usage_logs_emitted" == 1 ]]; then
    break
  fi
  sleep 0.1
done

if grep -q 'NATIVE_OTLP_SMOKE_SENTINEL' "$alloy_log"; then
  printf 'fake sentinel survived the collector sanitizer\n' >&2
  exit 1
fi
if grep -iq 'abcdef0123456789' "$alloy_log"; then
  printf 'private log trace/span identity survived the collector sanitizer\n' >&2
  exit 1
fi
if grep -q 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' "$alloy_log"; then
  printf 'large unallowlisted resource attribute survived the collector sanitizer\n' >&2
  exit 1
fi
for expected in \
  'Name: codex.api_request' \
  'Name: codex.tool.call' \
  'DataType: Sum' \
  'IsMonotonic: true' \
  'AggregationTemporality: Cumulative' \
  'Name: codex.turn.token_usage' \
  'DataType: Histogram' \
  'Count: 2' \
  'Sum: 37' \
  'model: Str(gpt)' \
  'token_type: Str(input)' \
  'tool: Str(other)' \
  'tool: Str(exec)' \
  'success: Str(unknown)' \
  'Body: Str(tool_result)' \
  'tool_name: Str(other)' \
  'duration_ms: Str(17)' \
  'tool_result_size_bytes: Str(4242)' \
  'Name: claude_code.cost.usage' \
  'query_source: Str(subagent)' \
  'effort: Str(other)' \
  'host: Str(msi-ms7758)' \
  'host.name: Str(black-pi)' \
  'host: Str(asus-b460m)' \
  'host.name: Str(asus-b460m)' \
  'Body: Str(api_request)' \
  'session.id: Str(smoke-session)' \
  'model: Str(claude-opus-5-5)' \
  'input_tokens: Int(321)' \
  'cost_usd: Double(0.5)' \
  'worker: Str(nspawn-a1)' \
  'Body: Str(skill_activated)' \
  'skill.name: Str(other)' \
  'skill.source: Str(userSettings)' \
  'Body: Str(hook_execution_complete)' \
  'hook_name: Str(PreToolUse:Bash)' \
  'total_duration_ms: Str(45)'; do
  grep -Fq "$expected" "$alloy_log" || {
    printf 'expected sanitized output not found: %s\n' "$expected" >&2
    exit 1
  }
done
[[ "$metrics_emitted" == 3 && "$tool_metrics_emitted" == 1 && "$logs_emitted" == 1 \
  && "$usage_logs_emitted" == 1 ]] || {
  printf 'unexpected accepted data points: single=%s paired=%s logs=%s usage_logs=%s\n' \
    "$metrics_emitted" "$tool_metrics_emitted" "$logs_emitted" "$usage_logs_emitted" >&2
  exit 1
}
for absent in 'worker.name:' 'user.email' 'tool_parameters' 'tool_input' 'request_id' 'Str(user_prompt)'; do
  if grep -Fq "$absent" "$alloy_log"; then
    printf 'dropped attribute or event survived the collector sanitizer: %s\n' "$absent" >&2
    exit 1
  fi
done
if grep -Fq 'codex.private.secret_metric' "$alloy_log"; then
  printf 'non-allowlisted metric passed the collector filter\n' >&2
  exit 1
fi

metrics_before_restart=$(grep -c 'Name: codex.api_request' "$alloy_log" || true)
logs_before_restart=$logs_emitted
[[ "$metrics_before_restart" -gt 0 ]] || {
  printf 'expected sanitized metric before restart\n' >&2
  exit 1
}

kill -INT "$alloy_pid" 2>/dev/null || true
wait "$alloy_pid" 2>/dev/null || true
alloy_pid=
"${alloy_argv[@]}" >> "$alloy_log" 2>&1 &
alloy_pid=$!

restarted_unauthenticated_status=
deadline=$((SECONDS + 30))
while ((SECONDS < deadline)); do
  restarted_unauthenticated_status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --max-time 2 -H 'Content-Type: application/json' -d "$unauthenticated_payload" \
    "$endpoint/v1/metrics" || true)
  [[ "$restarted_unauthenticated_status" == 401 ]] && break
  kill -0 "$alloy_pid" 2>/dev/null || {
    printf 'Alloy exited during restart; see %s\n' "$alloy_log" >&2
    exit 1
  }
  sleep 0.1
done
[[ "$restarted_unauthenticated_status" == 401 ]] || {
  printf 'expected 401 after restart, got %s after 30 s; the end of the Alloy log:\n' "$restarted_unauthenticated_status" >&2
  tail -n 20 "$alloy_log" >&2
  exit 1
}

restarted_metric_status=$(post_otlp metrics "$metric_payload")
[[ "$restarted_metric_status" == 200 ]] || {
  printf 'expected authenticated metrics acceptance after restart, got %s\n' \
    "$restarted_metric_status" >&2
  exit 1
}
restarted_log_status=$(post_otlp logs "$log_payload")
[[ "$restarted_log_status" == 200 ]] || {
  printf 'expected authenticated log acceptance after restart, got %s\n' \
    "$restarted_log_status" >&2
  exit 1
}
for _ in $(seq 1 50); do
  metrics_after_restart=$(grep -c 'Name: codex.api_request' "$alloy_log" || true)
  logs_after_restart=$(grep -c 'Logs component_path=.*log_records=1' "$alloy_log" || true)
  if [[ "$metrics_after_restart" -gt "$metrics_before_restart" \
    && "$logs_after_restart" -gt "$logs_before_restart" ]]; then
    break
  fi
  sleep 0.1
done
[[ "$metrics_after_restart" -gt "$metrics_before_restart" ]] || {
  printf 'authenticated metric was not emitted after Alloy restart\n' >&2
  exit 1
}
expected_metrics_after_restart=$((metrics_before_restart + 1))
[[ "$metrics_after_restart" -eq "$expected_metrics_after_restart" ]] || {
  printf 'expected one export for the repeated point after restart, got %s\n' \
    "$metrics_after_restart" >&2
  exit 1
}
expected_logs_after_restart=$((logs_before_restart + 1))
[[ "$logs_after_restart" -eq "$expected_logs_after_restart" ]] || {
  printf 'expected one sanitized log after restart, got %s\n' \
    "$logs_after_restart" >&2
  exit 1
}
if grep -q 'NATIVE_OTLP_SMOKE_SENTINEL' "$alloy_log"; then
  printf 'fake sentinel survived collector restart\n' >&2
  exit 1
fi
if grep -iq 'abcdef0123456789' "$alloy_log"; then
  printf 'private log trace/span identity survived collector restart\n' >&2
  exit 1
fi
if grep -q 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx' "$alloy_log"; then
  printf 'large unallowlisted resource attribute survived collector restart\n' >&2
  exit 1
fi

printf 'PASS: authenticated OTLP ingestion recovered after restart; 1 MiB request limit enforced; auth and redaction remained enforced\n'

# The session sum (homelab-gitops#226) in Claude Code's live shape: one request per session, cumulative, a start time
# from before the collector started and fixed per stream, the time moving on per export. After a start nothing leaves
# until each session's second export (cumulativetodelta's "auto" takes the first as the baseline), then the output
# is the sessions' summed increase since. This is what acer showed after its first start (#414).
kill -INT "$alloy_pid" 2>/dev/null || true
wait "$alloy_pid" 2>/dev/null || true
alloy_pid=
sum_port=$((otlp_port + 3))
cp "$deployed_config" "$rewritten_file"
chmod u+w "$rewritten_file"
for rewrite in \
  "s/127.0.0.1:4318/127.0.0.1:$sum_port/" \
  's/otelcol.exporter.otlphttp.native.input/otelcol.exporter.debug.test.input/g' \
  's/otelcol.exporter.loki.native.input/otelcol.exporter.debug.test.input/g'; do
  cp "$rewritten_file" "$config_file"
  sed -i -e "$rewrite" "$rewritten_file"
  if cmp -s "$rewritten_file" "$config_file"; then
    printf 'session-sum rewrite matched nothing in %s: %s\n' "$deployed_config" "$rewrite" >&2
    exit 1
  fi
done
awk '/^otelcol.exporter.loki "native" \{/ { skip = 1 } !skip { print }' "$rewritten_file" > "$config_file"
cat >> "$config_file" <<'EOF'
otelcol.exporter.debug "test" {
  verbosity = "detailed"
}
EOF
: > "$alloy_log"
mapfile -d '' alloy_argv < <(argv_of "127.0.0.1:$((otlp_port + 4))" "$sum_storage_dir" "$config_file")
"${alloy_argv[0]}" validate --stability.level=experimental "$config_file" >/dev/null
"${alloy_argv[@]}" > "$alloy_log" 2>&1 &
alloy_pid=$!
sum_status=
for _ in $(seq 1 50); do
  sum_status=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 2 \
    -H 'Content-Type: application/json' -d '{"resourceMetrics":[]}' "http://127.0.0.1:$sum_port/v1/metrics" || true)
  [[ "$sum_status" == 401 ]] && break
  kill -0 "$alloy_pid" 2>/dev/null || {
    printf 'Alloy exited during the session-sum startup; see %s\n' "$alloy_log" >&2
    exit 1
  }
  sleep 0.1
done
[[ "$sum_status" == 401 ]] || {
  printf 'session sum: expected unauthenticated OTLP response 401, got %s\n' "$sum_status" >&2
  exit 1
}

# s1 and s2 started two hours before this collector; s3 starts after it
old_start=$(( $(date +%s%N) - 2 * 3600 * 1000000000 ))
new_start=$(date +%s%N)
send_cost() {
  local session=$1 value=$2 start=$3
  curl --silent --fail --output /dev/null --max-time 5 -H "Authorization: Bearer $test_token" \
    -H 'Content-Type: application/json' --data "$(jq -cn --arg s "$session" --argjson v "$value" \
      --arg start "$start" --arg now "$(date +%s%N)" '{resourceMetrics: [{
        resource: {attributes: [{key: "service.name", value: {stringValue: "claude-code"}},
          {key: "host.name", value: {stringValue: "acer-swift"}}]},
        scopeMetrics: [{scope: {name: "com.anthropic.claude_code"}, metrics: [{name: "claude_code.cost.usage",
          unit: "USD", sum: {aggregationTemporality: 2, isMonotonic: true, dataPoints: [{
            attributes: [{key: "session.id", value: {stringValue: $s}}, {key: "model", value: {stringValue: "claude-opus-4-1"}}],
            startTimeUnixNano: $start, timeUnixNano: $now, asDouble: $v}]}}]}]}]}')" \
    "http://127.0.0.1:$sum_port/v1/metrics"
}
cost_values() {
  grep -o 'Name: claude_code.cost.usage[^"]*Value: [0-9.]*' "$alloy_log" | sed 's/.*Value: //' || true
}
expect_last_cost() {
  local want=$1 got=
  for _ in $(seq 1 50); do
    got=$(cost_values | tail -n 1)
    [[ "$got" == "$want" ]] && return 0
    sleep 0.1
  done
  printf 'session sum: expected %s, last emitted %s (all: %s)\n' "$want" "${got:-nothing}" "$(cost_values | tr '\n' ' ')" >&2
  exit 1
}

# First export: the older sessions only set their baselines, the new one counts in full ("drop" would lose it,
# "keep" would add the older totals). Two seconds cover the 1 s interval tick, so a late older-session value shows.
send_cost s1 10 "$old_start"
send_cost s2 20 "$old_start"
send_cost s3 3 "$new_start"
expect_last_cost 3.000000
sleep 2
first=$(cost_values | sort -u | tr '\n' ' ')
[[ "$first" == "3.000000 " ]] || {
  printf 'session sum: the first export must emit only the new session (3), emitted %s\n' "$first" >&2
  exit 1
}
send_cost s1 10.5 "$old_start"
send_cost s2 21 "$old_start"
send_cost s3 3 "$new_start"
expect_last_cost 4.500000
send_cost s1 11 "$old_start"
expect_last_cost 5.000000

printf 'PASS: session sum in the live shape: older sessions baseline on the first export, a new one counts at once (3, 4.5, 5)\n'
