# Perforce Game Server — Production
# SSL enabled, security level 3, no default credentials.
# Built by ButterStack — https://butterstack.com

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install base utilities + openssl for certificate generation
RUN apt-get update \
 && apt-get -y install curl gosu software-properties-common openssl \
 && rm -rf /var/lib/apt/lists/*

# Add Perforce official APT repository
RUN curl -fsSL https://package.perforce.com/perforce.pubkey \
      | gpg --dearmor -o /etc/apt/trusted.gpg.d/perforce.gpg \
 && apt-add-repository -y "deb http://package.perforce.com/apt/ubuntu noble release" \
 && rm -rf /var/lib/apt/lists/*

# Install helix-p4d (includes p4d, p4 CLI, p4dctl)
RUN apt-get update \
 && apt-get -y install helix-p4d \
 && rm -rf /var/lib/apt/lists/*

# Environment defaults (prod-safe: no default password)
ENV P4PORT=1666
ENV P4USER=super
ENV P4ROOT=/data/p4depot/root
ENV P4LOG=/data/p4depot/logs/log
ENV P4REST_PORT=8090
ENV ENGINE=unreal
ENV CASE_INSENSITIVE=1
ENV UNICODE=1
ENV SSL=1
ENV P4SSLDIR=/data/ssl

# Copy shared typemaps and setup script
COPY --from=shared typemaps /shared/typemaps
COPY --from=shared setup-typemap.sh /usr/local/bin/setup-typemap.sh
RUN chmod +x /usr/local/bin/setup-typemap.sh

# Copy entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# p4d on 1666 (ssl), REST API on 8090
EXPOSE 1666 8090

HEALTHCHECK --interval=30s --timeout=10s --start-period=45s --retries=5 \
    CMD p4 -p localhost:1666 info || p4 -p ssl:localhost:1666 trust -y > /dev/null 2>&1 && p4 -p ssl:localhost:1666 info

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
