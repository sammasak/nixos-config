import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


fixture = Path(__file__).with_suffix('.nix')
nixpkgs = sys.argv[1]
with tempfile.TemporaryDirectory(prefix='native-otel-fish-') as directory:
    root = Path(directory)
    token = root / 'token'
    token.write_text('synthetic-fish-token\n')
    capture = root / 'capture.jsonl'
    stub = root / 'stub.py'
    stub.write_text('''import json, os, sys
with open(os.environ['FISH_TEST_CAPTURE'], 'a') as output:
    output.write(json.dumps({'args': sys.argv[1:],
        'host': os.environ.get('OTEL_RESOURCE_ATTRIBUTES'),
        'temporality': os.environ.get('OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE'),
        'has_header': bool(os.environ.get('OTEL_EXPORTER_OTLP_HEADERS'))}) + '\\n')
sys.exit(17)
''')
    environment = dict(os.environ, FISH_TEST_CAPTURE=str(capture))
    for name in ['OTEL_RESOURCE_ATTRIBUTES', 'OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE',
                 'OTEL_EXPORTER_OTLP_HEADERS']:
        environment.pop(name, None)
    cases = [(True, True), (True, False), (False, True)]
    for dev_tools, native_otel in cases:
        result = subprocess.check_output([
            'nix-instantiate', '--eval', '--strict', '--json', str(fixture),
            '--argstr', 'nixpkgs', nixpkgs,
            '--arg', 'devTools', str(dev_tools).lower(),
            '--arg', 'nativeOtel', str(native_otel).lower()])
        functions = json.loads(result)
        for agent in ['codex', 'claude']:
            for token_present in [True, False]:
                body = functions[agent].replace('/run/secrets/native_otlp_auth',
                                               str(token if token_present else root / 'missing'))
                dispatch = f'{shutil.which("python3")} {stub}'
                if dev_tools:
                    body = body.replace('/stub/herdr-agent-launcher/bin/herdr-agent-launcher', dispatch)
                body = body.replace(f'/stub/native-otel-{agent}-env/bin/native-otel-{agent}-env', dispatch)
                body = body.replace(f'/stub/{agent}/bin/{agent}', agent)
                capture.unlink(missing_ok=True)
                command = (f'function {agent}\n{body}\nend\n'
                           f'{agent} --version "argument with spaces"\n'
                           'set -l saved_status $status\n'
                           'set -q OTEL_RESOURCE_ATTRIBUTES; and exit 99\n'
                           'exit $saved_status')
                process = subprocess.run(['fish', '--no-config', '-c', command], env=environment,
                                         capture_output=True, text=True)
                assert process.returncode == 17, (agent, process.returncode, process.stderr)
                records = [json.loads(line) for line in capture.read_text().splitlines()]
                assert len(records) == 1, (agent, dev_tools, native_otel, len(records))
                assert records[0]['args'] == [agent, '--version', 'argument with spaces'], records
                if dev_tools and native_otel:
                    assert records[0]['host'] == 'host.name=lenovo-21cb001pmx', records
                    if agent == 'codex':
                        assert records[0]['temporality'] == 'cumulative', records
                        assert not records[0]['has_header'], records
                    else:
                        assert records[0]['has_header'] == token_present, records
                elif not native_otel:
                    assert records[0]['host'] is None, records
        print(f'PASS: devTools={dev_tools}, nativeOtel={native_otel}; one dispatch, arguments and status preserved')
