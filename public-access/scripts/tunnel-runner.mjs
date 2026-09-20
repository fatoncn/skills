#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { buildSshArgs, backoffDelay, validateManifest } from './lib.mjs';

export async function loadManifest(manifestPath) {
  let parsed;
  try {
    parsed = JSON.parse(await readFile(manifestPath, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read manifest: ${error.message}`);
  }
  return validateManifest(parsed);
}

export async function superviseTunnel(manifest, options = {}) {
  const checked = validateManifest(manifest);
  const spawnImpl = options.spawnImpl ?? spawn;
  const sleepImpl = options.sleepImpl ?? sleep;
  const signalSource = options.signalSource ?? process;
  const logger = options.logger ?? console;
  const now = options.now ?? Date.now;
  const maxAttempts = options.maxAttempts ?? 8;
  const stableMs = options.stableMs ?? 60_000;
  let consecutiveFailures = 0;
  let attempt = 0;

  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 100) {
    throw new Error('maxAttempts must be an integer from 1 to 100');
  }

  while (consecutiveFailures < maxAttempts) {
    attempt += 1;
    const startedAt = now();
    logEvent(logger, 'info', {
      status: 'starting',
      project: checked.project,
      attempt,
      routeCount: checked.routes.length,
    });
    const child = spawnImpl('ssh', buildSshArgs(checked), { stdio: 'inherit', shell: false });
    const result = await waitForChild(child, signalSource, options);
    const duration = Math.max(0, now() - startedAt);
    if (result.shutdown) {
      logEvent(logger, 'info', {
        status: 'stopped',
        project: checked.project,
        attempt,
        durationMs: duration,
        ...exitFields(result),
      });
      return 0;
    }

    consecutiveFailures = duration >= stableMs ? 1 : consecutiveFailures + 1;
    if (consecutiveFailures >= maxAttempts) {
      logEvent(logger, 'error', {
        status: 'failed',
        project: checked.project,
        attempt,
        consecutiveFailures,
        durationMs: duration,
        ...exitFields(result),
      });
      throw new Error(`ssh exited ${describeExit(result)}; exhausted ${maxAttempts} consecutive attempts`);
    }
    const delay = backoffDelay(consecutiveFailures);
    logEvent(logger, 'warn', {
      status: 'retrying',
      project: checked.project,
      attempt,
      consecutiveFailures,
      durationMs: duration,
      delayMs: delay,
      ...exitFields(result),
    });
    await sleepImpl(delay);
  }
  return 1;
}

async function waitForChild(child, signalSource, options) {
  const setTimer = options.setTimeoutImpl ?? setTimeout;
  const clearTimer = options.clearTimeoutImpl ?? clearTimeout;
  const stopTimeoutMs = options.stopTimeoutMs ?? 5000;
  return new Promise((resolve) => {
    let shutdownSignal = null;
    let forceTimer = null;
    let settled = false;

    const cleanup = () => {
      signalSource.off('SIGINT', onSigint);
      signalSource.off('SIGTERM', onSigterm);
      if (forceTimer !== null) clearTimer(forceTimer);
    };
    const finish = (result) => {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(result);
    };
    const forward = (signal) => {
      if (shutdownSignal) return;
      shutdownSignal = signal;
      child.kill(signal);
      forceTimer = setTimer(() => child.kill('SIGKILL'), stopTimeoutMs);
      forceTimer.unref?.();
    };
    const onSigint = () => forward('SIGINT');
    const onSigterm = () => forward('SIGTERM');
    signalSource.on('SIGINT', onSigint);
    signalSource.on('SIGTERM', onSigterm);
    child.once('error', (error) => finish({ error, shutdown: Boolean(shutdownSignal) }));
    child.once('exit', (code, signal) => finish({ code, signal, shutdown: Boolean(shutdownSignal) }));
  });
}

function describeExit(result) {
  if (result.error) return `with start error: ${result.error.message}`;
  if (result.signal) return `from signal ${result.signal}`;
  return `with code ${result.code ?? 'unknown'}`;
}

function exitFields(result) {
  if (result.error) return { exitError: result.error.message };
  if (result.signal) return { exitSignal: result.signal };
  return { exitCode: result.code ?? null };
}

function logEvent(logger, level, fields) {
  logger[level](JSON.stringify({
    module: 'public_access',
    component: 'tunnel_runner',
    operation: 'reverse_ssh_tunnel',
    ...fields,
  }));
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const [, , manifestPath, flag] = process.argv;
  if (!manifestPath || (flag !== undefined && flag !== '--check')) {
    throw new Error('usage: tunnel-runner.mjs MANIFEST.json [--check]');
  }
  const manifest = await loadManifest(manifestPath);
  if (flag === '--check') {
    const forwards = manifest.routes.map((route) => ({
      name: route.name,
      remote: `127.0.0.1:${route.remotePort}`,
      local: `127.0.0.1:${route.localPort}`,
      kind: route.kind,
    }));
    console.log(JSON.stringify({
      project: manifest.project,
      relay: `${manifest.ssh.user}@${manifest.ssh.host}:${manifest.ssh.port}`,
      strictHostKeyChecking: true,
      userSshConfigDisabled: true,
      keepalive: { intervalSeconds: 15, countMax: 2 },
      forwards,
    }, null, 2));
    return;
  }
  process.exitCode = await superviseTunnel(manifest);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((error) => {
    logEvent(console, 'error', { status: 'failed', exitError: error.message });
    process.exitCode = 1;
  });
}
