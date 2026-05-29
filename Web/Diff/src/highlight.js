// Minimal Go syntax highlighter, ported verbatim from Loom.html's
// diff-view.jsx. Returns an array of { t: text, c: className | null }
// tokens so the React component can map them to spans.

const GO_KW = new Set([
  'func', 'package', 'import', 'if', 'else', 'for', 'return', 'var',
  'const', 'type', 'struct', 'interface', 'range', 'go', 'defer',
  'select', 'case', 'default', 'break', 'continue', 'switch', 'chan',
  'map', 'fallthrough', 'goto', 'nil', 'true', 'false', 'make',
]);
const GO_TY = new Set([
  'string', 'int', 'int32', 'int64', 'uint', 'uint32', 'uint64',
  'byte', 'bool', 'error', 'context', 'rune', 'float32', 'float64',
]);

export function tokenize(text, lang) {
  if (lang !== 'go' || !text) return [{ t: text || '', c: null }];
  const parts = [];
  let i = 0;
  while (i < text.length) {
    const c = text[i];
    // Strings
    if (c === '"' || c === '`') {
      const q = c;
      let j = i + 1;
      while (j < text.length && text[j] !== q) {
        if (text[j] === '\\' && q === '"') j++;
        j++;
      }
      parts.push({ t: text.slice(i, Math.min(j + 1, text.length)), c: 'str' });
      i = j + 1;
      continue;
    }
    // Line comments
    if (c === '/' && text[i + 1] === '/') {
      parts.push({ t: text.slice(i), c: 'com' });
      break;
    }
    // Whitespace
    if (/\s/.test(c)) {
      let j = i;
      while (j < text.length && /\s/.test(text[j])) j++;
      parts.push({ t: text.slice(i, j), c: null });
      i = j;
      continue;
    }
    // Numbers
    if (/[0-9]/.test(c)) {
      let j = i;
      while (j < text.length && /[0-9a-fxA-FX._]/.test(text[j])) j++;
      parts.push({ t: text.slice(i, j), c: 'num' });
      i = j;
      continue;
    }
    // Identifiers
    if (/[a-zA-Z_]/.test(c)) {
      let j = i;
      while (j < text.length && /[a-zA-Z0-9_]/.test(text[j])) j++;
      const w = text.slice(i, j);
      let cl = 'id';
      if (GO_KW.has(w)) cl = 'kw';
      else if (GO_TY.has(w)) cl = 'ty';
      else if (/^[A-Z]/.test(w)) cl = 'ty';
      else if (text[j] === '(') cl = 'fn';
      parts.push({ t: w, c: cl });
      i = j;
      continue;
    }
    // Operators / punctuation
    let j = i;
    while (j < text.length && !/[a-zA-Z0-9_\s"`]/.test(text[j]) && text[j] !== '/') {
      j++;
    }
    if (j === i) j = i + 1;
    parts.push({ t: text.slice(i, j), c: 'op' });
    i = j;
  }
  return parts;
}
