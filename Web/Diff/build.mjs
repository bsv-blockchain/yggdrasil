// esbuild driver. Bundles src/index.jsx (the diff React app) into the
// macOS app's resource directory at Yggdrasil/Resources/diff2html/index.js.
//
// Why a separate Web/Diff/ source tree instead of running esbuild inside
// the Xcode build:
//   - Keeps Node out of `xcodebuild`. CI doesn't need npm; the committed
//     index.js is what ships.
//   - Developers who edit the JSX run `make js` (or `npm run build` here)
//     to regenerate, then commit the diff.
//   - Cleanly separates "source we author" (JSX) from "shipped artifact"
//     (one bundled, minified JS file). The diff in PRs makes it obvious
//     which is which.

import * as esbuild from 'esbuild';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const watch = process.argv.includes('--watch');

const opts = {
  entryPoints: [resolve(__dirname, 'src/index.jsx')],
  bundle: true,
  minify: !watch,
  sourcemap: watch ? 'inline' : false,
  format: 'iife',
  target: ['safari17'],
  outfile: resolve(__dirname, '../../Yggdrasil/Resources/diff2html/index.js'),
  loader: { '.jsx': 'jsx', '.js': 'jsx' },
  jsx: 'automatic',
  // Inline React + ReactDOM (no CDN, no runtime Babel). React's dev build
  // is heavier; the prod build (NODE_ENV=production) trims it ~3x.
  define: {
    'process.env.NODE_ENV': watch ? '"development"' : '"production"',
  },
  logLevel: 'info',
};

if (watch) {
  const ctx = await esbuild.context(opts);
  await ctx.watch();
  console.log('[esbuild] watching…');
} else {
  await esbuild.build(opts);
}
