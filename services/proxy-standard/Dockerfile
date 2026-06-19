FROM debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg \
    curl \
    ca-certificates \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/nginx.gpg \
    && echo "deb http://nginx.org/packages/mainline/debian/ trixie nginx" > /etc/apt/sources.list.d/nginx.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    nginx-module-stream \
    gettext-base \
    && rm -rf /var/lib/apt/lists/*

COPY nginx.conf /etc/nginx/nginx.conf.template
COPY conf.d/ /etc/nginx/conf.d/
COPY proxy-params.conf /etc/nginx/proxy-params.conf
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/var/cache/nginx/lancache"]

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
