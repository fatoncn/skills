---
name: public-access
description: Expose a local HTTP application through an existing public relay using reverse SSH and Nginx TLS, or diagnose that access path. Use for stable public domains, local web apps, SSE, WebSocket, reverse tunnels, Nginx proxy routes, TLS certificates, 502 errors, tunnel reconnects, and launchd or systemd supervision. Do not use to expose databases or to provision an entire public host automatically.
metadata:
  version: 1.0.0
---

# Public Access

IRON LAW: PUBLICLY EXPOSE ONLY THE SELECTED APPLICATION ROUTES; KEEP REMOTE FORWARDS ON LOOPBACK AND NEVER TURN A DATABASE OR ADMIN PORT INTO A PUBLIC ENTRYPOINT.

Use an existing relay host with OpenSSH and Nginx. Keep the application on the local machine. The relay terminates TLS and proxies only to reverse SSH ports bound to `127.0.0.1`.

## Workflow

Copy this checklist and complete the applicable items:

- [ ] 1. Inspect the project and relay assumptions ⚠️ REQUIRED
  - [ ] Identify each local listener, public path, protocol (`http`, `sse`, or `websocket`), health path, and desired domain.
  - [ ] Confirm the relay already exists and supports a dedicated SSH account, loopback reverse forwards, Nginx, and TLS.
  - [ ] Ask: does every public route have an explicit access choice: application authentication, independent gateway control, or intentionally public?
  - [ ] Check project/domain/service names and local/remote ports against other projects. There is no global port registry.
- [ ] 2. Create a manifest ⛔ BLOCKING
  - [ ] Copy `assets/manifest.example.json` and replace every example value.
  - [ ] Read [references/manifest.md](references/manifest.md) when adding multiple routes or choosing HTTP/SSE/WebSocket behavior.
- [ ] 3. Render locally ⚠️ REQUIRED
  - [ ] Run `node scripts/render.mjs manifest.json OUTPUT_DIRECTORY`.
  - [ ] Review the generated summary, Nginx bootstrap/final configs, SSH config, supervisor units, and verification checklist.
  - [ ] Resolve every port/path/name collision before any external change.
- [ ] 4. Apply selected artifacts (only within the user's authorized scope)
  - [ ] Read [references/operations.md](references/operations.md) before changing the relay, DNS, certificates, or a local supervisor.
  - [ ] Bootstrap ACME with the HTTP-only Nginx config; obtain the certificate; then validate and enable the final TLS config.
  - [ ] Install one dedicated local supervisor unit for this project and start `scripts/tunnel-runner.mjs` separately from render.
  - [ ] Avoid whole-host sshd/firewall changes on an existing relay. Treat initial host creation as a separate, explicitly authorized task.
- [ ] 5. Verify all layers ⚠️ REQUIRED
  - [ ] Verify local process/PID, loopback listener, and health response.
  - [ ] Verify the tunnel runner remains alive after an immediate and delayed check.
  - [ ] Verify each relay port listens only on loopback and Nginx config passes syntax validation.
  - [ ] Verify DNS, TCP 443, TLS hostname/expiry, and each public route. Exercise a real SSE stream or WebSocket upgrade where configured.
- [ ] 6. Diagnose failures (conditional)
  - [ ] Read [references/troubleshooting.md](references/troubleshooting.md).
  - [ ] Collect evidence from public edge to local process; report observed facts, inferences, and unchecked layers separately.

## Commands

```bash
# Pure local generation: no network and no process starts.
node scripts/render.mjs path/to/manifest.json path/to/new-output-directory

# Validate and print SSH arguments without starting ssh.
node scripts/tunnel-runner.mjs path/to/manifest.json --check

# Start the supervised tunnel. The generated launchd/systemd templates call this.
node scripts/tunnel-runner.mjs path/to/manifest.json
```

The runner uses `ExitOnForwardFailure=yes`, `ServerAliveInterval=15`, `ServerAliveCountMax=2`, strict known-host checking, loopback-only remote binds, bounded exponential retry, and signal forwarding. It never kills remote `sshd` processes or cleans stale listeners automatically.

## Boundaries

- One manifest represents one project and one domain. It may contain many HTTP/SSE/WebSocket path routes.
- The generated gateway-control Nginx hook is an integration point, not an authentication implementation. Do not claim that it authenticates users until a real gateway include has been installed and tested.
- Rendering never connects to the relay, modifies DNS, requests certificates, or starts a process.
- Prefer an existing relay. For a new relay, separately authorize account creation, package installation, DNS, firewall, sshd, Nginx, and ACME changes; apply least privilege and review each plan.
- Do not weaken host-key checking, bind reverse forwards to `0.0.0.0`, run a blind stale-process cleanup, or accept `502` as end-to-end success.

## Delivery checks

- [ ] Manifest contains no secret values and selects one access mode explicitly.
- [ ] Every remote forward renders as `127.0.0.1:PORT`.
- [ ] SSE routes disable buffering; WebSocket routes set `Upgrade` and `Connection: upgrade`.
- [ ] Bootstrap Nginx config does not reference a missing certificate.
- [ ] Final Nginx config is enabled only after certificate files exist.
- [ ] Generated units affect only this project's tunnel.
- [ ] Verification includes a delayed process/listener check; a launch command returning zero is insufficient evidence.
