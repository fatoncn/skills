# Manifest contract

Use one JSON manifest per local project and public domain. The renderer rejects unknown fields so misspellings cannot silently weaken a setting.

## Top-level fields

| Field | Meaning |
| --- | --- |
| `version` | Must be `1`. |
| `project` | Lowercase slug used in filenames and supervisor identifiers. |
| `domain` | Public FQDN served by Nginx. |
| `access.mode` | `application`, `gateway`, or `public`. This is a declared security decision. |
| `ssh` | Existing relay connection and local known-host file. |
| `tls.email` | ACME contact used in the generated operator steps. |
| `routes` | One or more application routes for the same domain. |

`ssh.knownHostsFile` is required and must be an absolute path to a pre-populated file. `ssh.identityFile` is an optional absolute path. Paths are references only; the renderer never reads either file and never copies key material.

The runner starts `ssh` with `-F /dev/null` and explicit argv options, so a user's `~/.ssh/config` cannot inject forwards, a `ProxyCommand`, or weaker host-key policy. The generated standalone `ssh_config` is for reviewed operator connections and is likewise used only with an explicit `ssh -F`.

## Route fields

| Field | Meaning |
| --- | --- |
| `name` | Unique lowercase route slug. |
| `publicPath` | Absolute prefix ending in `/`, such as `/`, `/events/`, or `/socket/`. |
| `kind` | `http`, `sse`, or `websocket`. |
| `localHost` | Must be `127.0.0.1`; deliberately fixed to the local machine. |
| `localPort` | Existing local application TCP port. |
| `remotePort` | Unique unused relay loopback port. |
| `healthPath` | Optional local path used in the verification checklist. |

Route prefixes cannot overlap. A root route may coexist with more specific routes because Nginx chooses the longest prefix. Any two non-root prefixes where one contains the other are rejected to avoid surprising ownership.

Protocol handling is intentionally different:

- `http`: ordinary HTTP/1.1 proxying with hop-by-hop connection state cleared.
- `sse`: clears `Connection`, disables response buffering/cache, and uses a long read timeout.
- `websocket`: forwards `Upgrade` and sets `Connection "upgrade"`; it does not use the SSE connection settings.

Only a same-domain path router is supported. Multiple domains, wildcard certificates, raw TCP services, UDP, databases, and cross-host local targets are outside this version's contract.

## Access modes

- `application`: every exposed route already enforces suitable authentication and authorization in the application.
- `gateway`: the final Nginx config includes a required local file named `public-access-gateway.conf`; the operator must provide and validate that gateway policy before enabling the site.
- `public`: the operator explicitly accepts unauthenticated Internet access.

The manifest records a choice; it does not prove the chosen control is correctly implemented. Verify the real unauthorized and authorized behavior after deployment.
