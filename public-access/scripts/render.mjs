#!/usr/bin/env node
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import {
  fillTemplate,
  renderLocations,
  sshConfigValue,
  systemdExecArg,
  systemdUnitString,
  validateManifest,
  xmlText,
} from './lib.mjs';

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url));
const skillDirectory = path.dirname(scriptDirectory);
const templateDirectory = path.join(skillDirectory, 'assets', 'templates');

export async function render(manifestPath, outputPath) {
  const manifestFile = path.resolve(manifestPath);
  const outputDirectory = path.resolve(outputPath);
  await requireNewDirectory(outputDirectory);

  let raw;
  try {
    raw = JSON.parse(await readFile(manifestFile, 'utf8'));
  } catch (error) {
    throw new Error(`cannot read manifest: ${error.message}`);
  }
  const manifest = validateManifest(raw);
  await mkdir(outputDirectory, { recursive: true });

  const templates = Object.fromEntries(await Promise.all(
    ['nginx-bootstrap.conf', 'nginx-site.conf', 'ssh_config', 'systemd.service', 'launchd.plist'].map(async (name) => [
      name,
      await readFile(path.join(templateDirectory, `${name}.tpl`), 'utf8'),
    ]),
  ));
  const renderedManifestPath = path.join(outputDirectory, 'manifest.json');
  const runnerPath = path.join(scriptDirectory, 'tunnel-runner.mjs');
  const nodePath = process.execPath;

  const files = {
    'manifest.json': `${JSON.stringify(manifest, null, 2)}\n`,
    'nginx-bootstrap.conf': fillTemplate(templates['nginx-bootstrap.conf'], { DOMAIN: manifest.domain }),
    'nginx-site.conf': fillTemplate(templates['nginx-site.conf'], {
      DOMAIN: manifest.domain,
      LOCATIONS: renderLocations(manifest),
    }),
    ssh_config: fillTemplate(templates.ssh_config, {
      PROJECT: manifest.project,
      SSH_HOST: manifest.ssh.host,
      SSH_USER: manifest.ssh.user,
      SSH_PORT: manifest.ssh.port,
      KNOWN_HOSTS_FILE: sshConfigValue(manifest.ssh.knownHostsFile),
      IDENTITY_LINE: manifest.ssh.identityFile ? `    IdentityFile ${sshConfigValue(manifest.ssh.identityFile)}` : '',
      REMOTE_FORWARD_LINES: manifest.routes.map((route) => `    RemoteForward 127.0.0.1:${route.remotePort} 127.0.0.1:${route.localPort}`).join('\n'),
    }),
    [`public-access-${manifest.project}.service`]: fillTemplate(templates['systemd.service'], {
      PROJECT: manifest.project,
      WORKING_DIRECTORY: systemdUnitString(outputDirectory),
      NODE: systemdExecArg(nodePath),
      RUNNER: systemdExecArg(runnerPath),
      MANIFEST: systemdExecArg(renderedManifestPath),
    }),
    [`com.public-access.${manifest.project}.plist`]: fillTemplate(templates['launchd.plist'], {
      PROJECT: manifest.project,
      NODE: xmlText(nodePath),
      RUNNER: xmlText(runnerPath),
      MANIFEST: xmlText(renderedManifestPath),
      STDOUT: xmlText(path.join(outputDirectory, 'tunnel.stdout.log')),
      STDERR: xmlText(path.join(outputDirectory, 'tunnel.stderr.log')),
    }),
    'verification.md': renderVerification(manifest, outputDirectory),
    'render-summary.json': `${JSON.stringify(renderSummary(manifest), null, 2)}\n`,
  };

  for (const [name, content] of Object.entries(files)) {
    await writeFile(path.join(outputDirectory, name), content, { encoding: 'utf8', mode: name === 'manifest.json' ? 0o600 : 0o644 });
  }
  return { manifest, outputDirectory, files: Object.keys(files) };
}

function renderSummary(manifest) {
  return {
    generatedOnly: true,
    networkAccessPerformed: false,
    processStarted: false,
    project: manifest.project,
    domain: manifest.domain,
    accessMode: manifest.access.mode,
    relay: `${manifest.ssh.user}@${manifest.ssh.host}:${manifest.ssh.port}`,
    userSshConfigDisabledByRunner: true,
    remoteBind: '127.0.0.1',
    routes: manifest.routes.map(({ name, publicPath, kind, localPort, remotePort }) => ({ name, publicPath, kind, localPort, remotePort })),
    operatorChecksStillRequired: ['DNS', 'remote port ownership', 'Nginx conflicts', 'access control', 'certificate', 'end-to-end protocol behavior'],
  };
}

function renderVerification(manifest, outputDirectory) {
  const lines = [
    '# Verification checklist',
    '',
    'These commands are a reviewable checklist. Rendering did not run them.',
    '',
    '## 1. Local application',
    '',
  ];
  for (const route of manifest.routes) {
    lines.push(`- ${route.name} (${route.kind}): confirm the owning PID/cwd and listener on 127.0.0.1:${route.localPort}.`);
    if (route.healthPath) lines.push(`  - \`curl --fail --show-error http://127.0.0.1:${route.localPort}${route.healthPath}\``);
  }
  lines.push(
    '',
    '## 2. Tunnel client',
    '',
    `- Check config without starting SSH: \`${shellQuote(process.execPath)} ${shellQuote(path.join(scriptDirectory, 'tunnel-runner.mjs'))} ${shellQuote(path.join(outputDirectory, 'manifest.json'))} --check\`.`,
    '- After supervisor start, check its PID/status/log immediately and after at least 30 seconds.',
    '- Confirm there is one runner for this project and no rapid restart loop.',
    '',
    '## 3. Relay',
    '',
    `- Probe without creating forwards: \`ssh -F ${shellQuote(path.join(outputDirectory, 'ssh_config'))} -o ClearAllForwardings=yes public-access-${manifest.project}\`.`,
  );
  for (const route of manifest.routes) {
    lines.push(`- Confirm ${route.name} listens exactly on relay loopback 127.0.0.1:${route.remotePort}, not 0.0.0.0 or [::].`);
  }
  lines.push(
    '- Validate the selected Nginx config with `nginx -t` before reload.',
    '',
    '## 4. Public edge',
    '',
    `- Confirm DNS and TLS/SNI for \`${manifest.domain}\`, including certificate expiry.`,
  );
  for (const route of manifest.routes) {
    const url = `https://${manifest.domain}${route.publicPath}`;
    if (route.kind === 'sse') lines.push(`- SSE ${route.name}: use \`curl -N ${url}\` and confirm events arrive without buffering.`);
    else if (route.kind === 'websocket') lines.push(`- WebSocket ${route.name}: use a WebSocket client, confirm HTTP 101, then exchange a frame at \`${url}\`.`);
    else lines.push(`- HTTP ${route.name}: request \`${url}\` and verify the expected authenticated or public response body.`);
  }
  lines.push(
    '',
    'A 502 proves the public edge reached Nginx but does not prove the tunnel or local app. Record observed, inferred, and unchecked layers separately.',
    '',
  );
  return lines.join('\n');
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

async function requireNewDirectory(directory) {
  try {
    await stat(directory);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  throw new Error(`output directory already exists: ${directory}`);
}

async function main() {
  const [, , manifestPath, outputPath] = process.argv;
  if (!manifestPath || !outputPath) throw new Error('usage: render.mjs MANIFEST.json NEW_OUTPUT_DIRECTORY');
  const result = await render(manifestPath, outputPath);
  console.log(JSON.stringify({ outputDirectory: result.outputDirectory, files: result.files }, null, 2));
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((error) => {
    console.error(`[public-access] ${error.message}`);
    process.exitCode = 1;
  });
}
