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
