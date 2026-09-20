# Source lineage

This skill generalizes operational patterns from a private business automation repository without publishing its environment-specific hostnames, addresses, credentials, or paths.

Source anchors at the time of extraction:

- Commit `34a2306` (`feat: support multi-service public tunnel`): `kosbling-auto/scripts/public-tunnel.mjs` and its tests supplied the multi-forward, keepalive, forward-failure, and signal-propagation baseline.
- Commit `7c6f89c` (`feat(public-host): add repeatable host provisioning`): `public-host/nginx/`, `public-host/watchdog/`, `public-host/apply.sh`, and `public-host/verify.sh` supplied the TLS bootstrap, loopback proxy, observation, backup, and layered verification lessons.

Deliberate changes in this public package include strict known-host checking by default, no remote stale-process cleanup, separate SSE and WebSocket proxy behavior, pure local rendering, project-specific supervisor units, and no whole-host provisioner.
