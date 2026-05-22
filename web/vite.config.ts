import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// Two modes:
//   dev   — Vite on :5173, proxies /api and /health to Vapor on :8080
//   build — emits the SPA to ../Public/web so Vapor's FileMiddleware serves it
//           on the same origin as the JSON API. Single-origin = no CORS.
export default defineConfig({
  plugins: [svelte()],
  build: {
    outDir: '../Public',
    emptyOutDir: true,
    sourcemap: true,
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      '/api': 'http://127.0.0.1:8080',
      '/health': 'http://127.0.0.1:8080',
    },
  },
});
