FROM node:22-alpine AS dependencies

WORKDIR /app/api
COPY api/package.json api/package-lock.json ./
RUN npm ci --omit=dev

FROM node:22-alpine

ENV NODE_ENV=production \
    CONSOLE_PORT=8080
WORKDIR /app/api

COPY --from=dependencies --chown=node:node /app/api/node_modules ./node_modules
COPY --chown=node:node api/package.json api/package-lock.json ./
COPY --chown=node:node api/src ./src
COPY --chown=node:node web /app/web

USER node
EXPOSE 8080
HEALTHCHECK --interval=15s --timeout=3s --retries=3 CMD node -e "fetch('http://127.0.0.1:8080/api/health').then(r=>{if(!r.ok)process.exit(1)}).catch(()=>process.exit(1))"

CMD ["node", "src/server.js"]
