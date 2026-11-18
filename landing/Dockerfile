FROM node:22-alpine AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY astro.config.mjs tsconfig.json ./
COPY public ./public
COPY src ./src
RUN ASTRO_TELEMETRY_DISABLED=1 npm run build

FROM nginx:1.28-alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=builder /app/dist /usr/share/nginx/html

EXPOSE 80
