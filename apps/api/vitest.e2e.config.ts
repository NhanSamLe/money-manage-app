import { defineConfig } from "vitest/config";

// End-to-end tests need Docker (Postgres + PostgREST). Run with: npm run test:e2e
export default defineConfig({
  test: { include: ["test/e2e/**/*.e2e.test.ts"], testTimeout: 60_000, hookTimeout: 240_000, fileParallelism: false },
});
