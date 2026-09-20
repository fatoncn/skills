Host public-access-@@PROJECT@@
    HostName @@SSH_HOST@@
    User @@SSH_USER@@
    Port @@SSH_PORT@@
    BatchMode yes
    ExitOnForwardFailure yes
    ServerAliveInterval 15
    ServerAliveCountMax 2
    StrictHostKeyChecking yes
    UserKnownHostsFile @@KNOWN_HOSTS_FILE@@
@@IDENTITY_LINE@@
@@REMOTE_FORWARD_LINES@@
