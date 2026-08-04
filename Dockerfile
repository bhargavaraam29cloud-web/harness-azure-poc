# ================================================================
# FILE: Dockerfile
# PURPOSE:
#   Packages the Node.js server into a Docker container image.
#   Harness CI's BuildAndPushACR step runs this file and pushes
#   the resulting image to harnesspoc7058.azurecr.io.
#
# HOW IT WORKS — MULTI-STAGE BUILD:
#   Stage 1 (builder): Installs npm dependencies in a full image.
#   Stage 2 (runtime): Copies only the built files into a slim
#   image — keeping the final image small and secure.
#
# HOW TO BUILD LOCALLY (to test before committing):
#   docker build -t harness-poc:local .
#   docker run -p 80:80 harness-poc:local
#   curl http://localhost/health   → should return {"status":"ok",...}
# ================================================================

# ----------------------------------------------------------------
# STAGE 1 — builder
# Use the official slim Node.js 20 image as the build environment.
# "slim" removes non-essential OS packages, reducing image size.
# ----------------------------------------------------------------
FROM node:20-slim AS builder

# Set a clean working directory inside the builder container.
WORKDIR /build

# Copy dependency manifest first (Docker caches this layer).
# If package.json has not changed, npm install is skipped on
# subsequent builds — saving significant build time.
COPY app/package*.json ./

# Install only production dependencies (no devDependencies).
RUN npm install --omit=dev

# Copy the rest of the application source code.
COPY app/ .

# ----------------------------------------------------------------
# STAGE 2 — runtime
# Start fresh from the same slim base so the final image does
# NOT include build tools, npm cache, or temporary files.
# ----------------------------------------------------------------
FROM node:20-slim AS runtime

# Create a non-root user to run the process — security best practice.
# Running as root inside a container is a known vulnerability.
RUN groupadd -r appuser && useradd -r -g appuser appuser

WORKDIR /app

# Copy compiled app and node_modules from the builder stage only.
COPY --from=builder /build .

# Change ownership of all files to the non-root user.
RUN chown -R appuser:appuser /app

# Switch to non-root user before starting the process.
USER appuser

# Document the port the container listens on.
# Kubernetes and Azure Load Balancer use this value.
EXPOSE 80

# Set NODE_ENV so Express runs in production mode (faster, less logging).
ENV NODE_ENV=production
ENV PORT=80

# Start the server.
CMD ["node", "server.js"]
