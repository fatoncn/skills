# Layered troubleshooting

Collect evidence in this order. A failed or unavailable query leaves that layer unchecked; it does not prove absence.

| Layer | Evidence | Interpretation |
| --- | --- | --- |
| DNS | A/AAAA answer and intended relay address | Wrong answer stops the path before the relay. |
| TCP/TLS | 443 connect, SNI hostname, chain, expiry | Separates network/certificate faults from HTTP. |
| Nginx | `nginx -t`, selected site, access/error timing | Confirms route selection and upstream connect behavior. |
| Relay forward | listener address and port | Must be `127.0.0.1:PORT`, never a wildcard address. |
| SSH client | runner PID, restart count, stderr, forward-failure exit | Distinguishes auth/host-key/collision/network failures. |
| Local app | PID/cwd, loopback listener, direct health request | Confirms the tunnel has a usable destination. |
| Protocol | SSE receives events; WS returns 101 and exchanges a frame | A normal HTTP 200 cannot prove either protocol. |

## Common signatures

- `Host key verification failed`: the dedicated known-host file is missing the expected current key. Verify the fingerprint through an independent trusted channel; do not switch to `accept-new` or `no` as a shortcut.
- `remote port forwarding failed`: remote-port collision or server forwarding policy. Inspect ownership; do not kill an unknown `sshd` process automatically.
- Fast restart loop: inspect the first runner/SSH error and supervisor restart count. Fix the invariant instead of increasing retry frequency.
- Public `502`: Nginx is reachable, but this is not success. Check Nginx's exact upstream, relay listener, tunnel, then local app.
- SSE connects but events arrive in bursts: confirm the route is rendered as `sse` and response buffering is off.
- WebSocket handshake fails: confirm the route is `websocket`, the client sends `Upgrade`, and Nginx forwards both `Upgrade` and `Connection: upgrade`.
- Certificate renewal succeeds but old certificate remains served: inspect the deploy hook, `nginx -t`, reload result, active worker config, and SNI response.
- Process start reported success but endpoint later disappears: recheck PID, log mtime, restart count, both listeners, and HTTP after at least 30 seconds.

## Report format

Report three sections:

1. **Observed:** exact layer, command or log source, timestamp, and result.
2. **Inferred:** the narrow conclusion supported by those observations.
3. **Unchecked:** missing access, credentials, host state, or protocol checks.

Never describe static templates or an earlier deployment record as proof of current public availability.
