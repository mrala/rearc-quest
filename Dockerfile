# The bundled binaries in bin/ are linux/amd64 (x86-64) ELF, so the image must be
# amd64 even when built on Apple Silicon. Pinning it here avoids an "exec format
# error" at runtime if someone forgets --platform.
FROM --platform=linux/amd64 node:24-slim

ENV NODE_ENV=production
WORKDIR /app

# Node as PID 1 ignores SIGTERM, so "docker stop" (and ECS) wait out the grace
# period and then SIGKILL the task. tini forwards signals and reaps children.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/*

# Install dependencies first so this layer is cached until the lockfile changes.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

# src/000.js runs the binaries by relative path (bin/001 ...), so WORKDIR must be
# the directory that contains bin/.
COPY src ./src
COPY bin ./bin

# The node image ships a non-root "node" user (uid 1000).
USER node

EXPOSE 3000
ENTRYPOINT ["tini", "--"]
CMD ["node", "src/000.js"]
