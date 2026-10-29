# Dockerfile for teley
FROM node:24-slim

WORKDIR /app

# Install git and other build deps
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Clone teley repo, pinned so upstream refactors can't break the patches below
RUN git clone https://github.com/logaretm/teley.git . && git checkout f1c3c2ff52db0a855b25dbb11a7cde7e6a4dbfd8

# Patch workers/src/durable-object.ts to support default_token
RUN node -e ' \
  const fs = require("fs"); \
  const file = "workers/src/durable-object.ts"; \
  let content = fs.readFileSync(file, "utf8"); \
  const next = content.replace("const token = url.searchParams.get(\x27token\x27);", "const token = url.searchParams.get(\x27token\x27) || \x27default_token\x27;"); \
  if (next === content) throw new Error("patch target not found in " + file); \
  fs.writeFileSync(file, next, "utf8"); \
'

# Patch web/app/pages/live/[roomId].vue to support default_token fallback
RUN node -e ' \
  const fs = require("fs"); \
  const file = "web/app/pages/live/[roomId].vue"; \
  let content = fs.readFileSync(file, "utf8"); \
  const next = content.replace("const token = (route.query.token as string) || \x27\x27;", "const token = (route.query.token as string) || \x27default_token\x27;"); \
  if (next === content) throw new Error("patch target not found in " + file); \
  fs.writeFileSync(file, next, "utf8"); \
'

# Patch web/app/composables/useSession.ts to default to ruby_reactor_session and default_token
RUN node -e ' \
  const fs = require("fs"); \
  const file = "web/app/composables/useSession.ts"; \
  let content = fs.readFileSync(file, "utf8"); \
  const next = content.replace(/const initialize = async \(\): Promise<void> => {[\s\S]*?};/, "const initialize = async (): Promise<void> => {\n    if (initialized.value) return;\n    roomId.value = \x27ruby_reactor_session\x27;\n    receiveToken.value = \x27default_token\x27;\n    isNewSession.value = false;\n    initialized.value = true;\n  };"); \
  if (next === content) throw new Error("patch target not found in " + file); \
  fs.writeFileSync(file, next, "utf8"); \
'

# Enable corepack; it installs the pnpm version pinned in package.json's packageManager
RUN corepack enable

# Install dependencies (native builds are allowed via upstream pnpm-workspace.yaml allowBuilds)
RUN pnpm install --frozen-lockfile

# Build the Nuxt static files into web/.output/public (served by the worker as assets)
RUN pnpm -C web build

# Expose port
EXPOSE 3000

ENV HOST=0.0.0.0
ENV PORT=3000

# Start Cloudflare Pages local dev server via wrangler
WORKDIR /app/workers
CMD ["npx", "wrangler", "dev", "--ip", "0.0.0.0", "--port", "3000"]
