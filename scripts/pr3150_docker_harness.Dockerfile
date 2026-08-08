FROM node:26-slim
WORKDIR /app
RUN npm install --no-save --ignore-scripts --no-audit --no-fund ws@8.21.0
COPY scripts ./scripts
CMD ["node", "scripts/server_load_jitter.mjs"]
