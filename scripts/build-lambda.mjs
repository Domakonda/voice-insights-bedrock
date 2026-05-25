#!/usr/bin/env node
import { build } from 'esbuild';
import { createWriteStream, mkdirSync, rmSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import archiver from 'archiver';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = resolve(__dirname, '..');
const outDir = resolve(root, 'terraform', 'dist');

const handlers = [
  { name: 'submission', entry: 'src/handlers/submission/src/app.ts' },
  { name: 'normalization', entry: 'src/handlers/normalization/src/app.ts' },
  { name: 'retrieval', entry: 'src/handlers/retrieval/src/app.ts' },
];

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });

async function bundleAndZip({ name, entry }) {
  const buildDir = resolve(outDir, name);
  mkdirSync(buildDir, { recursive: true });

  await build({
    entryPoints: [resolve(root, entry)],
    bundle: true,
    platform: 'node',
    target: 'node20',
    format: 'esm',
    outfile: resolve(buildDir, 'index.mjs'),
    sourcemap: 'inline',
    minify: false,
    treeShaking: true,
    banner: {
      js: "import{createRequire as __cr}from'module';const require=__cr(import.meta.url);",
    },
    external: ['@aws-sdk/*'],
    logLevel: 'info',
  });

  const zipPath = resolve(outDir, `${name}.zip`);
  await new Promise((resolvePromise, rejectPromise) => {
    const output = createWriteStream(zipPath);
    const archive = archiver('zip', { zlib: { level: 9 } });
    output.on('close', resolvePromise);
    archive.on('error', rejectPromise);
    archive.pipe(output);
    archive.file(resolve(buildDir, 'index.mjs'), { name: 'index.mjs' });
    archive.finalize();
  });

  console.log(`built ${name} → ${zipPath}`);
}

for (const h of handlers) {
  await bundleAndZip(h);
}
console.log('all handlers bundled');
