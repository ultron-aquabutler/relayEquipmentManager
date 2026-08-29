# Dockerfile — relayEquipmentManager (REM)
#
# Mirrors AQB-011 multi-stage pattern (AquaButler-Control-njsPC/Dockerfile):
#   - Balena-friendly base via balenalib templates (`%%BALENA_MACHINE_NAME%%`)
#   - Build-arg swappable to plain Debian for local dev / non-balena targets
#   - Native deps (i2c-bus, spi-device, onoff) built in a dedicated build stage
#   - Slim prod stage with udev + libatomic1 for native module init
#
# Build contexts:
#   balena push    -> uses default BASE_IMAGE=balenalib/%%BALENA_MACHINE_NAME%%-debian-node:20-bookworm
#   docker build . -> pass --build-arg BASE_IMAGE=node:20-bookworm-slim for local builds
#
# Runtime devices bound by balena.yml (NOT here):
#   /dev/gpiomem                - GPIO via onoff
#   /dev/i2c-1                  - I2C bus 1 (default on Raspberry Pi)
#   /dev/spidev0.0 / 0.1        - SPI bus 0 (Sequent HAT ADC, Atlas EZO flow)
#   /sys/bus/w1                 - 1-Wire (DS18B20 temp probes)

ARG BASE_IMAGE=balenalib/%%BALENA_MACHINE_NAME%%-debian-node:20-bookworm-build

# ===========================================================================
# Build stage — compile TypeScript + install prod-only deps
# ===========================================================================
FROM ${BASE_IMAGE} AS build

RUN install_packages \
    make \
    gcc \
    g++ \
    python3 \
    udev \
    tzdata \
    git

WORKDIR /app

# Leverage Docker layer caching: manifests first
COPY package*.json ./
COPY tsconfig.json ./

# Install all deps including dev for tsc
RUN npm ci

# Copy source
COPY . .

# Build TypeScript -> dist/
RUN npm run build

# Drop dev deps, keep prod-only node_modules
RUN npm prune --production

# ===========================================================================
# Prod stage — minimal runtime, non-root, persistent volumes
# ===========================================================================
FROM balenalib/%%BALENA_MACHINE_NAME%%-debian-node:20-bookworm AS prod

LABEL maintainer="ultron-aquabutler" \
      org.opencontainers.image.title="relay-equipment-manager" \
      org.opencontainers.image.description="Relay Equipment Manager for AquaButler CPE — GPIO/I2C/SPI/1-Wire relay and sensor control" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.source="https://github.com/ultron-aquabutler/AquaButler-Control-REM"

# Native module runtime requirements:
#   udev       - libudev for spi-device / i2c-bus device discovery
#   libatomic1 - required by onoff / spi-device native bindings
#   git        - device-config scripts fetch binding snapshots at runtime
#   python3    - some Sequent HAT helpers + balena host hooks
RUN install_packages \
        udev \
        libatomic1 \
        git \
        python3 \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

# balenaOS exposes the `node` user at uid 1000 / gid 1000 in the runtime image.
# Match that here so persistent volumes owned by the host's node user stay
# writable when the container starts.
WORKDIR /app

# Persistent storage locations — host-mounted via balena named volumes
# (declared in balena.yml). Create + chown so first boot writes don't fail.
RUN mkdir -p /app/data /app/logs /app/backups \
    && chown -R node:node /app/data /app/logs /app/backups

# Copy only the runtime artifacts from the build stage
COPY --chown=node:node --from=build /app/package*.json ./
COPY --chown=node:node --from=build /app/node_modules ./node_modules
COPY --chown=node:node --from=build /app/dist ./dist
COPY --chown=node:node --from=build /app/defaultConfig.json ./defaultConfig.json
COPY --chown=node:node --from=build /app/defaultConfig.json ./config.json
COPY --chown=node:node --from=build /app/README.md ./README.md

USER node

# UDEV=1 triggers onoff / spi-device to use libudev for device discovery
# instead of hardcoded /dev paths. Required on balenaOS.
ENV UDEV=1 \
    NODE_ENV=production

# REM's HTTP API listens on 8080 by default (defaultConfig.json -> web.servers.http.port)
EXPOSE 8080

# Healthcheck: TCP socket to 8080 (REM's web UI / REST surface).
# Balena supervisor pings this on the device; compose-level healthcheck
# (balena.yml services.relayEquipmentManager.healthcheck) pings /devices on
# the same port.
HEALTHCHECK --interval=45s --timeout=6s --start-period=40s --retries=4 \
    CMD node -e "const n=require('net');const s=n.createConnection({host:'127.0.0.1',port:8080},()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1));setTimeout(()=>{s.destroy();process.exit(1)},5000);" || exit 1

ENTRYPOINT ["node", "dist/app.js"]
