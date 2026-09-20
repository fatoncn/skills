import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { EventEmitter } from 'node:events';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import {
  backoffDelay,
  buildSshArgs,
  renderLocations,
  systemdExecArg,
  systemdUnitString,
  validateManifest,
} from '../scripts/lib.mjs';
import { render } from '../scripts/render.mjs';
import { reportFatalError, superviseTunnel } from '../scripts/tunnel-runner.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));

function validManifest() {
  return {
    version: 1,
    project: 'demo-app',
    domain: 'demo.example.com',
    access: { mode: 'application' },
    ssh: {
      host: 'relay.example.com',
      user: 'tunnel-demo',
      port: 22,
      knownHostsFile: '/tmp/demo-known-hosts',
      identityFile: '/tmp/demo-id',
    },
    tls: { email: 'ops@example.com' },
    routes: [
      { name: 'web', publicPath: '/', kind: 'http', localHost: '127.0.0.1', localPort: 3000, remotePort: 18001, healthPath: '/healthz' },
      { name: 'events', publicPath: '/events/', kind: 'sse', localHost: '127.0.0.1', localPort: 3000, remotePort: 18002 },
      { name: 'socket', publicPath: '/socket/', kind: 'websocket', localHost: '127.0.0.1', localPort: 3001, remotePort: 18003 },
    ],
  };
}

test('renders a complete local-only artifact set with protocol-specific Nginx behavior', async () => {
  const temporary = await mkdtemp(path.join(os.tmpdir(), 'public-access-test-'));
  const manifestPath = path.join(temporary, 'input.json');
  const output = path.join(temporary, '$rendered');
  try {
    await writeFile(manifestPath, JSON.stringify(validManifest()));
    const result = await render(manifestPath, output);
    assert.equal(result.files.length, 8);
    const bootstrap = await readFile(path.join(output, 'nginx-bootstrap.conf'), 'utf8');
    const nginx = await readFile(path.join(output, 'nginx-site.conf'), 'utf8');
    const sshConfig = await readFile(path.join(output, 'ssh_config'), 'utf8');
    const verification = await readFile(path.join(output, 'verification.md'), 'utf8');
    const systemdUnit = await readFile(path.join(output, 'public-access-demo-app.service'), 'utf8');
    const summary = JSON.parse(await readFile(path.join(output, 'render-summary.json'), 'utf8'));
    assert.doesNotMatch(bootstrap, /ssl_certificate/);
    assert.match(nginx, /location \^~ \/events\//);
    assert.match(nginx, /proxy_buffering off/);
    assert.match(nginx, /location \^~ \/socket\//);
    assert.match(nginx, /proxy_set_header Upgrade \$http_upgrade/);
    assert.match(nginx, /proxy_set_header Connection "upgrade"/);
    assert.doesNotMatch(nginx, /map \$http_upgrade/);
    assert.match(sshConfig, /RemoteForward 127\.0\.0\.1:18001 127\.0\.0\.1:3000/);
    assert.doesNotMatch(sshConfig, /0\.0\.0\.0/);
    assert.match(verification, /-o ClearAllForwardings=yes/);
    const probeConfig = spawnSync('ssh', ['-G', '-F', path.join(output, 'ssh_config'), '-o', 'ClearAllForwardings=yes', 'public-access-demo-app'], { encoding: 'utf8' });
    assert.equal(probeConfig.status, 0, probeConfig.stderr);
    assert.doesNotMatch(probeConfig.stdout, /^remoteforward /m);
    assert.match(systemdUnit, /WorkingDirectory="[^"]+\/\$rendered"/);
    assert.match(systemdUnit, /ExecStart=.*\/\$\$rendered\/manifest\.json"/);
    assert.equal(summary.networkAccessPerformed, false);
    assert.equal(summary.processStarted, false);
    assert.equal(summary.remoteBind, '127.0.0.1');
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
});

test('rejects invalid types, unknown fields, unsafe names, paths, and overlap', () => {
  const booleanPort = validManifest();
  booleanPort.routes[0].localPort = true;
  assert.throws(() => validateManifest(booleanPort), /integer/);

  const unknown = validManifest();
  unknown.ssh.strictHostKeyChecking = 'no';
  assert.throws(() => validateManifest(unknown), /unknown field/);

  const unsafeName = validManifest();
  unsafeName.project = 'demo;reload';
  assert.throws(() => validateManifest(unsafeName), /invalid format/);

  const unsafePath = validManifest();
  unsafePath.routes[1].publicPath = '/events/;\ninclude /tmp/evil;';
  assert.throws(() => validateManifest(unsafePath), /control characters|safe absolute/);

  const overlap = validManifest();
  overlap.routes[2].publicPath = '/events/private/';
  assert.throws(() => validateManifest(overlap), /overlap/);

  const expandedSshPath = validManifest();
  expandedSshPath.ssh.knownHostsFile = '/tmp/known-$HOME';
  assert.throws(() => validateManifest(expandedSshPath), /OpenSSH expands/);
});

test('quotes a known-host path with spaces and quotes for the real OpenSSH parser', () => {
  const manifest = validManifest();
  manifest.ssh.knownHostsFile = '/tmp/known "hosts file';
  delete manifest.ssh.identityFile;
  const parsed = spawnSync('ssh', ['-G', ...buildSshArgs(manifest)], { encoding: 'utf8' });
  assert.equal(parsed.error, undefined);
  assert.equal(parsed.status, 0, parsed.stderr);
  assert.match(parsed.stdout, /userknownhostsfile/);
});

test('escapes dollar expansion only in systemd ExecStart arguments', () => {
  assert.equal(systemdExecArg('/tmp/$HOME/%i'), '"/tmp/$$HOME/%%i"');
  assert.equal(systemdUnitString('/tmp/$HOME/%i'), '"/tmp/$HOME/%%i"');
});

test('forces loopback forwards, strict host keys, keepalive, and ignores user SSH config', () => {
  const args = buildSshArgs(validManifest());
  assert.deepEqual(args.slice(0, 2), ['-F', '/dev/null']);
  assert.ok(args.includes('StrictHostKeyChecking=yes'));
  assert.ok(args.includes('ServerAliveInterval=15'));
  assert.ok(args.includes('ServerAliveCountMax=2'));
  assert.ok(args.includes('ExitOnForwardFailure=yes'));
  const forwards = args.filter((value, index) => args[index - 1] === '-R');
  assert.deepEqual(forwards, [
    '127.0.0.1:18001:127.0.0.1:3000',
    '127.0.0.1:18002:127.0.0.1:3000',
    '127.0.0.1:18003:127.0.0.1:3001',
  ]);
  assert.ok(forwards.every((value) => !value.includes('0.0.0.0')));
});

test('uses bounded exponential backoff and stops after the attempt limit', async () => {
  const delays = [];
  const spawnCalls = [];
  const logs = [];
  const spawnImpl = (command, args, options) => {
    spawnCalls.push({ command, args, options });
    const child = new EventEmitter();
    child.kill = () => true;
    queueMicrotask(() => child.emit('exit', 255, null));
    return child;
  };
  let terminalError;
  try {
    await superviseTunnel(validManifest(), {
      spawnImpl,
      sleepImpl: async (delay) => delays.push(delay),
      signalSource: new EventEmitter(),
      logger: {
        info: (line) => logs.push(JSON.parse(line)),
        warn: (line) => logs.push(JSON.parse(line)),
        error: (line) => logs.push(JSON.parse(line)),
      },
      maxAttempts: 3,
      now: () => 0,
    });
  } catch (error) {
    terminalError = error;
    reportFatalError(error, {
      error: (line) => logs.push(JSON.parse(line)),
    });
  }
  assert.match(terminalError.message, /exhausted 3 consecutive attempts/);
  assert.deepEqual(delays, [backoffDelay(1), backoffDelay(2)]);
  assert.equal(spawnCalls.length, 3);
  assert.ok(spawnCalls.every((call) => call.command === 'ssh' && call.options.shell === false));
  assert.ok(logs.every((entry) => entry.module === 'public_access' && entry.component === 'tunnel_runner'));
  assert.deepEqual(logs.filter((entry) => entry.status === 'retrying').map((entry) => entry.delayMs), [1000, 2000]);
  assert.equal(logs.filter((entry) => entry.status === 'failed').length, 1);
  assert.equal(logs.at(-1).status, 'failed');
});

test('logs an unrecorded configuration failure exactly once', () => {
  const logs = [];
  const logger = { error: (line) => logs.push(JSON.parse(line)) };
  reportFatalError(new Error('invalid manifest'), logger);
  assert.equal(logs.length, 1);
  assert.equal(logs[0].status, 'failed');
  assert.equal(logs[0].exitError, 'invalid manifest');
});

test('forwards termination signals to ssh and exits without retry', async () => {
  const signals = new EventEmitter();
  const killed = [];
  let sleeps = 0;
  const child = new EventEmitter();
  child.kill = (signal) => {
    killed.push(signal);
    queueMicrotask(() => child.emit('exit', null, signal));
    return true;
  };
  const running = superviseTunnel(validManifest(), {
    spawnImpl: () => child,
    sleepImpl: async () => { sleeps += 1; },
    signalSource: signals,
    logger: { info() {}, warn() {} },
  });
  queueMicrotask(() => signals.emit('SIGTERM'));
  assert.equal(await running, 0);
  assert.deepEqual(killed, ['SIGTERM']);
  assert.equal(sleeps, 0);
});

test('gateway mode renders a project-specific include without claiming built-in authentication', () => {
  const manifest = validManifest();
  manifest.access.mode = 'gateway';
  const nginx = renderLocations(manifest);
  assert.match(nginx, /include \/etc\/nginx\/snippets\/public-access-demo-app-gateway\.conf/);
  assert.doesNotMatch(nginx, /auth_basic|auth_request/);
  const second = validManifest();
  second.project = 'second-app';
  second.access.mode = 'gateway';
  const secondNginx = renderLocations(second);
  assert.match(secondNginx, /public-access-second-app-gateway\.conf/);
  assert.notEqual(nginx, secondNginx);
});

test('example manifest remains valid', async () => {
  const example = JSON.parse(await readFile(path.join(here, '..', 'assets', 'manifest.example.json'), 'utf8'));
  assert.equal(validateManifest(example).routes.length, 3);
});
