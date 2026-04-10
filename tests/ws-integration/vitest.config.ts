import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    dir: 'specs',
    testTimeout: 10000,
    hookTimeout: 10000,
    globals: true,
    // Run test files sequentially to avoid overwhelming the REAPER WebSocket server
    // with too many concurrent connections during token fetch + handshake
    fileParallelism: false,
  },
});
