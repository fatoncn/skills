[Unit]
Description=Public access reverse tunnel for @@PROJECT@@
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=@@WORKING_DIRECTORY@@
ExecStart=@@NODE@@ @@RUNNER@@ @@MANIFEST@@
Restart=on-failure
RestartSec=30
TimeoutStopSec=10

[Install]
WantedBy=default.target
