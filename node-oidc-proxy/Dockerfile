# syntax=docker/dockerfile:1

# Node version is pinned in mise.toml ([tools].node) at the repo root.
# CI passes --build-arg NODE_VERSION=$(mise current node) when building.
ARG NODE_VERSION=24

# ---- build stage --------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS build
WORKDIR /app
# Install all deps (incl. dev) against the committed lockfile for a
# reproducible build, then compile TypeScript → dist/.
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- runtime stage ------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS runtime
ENV NODE_ENV=production
WORKDIR /app

# Production dependencies only; create a non-root user to run as.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev \
  && addgroup -S app \
  && adduser -S app -G app
COPY --from=build /app/dist ./dist

USER app
EXPOSE 8080

# Container-level liveness probe hitting the unauthenticated health route.
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz || exit 1

CMD ["node", "dist/server.js"]
