### Build stage
FROM node:20-alpine AS build
LABEL maintainer="ultron-aquabutler"
LABEL org.opencontainers.image.title="relay-equipment-manager"
LABEL org.opencontainers.image.description="Relay Equipment Manager for AquaButler CPE — GPIO/I2C/SPI relay control"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.source="https://github.com/ultron-aquabutler/relayEquipmentManager"

# Install build toolchain only for native deps (i2c-bus, spi-device, onoff, etc.)
RUN apk add --no-cache make gcc g++ python3 linux-headers udev tzdata git

WORKDIR /app

# Leverage Docker layer caching: copy only manifests first
COPY package*.json ./

# Install all deps (including dev) for build
RUN npm ci

# Copy source
COPY . .

# Build Typescript
RUN npm run build

# Remove dev dependencies while keeping a clean node_modules with prod deps only
RUN npm prune --production

### Runtime stage
FROM node:20-alpine AS prod
LABEL org.opencontainers.image.title="relay-equipment-manager"
LABEL org.opencontainers.image.description="Relay Equipment Manager for AquaButler CPE — GPIO/I2C/SPI relay control"
LABEL org.opencontainers.image.licenses="AGPL-3.0-only"
LABEL org.opencontainers.image.source="https://github.com/ultron-aquabutler/relayEquipmentManager"
ENV NODE_ENV=production

# Use existing 'node' user from base image; just ensure work directory exists
WORKDIR /app
RUN mkdir -p /app/logs /app/data \
	&& chown -R node:node /app/logs /app/data || true

# Copy only the necessary runtime artifacts from build stage
COPY --chown=node:node --from=build /app/package*.json ./
COPY --chown=node:node --from=build /app/node_modules ./node_modules
COPY --chown=node:node --from=build /app/dist ./dist
COPY --chown=node:node --from=build /app/defaultConfig.json ./defaultConfig.json
COPY --chown=node:node --from=build /app/config.json ./config.json
COPY --chown=node:node --from=build /app/README.md ./README.md

USER node

# Default HTTP port
EXPOSE 8080

# Basic healthcheck (container considered healthy if process responds to tcp socket open)
HEALTHCHECK --interval=45s --timeout=6s --start-period=40s --retries=4 \
	CMD node -e "const n=require('net');const s=n.createConnection({host:'127.0.0.1',port:8080},()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1));setTimeout(()=>{s.destroy();process.exit(1)},5000);" || exit 1

ENTRYPOINT ["node", "dist/app.js"]