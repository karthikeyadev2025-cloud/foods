/// <reference types="vitest/config" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { execSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';

/**
 * The commit this bundle was built from.
 *
 * Shown in Setup, because "is the site running the change I asked for?" is
 * otherwise unanswerable from the outside — and the wrong answer sends everyone
 * hunting for a bug in code the browser has never seen.
 *
 * Vercel and most CI runners check out a detached HEAD with git available; where
 * it is not, the build must still succeed, so this falls back rather than throws.
 */
function buildSha(): string {
  for (const env of ['VERCEL_GIT_COMMIT_SHA', 'GITHUB_SHA', 'COMMIT_REF']) {
    const v = process.env[env];
    if (v) return v.slice(0, 7);
  }
  try {
    return execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim();
  } catch {
    return 'unknown';
  }
}

export default defineConfig({
  // The desktop build is loaded from file:// (dist/index.html), so assets are relative there.
  base: process.env.VITE_DESKTOP ? './' : '/',
  define: {
    __APP_VERSION__: JSON.stringify(process.env.npm_package_version ?? '0.0.0'),
    __BUILD_SHA__: JSON.stringify(buildSha()),
    __BUILT_AT__: JSON.stringify(new Date().toISOString()),
  },
  plugins: [
    react(),
    {
      // public/ is copied verbatim, so the placeholder is replaced afterwards on
      // the built file rather than by a define, which never sees static assets.
      name: 'stamp-service-worker',
      apply: 'build',
      closeBundle() {
        const out = path.resolve(__dirname, 'dist/sw.js');
        if (!existsSync(out)) return;
        // Falls back to the clock rather than to buildSha()'s 'unknown': a
        // constant name is the whole bug, so the one thing this must never
        // produce is the same name twice.
        const sha = buildSha();
        const id = sha === 'unknown' ? `t${Date.now()}` : sha;
        writeFileSync(out, readFileSync(out, 'utf8').replaceAll('__BUILD_SHA__', id));
      },
    },
  ],
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    port: 5173,
  },
  test: {
    environment: 'node',
    include: ['src/**/*.test.ts', 'src/**/*.test.tsx'],
  },
});
