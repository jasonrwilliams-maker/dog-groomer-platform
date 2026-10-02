# The groomer interface (web/). Started with the rest of the stack —
# `docker compose up -d` — at http://localhost:3000 (this machine only).
# Node lives in the container, so nothing needs installing on the host.
FROM node:22-alpine
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --no-audit --no-fund
EXPOSE 3000
CMD ["npm", "run", "dev"]
