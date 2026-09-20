# Apply and operate generated public access

## Contents

- Safety boundary
- Render and review
- Relay preflight
- TLS bootstrap without deadlock
- Tunnel supervision
- Verification and rollback
- Initial relay checklist

## Safety boundary

Rendering is local and reversible. DNS changes, remote file installation, certificate issuance, reloads, account changes, and process starts mutate external state. Perform only the subset already authorized by the user. Never print or copy private-key contents.

## Render and review

Render into a new empty directory. Compare remote ports, domain, public paths, SSH user, and access mode with the intended project. Check other projects manually because this skill has no global registry or allocator.

The output contains:

- `nginx-bootstrap.conf`: port 80 ACME challenge and HTTPS redirect; no certificate references.
- `nginx-site.conf`: final TLS proxy configuration.
- `ssh_config`: a dedicated strict client stanza.
- `public-access-<project>.service`: Linux user systemd unit.
- `com.public-access.<project>.plist`: macOS LaunchAgent.
- `verification.md`: commands and expected evidence, with no automatic execution.

Supervisor artifacts contain absolute paths to the current Node executable, installed skill runner, rendered manifest, and output directory. Keep that output directory in its final location. Re-render and reinstall the unit after moving the skill/output or upgrading/removing that Node installation.

## Relay preflight

Before installing anything, establish these facts with read-only checks:

1. DNS for the domain resolves to the intended relay.
2. TCP 80 and 443 reach that relay.
3. The dedicated SSH account can authenticate with batch mode and the configured known-host file.
4. Every chosen remote port is unused and will bind only to `127.0.0.1`.
5. Nginx has no conflicting `server_name` or path ownership.
6. The SSH server permits TCP forwarding without enabling public gateway ports.

Do not rewrite a shared host's global sshd, firewall, journald, or fail2ban configuration as part of ordinary project onboarding.

## TLS bootstrap without deadlock

Do not enable the final config before its certificate files exist; Nginx will fail validation and ACME cannot reach the challenge path.

1. Install `nginx-bootstrap.conf` as the project's enabled site.
2. Create `/var/www/acme-challenge` with ownership suitable for the ACME client and Nginx.
3. Run `nginx -t`, then reload only Nginx.
4. Request a certificate with an HTTP-01 webroot flow, for example:

   ```bash
   sudo certbot certonly --webroot -w /var/www/acme-challenge \
     -d APP.EXAMPLE.COM -m OPERATOR@EXAMPLE.COM --agree-tos --no-eff-email
   ```

5. Confirm the full chain and private key exist at the paths shown in `nginx-site.conf`.
6. Install the final config, run `nginx -t`, and reload Nginx.
7. Configure a renewal deploy hook that runs `nginx -t` and reloads Nginx only after successful renewal. Exercise a dry-run renewal and record the result.

## Tunnel supervision

Use exactly one generated supervisor for the local operating system. The runner retries consecutive SSH failures with bounded exponential delays and exits after the configured limit; launchd/systemd may then restart the runner according to its own policy. Supervise the local application independently: a healthy tunnel cannot serve an application process that has exited.

For macOS, copy the plist to the user's `~/Library/LaunchAgents`, then use `launchctl bootstrap`/`kickstart` for that label. A LaunchAgent belongs to the logged-in user session, and normal laptop sleep interrupts network reachability; use a host with an appropriate awake/power policy when continuous access is required. For Linux, copy the unit to `~/.config/systemd/user`, run `systemctl --user daemon-reload`, enable, and start only that unit. A user service normally stops with the login session unless user lingering is explicitly enabled and accepted by the operator.

After a start or restart, check twice: immediately and again after at least two keepalive intervals. Confirm PID identity, fresh logs, local listener, relay loopback listeners, and application HTTP behavior. `nohup` returning a PID or a supervisor command returning zero is not residency proof.

## Verification and rollback

Follow generated `verification.md` from local application outward. Its relay probe sets `ClearAllForwardings=yes`; this prevents the inspection connection from requesting the configured reverse forwards or masking the runner's real state. Treat these outcomes precisely:

- DNS/TLS success plus HTTP `502`: edge and Nginx are reachable; the upstream tunnel or local application is not healthy.
- Relay loopback port absent: tunnel is down or the forward failed.
- Relay port present but Nginx `502`: inspect route/port alignment and Nginx connection errors.
- Root HTTP works while SSE/WS fails: perform protocol-specific checks; a normal GET does not prove streaming or upgrade behavior.

Keep a timestamped backup of every replaced relay file. Roll back by restoring only this project's prior site config and local supervisor unit, validating syntax, and reloading/restarting those targets. Re-run the same layered verification after rollback.

## Initial relay checklist

Building a new relay is a separate task with explicit authorization. Plan and review, at minimum: OS/user choice, dedicated non-root SSH account and public key, SSH forwarding policy, loopback-only gateway behavior, DNS, ingress for 22/80/443, Nginx, certbot, patching, logs/retention, backups, monitoring, and recovery access. Do not turn this checklist into an unreviewed all-host provisioner.
