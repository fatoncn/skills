server {
    listen 80;
    listen [::]:80;
    server_name @@DOMAIN@@;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/acme-challenge;
        default_type text/plain;
        try_files $uri =404;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name @@DOMAIN@@;

    ssl_certificate /etc/letsencrypt/live/@@DOMAIN@@/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/@@DOMAIN@@/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

@@LOCATIONS@@
}
