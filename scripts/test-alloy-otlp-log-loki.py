"""alloy-otlp's log privacy (modules/homelab/monitoring/alloy-otlp.alloy), ported from homelab-gitops
scripts/test-native-otlp-log-loki.py: acer's deployed config, run with acer's Alloy and the unit's own arguments
(scripts/alloy_otlp_argv.py), against black-pi's Loki version. Prompts, tool output, identities and trace ids never
reach Loki, and the stored schema is exact."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request

import alloy_otlp_argv


root = Path(tempfile.mkdtemp(prefix='otlp-log-privacy-', dir=os.environ.get('TMPDIR', '/tmp')))
print('Evidence:', root, flush=True)
ports = []
for unused in range(4):
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        ports.append(listener.getsockname()[1])
receiver_port, alloy_port, loki_port, grpc_port = ports
_, loki_bin = alloy_otlp_argv.unit()
alloy_argv = alloy_otlp_argv.overridden(f'127.0.0.1:{alloy_port}', str(root / 'alloy'), str(root / 'alloy.alloy'))


def replace_once(text, old, new):
    # a rewrite that matched nothing would test some other config
    assert text.count(old) == 1, f'{old!r} occurs {text.count(old)} times in the deployed config, not once'
    return text.replace(old, new)


base = Path(alloy_otlp_argv.config_path()).read_text()
assert base.count('otelcol.storage.file "native"') == 1, 'no durable queue block to cut at'
config = base.split('otelcol.storage.file "native"')[0]
config = replace_once(config, '127.0.0.1:4318', f'127.0.0.1:{receiver_port}')
config = replace_once(config, 'http://192.168.10.137:3100', f'http://127.0.0.1:{loki_port}')
config = replace_once(config, 'metrics = [otelcol.exporter.otlphttp.native.input]', 'metrics = []')
(root / 'alloy.alloy').write_text(config)
(root / 'loki.yml').write_text(f'''auth_enabled: false
server:
  http_listen_address: 127.0.0.1
  http_listen_port: {loki_port}
  grpc_listen_address: 127.0.0.1
  grpc_listen_port: {grpc_port}
common:
  instance_addr: 127.0.0.1
  path_prefix: {root}/loki
  storage:
    filesystem:
      chunks_directory: {root}/loki/chunks
      rules_directory: {root}/loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2020-10-24
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
ingester:
  lifecycler:
    min_ready_duration: 0s
limits_config:
  allow_structured_metadata: false
''')
processes = []
environment = dict(os.environ, OTLP_BEARER_TOKEN='synthetic-log-token')


def get(url):
    with urllib.request.urlopen(url, timeout=3) as response:
        return response.read()


try:
    commands = [[loki_bin, '-config.file=' + str(root / 'loki.yml')], alloy_argv]
    for index, command in enumerate(commands):
        with (root / f'process-{index}.log').open('w') as output:
            processes.append(subprocess.Popen(command, env=environment, stdout=output, stderr=output))
    for attempt in range(200):
        assert all(process.poll() is None for process in processes), 'process exited'
        try:
            get(f'http://127.0.0.1:{alloy_port}/-/ready')
            get(f'http://127.0.0.1:{loki_port}/ready')
            break
        except OSError:
            time.sleep(.1)
    else:
        raise RuntimeError('readiness timeout')
    timestamp = time.time_ns()
    attribute = lambda key, value: {'key': key, 'value': {'stringValue': value}}
    integer = lambda key, value: {'key': key, 'value': {'intValue': str(value)}}
    sentinel = 'LOG_METADATA_PRIVATE_SENTINEL'
    trace_id, span_id = 'abcdef0123456789abcdef0123456789', 'abcdef0123456789'
    private = [attribute('user.email', sentinel), attribute('user.id', sentinel),
               attribute('organization.id', sentinel), attribute('tool_parameters', sentinel),
               attribute('tool_input', sentinel), attribute('prompt', sentinel),
               attribute('request_id', sentinel), attribute('error', sentinel),
               attribute('stamped.worker', 'forged')]

    def resource(attributes, host='lenovo-21cb001pmx', worker='nspawn-a1', service='claude-code'):
        offset = len(resource_logs)
        return {'schemaUrl': 'https://' + sentinel + '.invalid',
            'resource': {'attributes': [attribute('service.name', service), attribute('host.name', host),
                attribute('worker.name', worker), attribute('session.id', sentinel)]},
            'scopeLogs': [{'schemaUrl': 'https://' + sentinel + '.invalid',
                'scope': {'name': sentinel, 'version': sentinel, 'attributes': [attribute('private', sentinel)]},
                'logRecords': [{'timeUnixNano': str(timestamp + offset), 'observedTimeUnixNano': str(timestamp),
                    'severityNumber': 9, 'severityText': sentinel, 'traceId': trace_id, 'spanId': span_id,
                    'body': {'stringValue': sentinel}, 'attributes': attributes + private}]}]}

    resource_logs = []
    expected = {}

    def accept(event, attributes, kept, labels=None, **resource_args):
        expected[str(timestamp + len(resource_logs))] = (event, labels or {}, kept)
        resource_logs.append(resource([attribute('event.name', event)] + attributes, **resource_args))

    def deny(event, **resource_args):
        resource_logs.append(resource([attribute('event.name', event)], **resource_args))

    common = {'session.id': 'session-1', 'worker': 'nspawn-a1'}
    accept('tool_result', [attribute('tool_name', 'Bash'), attribute('success', 'true'),
        attribute('duration_ms', '12'), attribute('tool_result_size_bytes', '300'),
        attribute('session.id', 'session-1'), attribute('command', sentinel)],
        dict(common, success='true', duration_ms='12', tool_result_size_bytes='300'),
        {'tool_name': 'Bash'})
    accept('tool_result', [attribute('tool_name', sentinel), attribute('success', sentinel),
        attribute('session.id', 'session-1')], {'session.id': 'session-1', 'success': 'unknown'},
        {'tool_name': 'other', 'host_name': 'other'}, host=sentinel, worker='Bad_Worker!')
    accept('tool_decision', [attribute('tool_name', 'mcp__github__' + sentinel),
        attribute('decision', 'accept'), attribute('source', 'config'), attribute('session.id', 'session-1')],
        dict(common, decision='accept', source='config'), {'tool_name': 'mcp'})
    accept('api_request', [attribute('session.id', 'session-1'), attribute('prompt.id', 'prompt-1'),
        attribute('model', 'claude-opus-5-5'), attribute('query_source', 'main'), attribute('effort', 'high'),
        attribute('speed', 'normal'), integer('input_tokens', 10), integer('output_tokens', 20),
        integer('cache_read_tokens', 30), integer('cache_creation_tokens', 40),
        {'key': 'cost_usd', 'value': {'doubleValue': 0.25}}, integer('duration_ms', 900),
        integer('ttft_ms', 300), attribute('client_request_id', sentinel)],
        dict(common, **{'prompt.id': 'prompt-1', 'model': 'claude-opus-5-5', 'query_source': 'main',
            'effort': 'high', 'speed': 'normal', 'input_tokens': 10, 'output_tokens': 20,
            'cache_read_tokens': 30, 'cache_creation_tokens': 40, 'cost_usd': 0.25,
            'duration_ms': 900, 'ttft_ms': 300}))
    accept('api_error', [attribute('session.id', 'session-1'), attribute('model', sentinel + '<>'),
        attribute('status_code', '529'), attribute('attempt', '2')],
        dict(common, model='other', status_code='529', attempt='2'))
    accept('api_retries_exhausted', [attribute('session.id', 'session-1'), attribute('attempt', '10')],
        dict(common, attempt='10'))
    accept('skill_activated', [attribute('session.id', 'session-1'), attribute('skill.name', 'bulk-reader'),
        attribute('invocation_trigger', 'model'), attribute('skill.source', 'userSettings')],
        dict(common, **{'skill.name': 'bulk-reader', 'invocation_trigger': 'model',
            'skill.source': 'userSettings'}))
    accept('skill_activated', [attribute('session.id', 'session-1'), attribute('skill.name', sentinel + ' $(id)')],
        dict(common, **{'skill.name': 'other'}))
    accept('skill_use', [attribute('session.id', 'session-1'), attribute('skill.name', 'superpowers:brainstorming'),
        attribute('invocation_trigger', 'user-slash'), attribute('agent_type', 'Explore'), attribute('args', sentinel)],
        dict(common, **{'skill.name': 'superpowers:brainstorming', 'invocation_trigger': 'user-slash',
            'agent_type': 'Explore'}))
    accept('subagent_completed', [attribute('session.id', 'session-1'), attribute('agent_type', 'Explore'),
        {'key': 'is_async', 'value': {'boolValue': False}}, integer('total_tokens', 500),
        integer('total_tool_uses', 3), integer('duration_ms', 4000), attribute('agent.name', sentinel)],
        dict(common, agent_type='Explore', is_async=False, total_tokens=500, total_tool_uses=3,
            duration_ms=4000))
    accept('hook_execution_complete', [attribute('session.id', 'session-1'),
        attribute('hook_event', 'PreToolUse'), attribute('hook_name', 'PreToolUse:Bash'),
        attribute('num_hooks', '2'), attribute('num_success', '2'), attribute('num_blocking', '0'),
        attribute('num_non_blocking_error', '0'), attribute('num_cancelled', '0'),
        attribute('total_duration_ms', '45')],
        dict(common, hook_event='PreToolUse', hook_name='PreToolUse:Bash', num_hooks='2', num_success='2',
            num_blocking='0', num_non_blocking_error='0', num_cancelled='0', total_duration_ms='45'))
    accept('compaction', [attribute('session.id', 'session-1'), attribute('trigger', 'auto'),
        attribute('pre_tokens', '150000'), attribute('post_tokens', '20000')],
        dict(common, trigger='auto', pre_tokens='150000', post_tokens='20000'))
    accept('work_ref', [attribute('session.id', 'session-1'), attribute('vcs.owner.name', 'sammasak'),
        attribute('vcs.repository.name', 'nixos-config'), attribute('vcs.ref.head.name', 'fix/143-relay'),
        attribute('vcs.ref.head.revision', '0123456789ab'), attribute('work.ref.hint', '143'),
        attribute('vcs.repository.url.full', sentinel)],
        dict(common, **{'vcs.owner.name': 'sammasak', 'vcs.repository.name': 'nixos-config',
            'vcs.ref.head.name': 'fix/143-relay', 'vcs.ref.head.revision': '0123456789ab',
            'work.ref.hint': '143'}))
    accept('work_ref', [attribute('session.id', 'session-1'), attribute('vcs.repository.name', sentinel + ' x'),
        attribute('vcs.ref.head.name', sentinel + ' $(id)'), attribute('vcs.ref.head.revision', sentinel),
        attribute('work.ref.hint', sentinel)],
        dict(common, **{'vcs.repository.name': 'other', 'vcs.ref.head.name': 'other',
            'vcs.ref.head.revision': 'other', 'work.ref.hint': 'other'}))
    deny('user_prompt')
    deny('session_start')
    deny('tool_result', service='codex')
    payload = {'resourceLogs': resource_logs}
    (root / 'input.json').write_text(json.dumps(payload))

    def post(logs, **headers):
        request = urllib.request.Request(f'http://127.0.0.1:{receiver_port}/v1/logs',
            data=json.dumps({'resourceLogs': logs}).encode(), headers={'Content-Type': 'application/json',
            'Authorization': 'Bearer synthetic-log-token', **headers})
        with urllib.request.urlopen(request, timeout=5) as response:
            assert response.status == 200

    post(resource_logs)
    # A relay's X-Otel-Worker stamp wins over what the sender claims; a malformed stamp becomes "other".
    stamped = [attribute('session.id', 'session-1')]
    for stamp, worker in (('env-a', 'env-a'), (sentinel + '!', 'other')):
        first = len(resource_logs)
        accept('api_request', stamped, {'session.id': 'session-1', 'worker': worker})
        post(resource_logs[first:], **{'X-Otel-Worker': stamp})
    query = urllib.parse.urlencode({'query': '{exporter="OTLP"}', 'start': str(timestamp - 10**9),
                                    'end': str(timestamp + 60 * 10**9), 'limit': 100})
    settled_at = None
    for attempt in range(80):
        result = json.loads(get(f'http://127.0.0.1:{loki_port}/loki/api/v1/query_range?' + query))
        entries = [line for stream in result['data']['result'] for line in stream['values']]
        if len(entries) >= len(expected) and settled_at is None:
            settled_at = time.monotonic() + 3
        if settled_at is not None and time.monotonic() >= settled_at:
            break
        time.sleep(.25)
    assert settled_at is not None and time.monotonic() >= settled_at, 'negative-event observation incomplete'
    assert len(entries) == len(expected), entries
    (root / 'backend.json').write_text(json.dumps(result))
    leaked = [value for value in [sentinel, trace_id, span_id] if value in json.dumps(result)]
    print('leaked fields:', leaked, flush=True)
    assert not leaked, 'sensitive log metadata reached Loki'
    seen = set()
    for stream in result['data']['result']:
        for event_time, line in stream['values']:
            assert event_time in expected and event_time not in seen, event_time
            seen.add(event_time)
            event, labels, kept = expected[event_time]
            assert stream['stream'] == dict({
                'event_name': event, 'exporter': 'OTLP', 'host_name': 'lenovo-21cb001pmx',
                'job': 'claude-code', 'level': 'INFO', 'observer': 'harness',
                'service_name': 'claude-code',
            }, **labels), stream['stream']
            assert json.loads(line) == {'body': event, 'attributes': kept}, line
    assert seen == set(expected), seen
    print(f'PASS: exact Loki schema; {len(expected)} bounded usage events; '
          'Codex/unlisted events and identities absent', flush=True)
finally:
    for process in reversed(processes):
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

