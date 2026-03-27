FROM alpine:3.18

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    jq \
    curl \
    openssh-client \
    docker-cli \
    rsync \
    dnsmasq \
    bind-tools \
    coreutils \
    grep \
    sed

# Create supervisor user
RUN addgroup -g 1000 supervisor && \
    adduser -D -u 1000 -G supervisor supervisor

# Setup working directory
WORKDIR /app
RUN chown -R supervisor:supervisor /app

# Copy supervisor scripts
COPY bin/ /app/bin/
COPY data/ /app/data/
COPY app.js /app/

# Make scripts executable
RUN chmod +x /app/bin/*.sh && \
    chmod +x /app/app.js

# Create volume mounts for state and data
VOLUME ["/app/data", "/var/run/docker.sock"]

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD curl -f http://localhost:3000/health || exit 1

# Run supervisor
USER supervisor
CMD ["/app/bin/supervisor.sh", "daemon"]

# Metadata
LABEL maintainer="C.O.R.E Project" \
      description="Distributed multi-node service supervisor with failover and recovery" \
      version="1.0.0"
