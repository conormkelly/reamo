import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    dir: 'specs',
    testTimeout: 10000,
    hookTimeout: 10000,
    globals: true,
    // Sequential to avoid race conditions with REAPER's broadcast timing
    fileParallelism: false,
  },
});
