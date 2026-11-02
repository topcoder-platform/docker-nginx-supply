# Local source-mounted development image; deployment uses ECSDockerfile.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

RUN apk upgrade --no-cache \
    && apk add --no-cache ca-certificates nginx bash perl \
    && adduser -S -D -H -u 10001 -G www-data www-data \
    && rm -f /etc/nginx/nginx.conf \
    && mkdir -p /usr/local/nginx/cache /var/log/nginx/logs /home/apps/nginx/app /usr/share/nginx/html
COPY healthcheck.html /home/apps/nginx/app/healthcheck.html
WORKDIR /data/nginx
CMD ["./run"]
