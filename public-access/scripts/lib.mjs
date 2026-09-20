import path from 'node:path';

const SLUG = /^[a-z][a-z0-9-]{0,39}$/;
const USER = /^[a-z_][a-z0-9_-]{0,31}$/;
const ROUTE_PATH = /^\/(?:[A-Za-z0-9._~-]+\/)*$/;
const HEALTH_PATH = /^\/(?:[A-Za-z0-9._~\/-]*)$/;
const CONTROL = /[\u0000-\u001f\u007f]/;
const ACCESS_MODES = new Set(['application', 'gateway', 'public']);
const ROUTE_KINDS = new Set(['http', 'sse', 'websocket']);

export function validateManifest(input) {
  assertObject(input, 'manifest');
  exactKeys(input, ['version', 'project', 'domain', 'access', 'ssh', 'tls', 'routes'], 'manifest');
  if (input.version !== 1) fail('version must be 1');
  const project = requireSlug(input.project, 'project');
  const domain = requireFqdn(input.domain, 'domain');

  assertObject(input.access, 'access');
  exactKeys(input.access, ['mode'], 'access');
  if (!ACCESS_MODES.has(input.access.mode)) fail('access.mode must be application, gateway, or public');

  assertObject(input.ssh, 'ssh');
  exactKeys(input.ssh, ['host', 'user', 'port', 'knownHostsFile', 'identityFile'], 'ssh');
  const ssh = {
    host: requireHost(input.ssh.host, 'ssh.host'),
    user: requirePattern(input.ssh.user, USER, 'ssh.user'),
    port: requirePort(input.ssh.port, 'ssh.port'),
    knownHostsFile: requireAbsolutePath(input.ssh.knownHostsFile, 'ssh.knownHostsFile'),
  };
  if (input.ssh.identityFile !== undefined) {
    ssh.identityFile = requireAbsolutePath(input.ssh.identityFile, 'ssh.identityFile');
  }

  assertObject(input.tls, 'tls');
  exactKeys(input.tls, ['email'], 'tls');
  const email = requireString(input.tls.email, 'tls.email');
  if (!/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+$/.test(email) || email.length > 254) {
    fail('tls.email must be a valid email address');
  }

  if (!Array.isArray(input.routes) || input.routes.length < 1 || input.routes.length > 32) {
    fail('routes must contain 1 to 32 entries');
  }
  const names = new Set();
  const remotePorts = new Set();
  const publicPaths = new Set();
  const routes = input.routes.map((route, index) => {
    const where = `routes[${index}]`;
    assertObject(route, where);
    exactKeys(route, ['name', 'publicPath', 'kind', 'localHost', 'localPort', 'remotePort', 'healthPath'], where);
    const name = requireSlug(route.name, `${where}.name`);
    if (names.has(name)) fail(`${where}.name must be unique`);
    names.add(name);
    const publicPath = requireRoutePath(route.publicPath, `${where}.publicPath`);
    if (publicPaths.has(publicPath)) fail(`${where}.publicPath must be unique`);
    publicPaths.add(publicPath);
    if (!ROUTE_KINDS.has(route.kind)) fail(`${where}.kind must be http, sse, or websocket`);
    if (route.localHost !== '127.0.0.1') fail(`${where}.localHost must be 127.0.0.1`);
    const localPort = requirePort(route.localPort, `${where}.localPort`);
    const remotePort = requirePort(route.remotePort, `${where}.remotePort`);
    if (remotePorts.has(remotePort)) fail(`${where}.remotePort must be unique`);
    remotePorts.add(remotePort);
    let healthPath;
    if (route.healthPath !== undefined) healthPath = requireHealthPath(route.healthPath, `${where}.healthPath`);
    return { name, publicPath, kind: route.kind, localHost: '127.0.0.1', localPort, remotePort, ...(healthPath ? { healthPath } : {}) };
  });

  const nonRoot = routes.filter((route) => route.publicPath !== '/');
  for (let i = 0; i < nonRoot.length; i += 1) {
    for (let j = i + 1; j < nonRoot.length; j += 1) {
      const a = nonRoot[i].publicPath;
      const b = nonRoot[j].publicPath;
      if (a.startsWith(b) || b.startsWith(a)) fail(`route prefixes overlap: ${a} and ${b}`);
    }
  }

  return {
    version: 1,
    project,
    domain,
    access: { mode: input.access.mode },
    ssh,
    tls: { email },
    routes,
  };
}

export function buildSshArgs(manifest) {
  const checked = validateManifest(manifest);
  const args = [
    '-F', '/dev/null',
    '-N', '-T',
    '-o', 'BatchMode=yes',
    '-o', 'ConnectTimeout=10',
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=2',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', `UserKnownHostsFile=${checked.ssh.knownHostsFile}`,
    '-p', String(checked.ssh.port),
  ];
  if (checked.ssh.identityFile) {
    args.push('-o', 'IdentitiesOnly=yes', '-i', checked.ssh.identityFile);
  }
  for (const route of checked.routes) {
    args.push('-R', `127.0.0.1:${route.remotePort}:127.0.0.1:${route.localPort}`);
  }
  args.push(`${checked.ssh.user}@${checked.ssh.host}`);
  return args;
}

export function backoffDelay(attempt, baseMs = 1000, capMs = 30000) {
  if (!Number.isInteger(attempt) || attempt < 1) throw new Error('attempt must be a positive integer');
  return Math.min(capMs, baseMs * (2 ** (attempt - 1)));
}

export function renderLocations(manifest) {
  const checked = validateManifest(manifest);
  return [...checked.routes]
    .sort((a, b) => b.publicPath.length - a.publicPath.length)
    .map((route) => renderLocation(route, checked.access.mode))
    .join('\n\n');
}

export function fillTemplate(template, values) {
  let result = template;
  for (const [key, value] of Object.entries(values)) {
    result = result.replaceAll(`@@${key}@@`, String(value));
  }
  const remaining = result.match(/@@[A-Z0-9_]+@@/g);
  if (remaining) throw new Error(`unfilled template token: ${remaining[0]}`);
  return result;
}

export function sshConfigValue(value) {
  const text = requireString(value, 'ssh config value');
  if (CONTROL.test(text)) fail('ssh config value contains control characters');
  return `"${text.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

export function systemdArg(value) {
  const text = requireString(value, 'systemd argument');
  if (CONTROL.test(text)) fail('systemd argument contains control characters');
  return `"${text.replaceAll('%', '%%').replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"`;
}

export function xmlText(value) {
  const text = requireString(value, 'XML value');
  if (CONTROL.test(text)) fail('XML value contains control characters');
  return text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
}

function renderLocation(route, accessMode) {
  const access = accessMode === 'gateway'
    ? '        include /etc/nginx/snippets/public-access-gateway.conf;\n'
    : `        # Access mode: ${accessMode}; verify the declared control independently.\n`;
  const common = [
    `    location ^~ ${route.publicPath} {`,
    access.trimEnd(),
    `        proxy_pass http://127.0.0.1:${route.remotePort};`,
    '        proxy_http_version 1.1;',
    '        proxy_set_header Host $host;',
    '        proxy_set_header X-Real-IP $remote_addr;',
    '        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;',
    '        proxy_set_header X-Forwarded-Proto $scheme;',
  ];
  if (route.kind === 'websocket') {
    common.push(
      '        proxy_set_header Upgrade $http_upgrade;',
      '        proxy_set_header Connection "upgrade";',
      '        proxy_read_timeout 3600s;',
      '        proxy_send_timeout 3600s;',
    );
  } else {
    common.push('        proxy_set_header Connection "";');
    if (route.kind === 'sse') {
      common.push(
        '        proxy_buffering off;',
        '        proxy_cache off;',
        '        add_header X-Accel-Buffering no always;',
        '        proxy_read_timeout 3600s;',
        '        proxy_send_timeout 3600s;',
      );
    } else {
      common.push('        proxy_read_timeout 60s;');
    }
  }
  common.push('    }');
  return common.join('\n');
}

function requirePort(value, label) {
  if (!Number.isInteger(value) || value < 1 || value > 65535) fail(`${label} must be an integer from 1 to 65535`);
  return value;
}

function requireSlug(value, label) {
  return requirePattern(value, SLUG, label);
}

function requirePattern(value, pattern, label) {
  const text = requireString(value, label);
  if (!pattern.test(text) || text.includes('--')) fail(`${label} has an invalid format`);
  return text;
}

function requireFqdn(value, label) {
  const text = requireString(value, label);
  if (text !== text.toLowerCase() || text.length > 253 || text.endsWith('.')) fail(`${label} must be a lowercase FQDN`);
  const labels = text.split('.');
  if (labels.length < 2 || labels.some((part) => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(part))) {
    fail(`${label} must be a lowercase FQDN`);
  }
  return text;
}

function requireHost(value, label) {
  const text = requireString(value, label);
  if (/^\d{1,3}(?:\.\d{1,3}){3}$/.test(text)) {
    if (text.split('.').every((part) => Number(part) <= 255)) return text;
    fail(`${label} has an invalid IPv4 address`);
  }
  return requireFqdn(text, label);
}

function requireAbsolutePath(value, label) {
  const text = requireString(value, label);
  if (!path.isAbsolute(text) || CONTROL.test(text) || text.length > 4096) fail(`${label} must be a safe absolute path`);
  return text;
}

function requireRoutePath(value, label) {
  const text = requireString(value, label);
  if (!ROUTE_PATH.test(text) || unsafeSegments(text)) fail(`${label} must be a safe absolute prefix ending in /`);
  return text;
}

function requireHealthPath(value, label) {
  const text = requireString(value, label);
  if (!HEALTH_PATH.test(text) || text.includes('//') || unsafeSegments(text)) fail(`${label} must be a safe absolute URL path`);
  return text;
}

function unsafeSegments(value) {
  return value.split('/').some((segment) => segment === '.' || segment === '..');
}

function requireString(value, label) {
  if (typeof value !== 'string' || value.length === 0 || CONTROL.test(value)) fail(`${label} must be a non-empty string without control characters`);
  return value;
}

function assertObject(value, label) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) fail(`${label} must be an object`);
}

function exactKeys(value, allowed, label) {
  const extras = Object.keys(value).filter((key) => !allowed.includes(key));
  if (extras.length) fail(`${label} contains unknown field: ${extras[0]}`);
}

function fail(message) {
  throw new Error(message);
}
