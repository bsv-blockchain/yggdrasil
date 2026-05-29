// Parse `git diff` unified-diff text into structured data the React tree
// can render. Same shape as the design's LOOM_DIFF_FILES fixture:
//   { path, status, lang, add, del, hunks: [{ header, lines: [...] }] }
// with each line = { type: 'add' | 'del' | 'ctx', n, oldN?, text }.

export function parseDiff(text) {
  const files = [];
  let cur = null;
  let hunk = null;
  let oldLn = 0, newLn = 0;
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.startsWith('diff --git ')) {
      if (cur) files.push(cur);
      const m = l.match(/^diff --git a\/(.+) b\/(.+)$/);
      const path = m ? m[2] : l.slice('diff --git '.length);
      cur = {
        path,
        status: 'modified',
        add: 0,
        del: 0,
        hunks: [],
        lang: detectLang(path),
      };
      hunk = null;
      continue;
    }
    if (!cur) continue;
    if (l.startsWith('--- ')) {
      if (l === '--- /dev/null') cur.status = 'added';
      continue;
    }
    if (l.startsWith('+++ ')) {
      if (l === '+++ /dev/null') cur.status = 'deleted';
      continue;
    }
    if (l.startsWith('@@ ')) {
      const m = l.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/);
      if (m) {
        oldLn = parseInt(m[1], 10);
        newLn = parseInt(m[2], 10);
        hunk = { header: l, lines: [] };
        cur.hunks.push(hunk);
      }
      continue;
    }
    if (!hunk) continue;
    const tag = l[0];
    if (tag === '+') {
      hunk.lines.push({ type: 'add', n: newLn++, text: l.slice(1) });
      cur.add++;
    } else if (tag === '-') {
      hunk.lines.push({ type: 'del', n: oldLn++, text: l.slice(1) });
      cur.del++;
    } else if (tag === ' ') {
      hunk.lines.push({ type: 'ctx', n: newLn, oldN: oldLn, text: l.slice(1) });
      oldLn++;
      newLn++;
    }
    // '\ No newline at end of file' and the like — skip
  }
  if (cur) files.push(cur);
  return files;
}

export function detectLang(path) {
  const m = path.match(/\.([^./]+)$/);
  return m ? m[1].toLowerCase() : '';
}

/// Folder tree from a flat file list. Each node has children + files.
/// Used by the file-tree sidebar.
export function buildTree(files) {
  const root = { name: '', children: {}, files: [] };
  for (const f of files) {
    const parts = f.path.split('/');
    let node = root;
    for (let i = 0; i < parts.length - 1; i++) {
      const p = parts[i];
      if (!node.children[p]) {
        node.children[p] = { name: p, children: {}, files: [] };
      }
      node = node.children[p];
    }
    node.files.push(f);
  }
  return root;
}

/// Pair adjacent del/add blocks for side-by-side rendering. Context
/// lines appear on both sides. Returns rows = [{ left, right }] where
/// either side can be null (= empty placeholder cell).
export function pairForSplit(lines) {
  const out = [];
  let i = 0;
  while (i < lines.length) {
    const l = lines[i];
    if (l.type === 'ctx') {
      out.push({ left: l, right: l });
      i++;
    } else if (l.type === 'del') {
      const dels = [];
      while (i < lines.length && lines[i].type === 'del') {
        dels.push(lines[i]);
        i++;
      }
      const adds = [];
      while (i < lines.length && lines[i].type === 'add') {
        adds.push(lines[i]);
        i++;
      }
      const max = Math.max(dels.length, adds.length);
      for (let k = 0; k < max; k++) {
        out.push({ left: dels[k] || null, right: adds[k] || null });
      }
    } else if (l.type === 'add') {
      const adds = [];
      while (i < lines.length && lines[i].type === 'add') {
        adds.push(lines[i]);
        i++;
      }
      for (const a of adds) out.push({ left: null, right: a });
    } else {
      i++;
    }
  }
  return out;
}
