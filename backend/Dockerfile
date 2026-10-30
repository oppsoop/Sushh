# WorldFriends API - small production/dev image.
FROM node:22-alpine

WORKDIR /app

# Install production dependencies first so Docker can cache this layer.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY . .

ENV NODE_ENV=production
ENV PORT=8080
EXPOSE 8080

# Run migrations, then the API + websocket server.
CMD ["sh", "-c", "node scripts/migrate.js && node src/server.js"]
