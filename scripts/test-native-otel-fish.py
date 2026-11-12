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
    dispatch = f'{shutil.which("python3")} {stub}'
    environment = dict(os.environ, FISH_TEST_CAPTURE=str(capture))
    for name in ['OTEL_RESOURCE_ATTRIBUTES', 'OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE',
                 'OTEL_EXPORTER_OTLP_HEADERS']:
        environment.pop(name, None)

    def run(argv, **kwargs):
        capture.unlink(missing_ok=True)
        process = subprocess.run(argv, capture_output=True, text=True, **kwargs)
        assert process.returncode == 17, (argv, process.returncode, process.stderr)
        records = [json.loads(line) for line in capture.read_text().splitlines()]
        assert len(records) == 1, (argv, records)
        assert not records[0]['has_header'], records
        return records[0]

    composed = None
    for dev_tools, native_otel in [(True, True), (True, False), (False, True)]:
        result = json.loads(subprocess.check_output([
            'nix-instantiate', '--eval', '--strict', '--json', str(fixture),
            '--argstr', 'nixpkgs', nixpkgs,
            '--arg', 'devTools', str(dev_tools).lower(),
            '--arg', 'nativeOtel', str(native_otel).lower()]))
        functions, wrappers = result['functions'], result['codex']
        assert sorted(a for a in functions if a in ('codex', 'claude')) == (['claude', 'codex'] if dev_tools else []), functions
        assert not any('OTEL_' in body for body in functions.values()), functions
        assert len(wrappers) == (1 if dev_tools and native_otel else 0), wrappers
        for agent in functions.keys() & {'codex', 'claude'}:
            body = functions[agent].replace('/stub/herdr-agent-launcher/bin/herdr-agent-launcher', dispatch)
            record = run(['fish', '--no-config', '-c',
                          f'function {agent}\n{body}\nend\n{agent} --version "argument with spaces"\n'
                          'set -l saved_status $status\nset -q OTEL_RESOURCE_ATTRIBUTES; and exit 99\nexit $saved_status'],
                         env=environment)
            assert record['args'] == [agent, '--version', 'argument with spaces'], record
            assert record['host'] is None, record
        if wrappers:
            composed = functions, wrappers[0]
        print(f'PASS: devTools={dev_tools}, nativeOtel={native_otel}; codex wrapper on PATH: {bool(wrappers)}, '
              'no Fish function sets OTEL_, one dispatch')

    functions, wrapper = composed
    assert wrapper['priority'] < 5, wrapper
    codex = root / 'codex'
    codex.write_text(f'#!{shutil.which("bash")}\n' + wrapper['text'].replace('/stub/codex/bin/codex', dispatch))
    codex.chmod(0o700)
    record = run([str(codex), 'exec', 'argument with spaces'], env=environment, stdin=subprocess.DEVNULL)
    assert record['args'] == ['exec', 'argument with spaces'], record
    assert record['host'] == 'host.name=lenovo-21cb001pmx', record
    assert record['temporality'] == 'cumulative', record
    print('PASS: the codex wrapper outranks pkgs.codex and exports host.name and cumulative temporality to any caller')

    launcher = fixture.parent.parent / 'modules/programs/cli/herdr/agent-launcher.sh'
    claude = root / 'claude'
    claude.write_text(f'#!{sys.executable}\n' + stub.read_text())
    claude.chmod(0o700)
    for agent in ['codex', 'claude']:
        body = functions[agent].replace('/stub/herdr-agent-launcher/bin/herdr-agent-launcher',
                                        f'{shutil.which("bash")} {launcher}')
        record = run(['fish', '--no-config', '-c', f'function {agent}\n{body}\nend\n{agent} --version "argument with spaces"'],
                     env=dict(environment, PATH=f'{root}:{environment["PATH"]}'), stdin=subprocess.DEVNULL)
        assert record['args'] == ['--version', 'argument with spaces'], record
        if agent == 'codex':
            assert record['host'] == 'host.name=lenovo-21cb001pmx', record
            assert record['temporality'] == 'cumulative', record
        else:
            assert record['host'] is None, record
    print('PASS: real Herdr non-TTY launcher reaches the codex wrapper on PATH once and preserves status')
