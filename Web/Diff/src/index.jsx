// Entry point. Mounts the React tree and wires the `window.yggdrasil`
// bridge that the Swift host calls into. Compiled by esbuild into
// `Yggdrasil/Resources/diff2html/index.js`.

import React, { useState, useCallback } from 'react';
import { createRoot } from 'react-dom/client';
import { DiffView } from './DiffView.jsx';
import { parseDiff } from './parser.js';
import './styles.css';

function App({ diffText, theme, scopeOptions, onScopeChange }) {
  const [mode, setMode] = useState('split');
  const files = React.useMemo(() => parseDiff(diffText || ''), [diffText]);
  React.useEffect(() => {
    document.body.setAttribute('data-theme', theme);
  }, [theme]);
  return (
    <DiffView
      files={files}
      mode={mode}
      setMode={setMode}
      scopeOptions={scopeOptions}
      onScopeChange={onScopeChange}
    />
  );
}

// Single mount point: <div id="app"></div> is in the HTML.
const mount = document.getElementById('app');
const root = createRoot(mount);

const state = {
  diffText: '',
  theme: 'dark',
  scopeOptions: { branchEnabled: true, selected: 'branch' },
};

function rerender() {
  root.render(
    <App
      diffText={state.diffText}
      theme={state.theme}
      scopeOptions={state.scopeOptions}
      onScopeChange={postScope}
    />
  );
}

function postScope(value) {
  try {
    window.webkit.messageHandlers.yggdrasil.postMessage({
      type: 'scope', value,
    });
  } catch (e) {
    // No bridge (standalone preview) — just update local state so the
    // toolbar UI reflects the click.
    state.scopeOptions = { ...state.scopeOptions, selected: value };
    rerender();
  }
}

// --- Public API (called by Swift via WKWebView.evaluateJavaScript) --

window.yggdrasil = window.yggdrasil || {};
window.yggdrasil.render = function (text) {
  state.diffText = (text || '').toString();
  rerender();
};
window.yggdrasil.clear = function () {
  state.diffText = '';
  rerender();
};
window.yggdrasil.setTheme = function (theme) {
  if (theme === 'dark' || theme === 'light') {
    state.theme = theme;
    rerender();
  }
};
/// opts = { branchEnabled: boolean, selected: 'branch' | 'uncommitted' }
window.yggdrasil.setScopeOptions = function (opts) {
  state.scopeOptions = {
    branchEnabled: !!opts.branchEnabled,
    selected: opts.selected === 'uncommitted' ? 'uncommitted' : 'branch',
  };
  rerender();
};

// OS theme fallback if Swift never sets one
(function () {
  const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
  state.theme = dark ? 'dark' : 'light';
  rerender();
})();
