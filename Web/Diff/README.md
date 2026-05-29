# Yggdrasil — Diff View React Source

This directory holds the React source for the diff pane that renders inside
the macOS app's `WKWebView`. The bundled output lives at
`Yggdrasil/Resources/diff2html/index.js` and is committed to the repo — the
Xcode build does not run esbuild.

## Build

```bash
cd Web/Diff
npm install      # one-time, or whenever dependencies change
npm run build    # writes ../../Yggdrasil/Resources/diff2html/index.js
```

Or from the repo root: `make js`.

Watch mode for iteration:

```bash
npm run watch
```

Then reload the diff pane in the running app (close + reopen the tab, or
relaunch Yggdrasil) to pick up the change.

## Layout

- `src/index.jsx` — entry point. Mounts the React tree, exposes the
  `window.yggdrasil` bridge (render, clear, setTheme, setScopeOptions)
  to Swift, and posts scope changes back via `webkit.messageHandlers`.
- `src/DiffView.jsx` — top-level layout: file tree (left) + per-file
  cards (right), toolbar with split/unified + scope toggle.
- `src/icons.jsx` — inline SVG icons.
- `src/highlight.js` — tiny Go syntax highlighter ported from the
  design. Other languages render unhighlighted.
- `src/parser.js` — parses unified-diff text into structured data.
- `src/styles.css` — design tokens + component styles, imported by the
  entry point and inlined into the bundle via esbuild's CSS loader.

## Source

The design components originate from Claude Design's `Loom.html`
handoff. Adapted to consume parsed diff data over the
`window.yggdrasil.render` bridge instead of a hard-coded fixture.
