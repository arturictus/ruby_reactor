# Dockerfile for teley
FROM node:24-slim

WORKDIR /app

# Install git and other build deps
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Clone teley repo
RUN git clone https://github.com/logaretm/teley.git .

# Allow native builds for dependencies (like esbuild) via workspace config
RUN echo "dangerouslyAllowAllBuilds: true" > pnpm-workspace.yaml

# Patch workers/src/durable-object.ts to support default_token
RUN node -e ' \
  const fs = require("fs"); \
  const file = "workers/src/durable-object.ts"; \
  let content = fs.readFileSync(file, "utf8"); \
  content = content.replace("const token = url.searchParams.get(\x27token\x27);", "const token = url.searchParams.get(\x27token\x27) || \x27default_token\x27;"); \
  fs.writeFileSync(file, content, "utf8"); \
'

# Patch app/pages/live/[roomId].vue to support default_token fallback
RUN node -e ' \
  const fs = require("fs"); \
  const file = "app/pages/live/[roomId].vue"; \
  let content = fs.readFileSync(file, "utf8"); \
  content = content.replace("const token = (route.query.token as string) || \x27\x27;", "const token = (route.query.token as string) || \x27default_token\x27;"); \
  fs.writeFileSync(file, content, "utf8"); \
'

# Patch app/composables/useSession.ts to default to ruby_reactor_session and default_token
RUN node -e ' \
  const fs = require("fs"); \
  const file = "app/composables/useSession.ts"; \
  let content = fs.readFileSync(file, "utf8"); \
  content = content.replace(/const initialize = async \(\): Promise<void> => {[\s\S]*?};/, "const initialize = async (): Promise<void> => {\n    if (initialized.value) return;\n    roomId.value = \x27ruby_reactor_session\x27;\n    receiveToken.value = \x27default_token\x27;\n    isNewSession.value = false;\n    initialized.value = true;\n  };"); \
  fs.writeFileSync(file, content, "utf8"); \
'


# Enable corepack and install pnpm
RUN corepack enable && corepack prepare pnpm@latest --activate

# Install dependencies
RUN pnpm install --frozen-lockfile

# Build the Nuxt static files
RUN pnpm build

# Expose port
EXPOSE 3000

ENV HOST=0.0.0.0
ENV PORT=3000

# Start Cloudflare Pages local dev server via wrangler
WORKDIR /app/workers
CMD ["npx", "wrangler", "dev", "--ip", "0.0.0.0", "--port", "3000"]
