FROM debian:13-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    gnupg \
    curl \
    ca-certificates \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /etc/apt/trusted.gpg.d/nginx.gpg \
    && echo "deb http://nginx.org/packages/mainline/debian/ trixie nginx" > /etc/apt/sources.list.d/nginx.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    openssl \
    gettext-base \
    locales \
    && echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN mkdir -p \
    /etc/nginx/ssl/ca \
    /etc/nginx/ssl/certs \
    /var/cache/nginx/lancache \
    /var/cache/nginx/tmp

COPY nginx.conf /etc/nginx/nginx.conf.template
COPY conf.d/ /etc/nginx/conf.d/
COPY proxy-params.conf /etc/nginx/proxy-params.conf
COPY cdn-ssl-domains.txt /etc/nginx/cdn-ssl-domains.txt
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/etc/nginx/ssl", "/var/cache/nginx/lancache"]

EXPOSE 80 443

ENTRYPOINT ["/entrypoint.sh"]
