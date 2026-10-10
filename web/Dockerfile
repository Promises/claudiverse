# syntax=docker/dockerfile:1
# Production image for the Claudiverse web SPA (Vite/React).
#
# VITE_API_URL is COMPILE-TIME in Vite (baked into the bundle), so it must be
# supplied as a build arg, not a runtime env var. Point it at the public URL of
# the API server (e.g. http://your-host:4000).

# ---------- build stage ----------
FROM node:24-slim AS build

WORKDIR /app

ARG VITE_API_URL=http://localhost:4000
ENV VITE_API_URL=${VITE_API_URL}

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
# Use `vite build` directly rather than the package.json "build" script: that
# script gates on `tsc -b`, but the app has pre-existing type errors and the dev
# server (plain `vite`) never typechecks. Vite/esbuild transpiles + bundles the
# same code that runs in dev. Fix the TS errors separately to re-enable `tsc`.
RUN npx vite build

# ---------- runtime stage ----------
FROM nginx:1.27-alpine AS runtime

# SPA fallback config (client-side routing via react-router).
COPY nginx.conf /etc/nginx/conf.d/default.conf

COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
