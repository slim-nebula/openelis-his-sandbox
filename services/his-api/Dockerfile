FROM node:20-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
# ci, not install: builds the exact tree the lockfile pins. `npm install` would
# quietly resolve newer versions and produce an image nobody can reproduce.
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY swagger.yaml ./swagger.yaml
# curl is what the compose healthcheck uses; the slim image has none.
RUN apt-get update -y && apt-get install -y --no-install-recommends curl \
 && rm -rf /var/lib/apt/lists/*
EXPOSE 8080
CMD ["node", "dist/server.js"]
