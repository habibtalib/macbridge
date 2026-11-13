FROM node:24-alpine
WORKDIR /app
RUN corepack enable
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --prod --frozen-lockfile
COPY src ./src
ENV NODE_ENV=production PORT=8787 HOST=0.0.0.0
EXPOSE 8787
USER node
CMD ["node", "src/main.ts"]
