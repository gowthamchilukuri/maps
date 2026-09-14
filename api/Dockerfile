FROM node:20-bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends docker.io ca-certificates \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --omit=dev --no-fund --no-audit
COPY index.js server.js ./
COPY src ./src

ENV NODE_ENV=production
ENV UI_DIR=/ui
ENV PORT=8092
EXPOSE 8092
CMD ["node", "server.js"]
