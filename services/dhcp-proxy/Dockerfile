FROM debian:trixie-slim@sha256:a617c1cdde36a7e0194b2f07dff669e1753c03c3205356b94f9f350b0f9a57d1

RUN apt-get update && apt-get install -y --no-install-recommends \
    dnsmasq \
    gettext \
    && rm -rf /var/lib/apt/lists/*

COPY dnsmasq.conf.template /etc/dnsmasq.conf.template
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 67/udp

ENTRYPOINT ["/entrypoint.sh"]
