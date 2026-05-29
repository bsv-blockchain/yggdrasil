// Top-level diff layout. Ported from Loom.html (Claude Design)
// diff-view.jsx, with two adaptations:
//   - Reads files from a `diff` prop (parsed from the unified diff text
//     the Swift host sends in) instead of the static LOOM_DIFF_FILES.
//   - Toolbar gains a scope toggle (branch / uncommitted) whose value
//     round-trips to Swift via window.webkit.messageHandlers.

import React, { useMemo, useState, useRef, useCallback } from 'react';
import { Icon } from './icons.jsx';
import { tokenize } from './highlight.js';
import { buildTree, pairForSplit } from './parser.js';

const LANG_EXT_COLORS = {
  go: '#67d4ce',
  md: '#a4baff',
  puml: '#ff7a59',
  svg: '#c4cad6',
  ts: '#3b82f6',
  swift: '#ff7a59',
};

function fileIconColor(lang) {
  return LANG_EXT_COLORS[lang] || 'var(--text-mute)';
}

function HighlightedLine({ text, lang }) {
  if (!text) return <span>&nbsp;</span>;
  const parts = tokenize(text, lang);
  return (
    <>
      {parts.map((p, i) =>
        p.c
          ? <span key={i} className={`syn-${p.c}`}>{p.t}</span>
          : <span key={i}>{p.t}</span>
      )}
    </>
  );
}

// ----------------------------------------------------------------- Tree

function FileTreeNode({ node, depth = 0, selectedPath, onSelect }) {
  const [open, setOpen] = useState(true);
  const childFolders = Object.values(node.children).sort((a, b) =>
    a.name.localeCompare(b.name));
  return (
    <div>
      {node.name && (
        <button
          onClick={() => setOpen(!open)}
          style={{
            width: '100%', display: 'flex', alignItems: 'center', gap: 5,
            padding: `3px 8px 3px ${depth * 12 + 8}px`,
            background: 'transparent', border: 'none', cursor: 'pointer',
            color: 'var(--text-dim)', fontSize: 12, fontFamily: 'var(--font-sans)',
            textAlign: 'left',
          }}
        >
          <Icon name={open ? 'chevronDown' : 'chevronRight'} size={11}
                style={{ opacity: 0.5, flexShrink: 0 }} />
          <Icon name={open ? 'folderOpen' : 'folder'} size={13}
                style={{ color: 'var(--text-mute)', flexShrink: 0 }} />
          <span>{node.name}</span>
        </button>
      )}
      {open && (
        <>
          {childFolders.map(c => (
            <FileTreeNode
              key={c.name}
              node={c}
              depth={node.name ? depth + 1 : depth}
              selectedPath={selectedPath}
              onSelect={onSelect}
            />
          ))}
          {node.files.map(f => {
            const selected = f.path === selectedPath;
            return (
              <button
                key={f.path}
                onClick={() => onSelect(f.path)}
                style={{
                  width: '100%', display: 'flex', alignItems: 'center', gap: 6,
                  padding: `3px 8px 3px ${(node.name ? depth + 1 : depth) * 12 + 8}px`,
                  background: selected ? 'var(--accent-soft)' : 'transparent',
                  border: 'none', cursor: 'pointer',
                  color: selected ? 'var(--accent)' : 'var(--text)',
                  fontSize: 12, fontFamily: 'var(--font-sans)',
                  textAlign: 'left',
                  borderLeft: selected ? '2px solid var(--accent)' : '2px solid transparent',
                }}
              >
                <div style={{
                  width: 6, height: 6, borderRadius: 1, flexShrink: 0,
                  background:
                    f.status === 'added' ? 'var(--add)' :
                    f.status === 'deleted' ? 'var(--del)' : 'var(--accent)',
                }} />
                <span style={{
                  flex: 1, minWidth: 0, overflow: 'hidden',
                  textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                  fontFamily: 'var(--font-mono)', fontSize: 11.5, letterSpacing: -0.1,
                }}>{f.path.split('/').pop()}</span>
                <span style={{
                  fontSize: 10, fontFamily: 'var(--font-mono)',
                  color: 'var(--add)', letterSpacing: 0.2,
                }}>+{f.add}</span>
                <span style={{
                  fontSize: 10, fontFamily: 'var(--font-mono)',
                  color: 'var(--del)', letterSpacing: 0.2,
                }}>−{f.del}</span>
              </button>
            );
          })}
        </>
      )}
    </div>
  );
}

// ----------------------------------------------------------------- Rows

function DiffRow({ line, lang }) {
  const bg =
    line.type === 'add' ? 'var(--add-bg)' :
    line.type === 'del' ? 'var(--del-bg)' : 'transparent';
  const prefix = line.type === 'add' ? '+' : line.type === 'del' ? '−' : ' ';
  const prefixColor =
    line.type === 'add' ? 'var(--add)' :
    line.type === 'del' ? 'var(--del)' : 'var(--diff-gutter)';
  const oldN = line.type === 'del' ? line.n : line.type === 'ctx' ? line.oldN : '';
  const newN = line.type === 'add' || line.type === 'ctx' ? line.n : '';
  return (
    <div style={{ display: 'flex', background: bg, minHeight: 20, lineHeight: '20px' }}>
      <div style={gutterStyle}>{oldN}</div>
      <div style={gutterStyle}>{newN}</div>
      <div style={{
        width: 18, textAlign: 'center', color: prefixColor,
        fontWeight: 600, flexShrink: 0, userSelect: 'none',
      }}>{prefix}</div>
      <div style={{
        flex: 1, paddingRight: 12, whiteSpace: 'pre',
        color:
          line.type === 'add' ? 'var(--diff-add-fg)' :
          line.type === 'del' ? 'var(--diff-del-fg)' : 'var(--diff-context)',
        overflowX: 'auto',
      }}>
        <HighlightedLine text={line.text} lang={lang} />
      </div>
    </div>
  );
}

const gutterStyle = {
  width: 48, textAlign: 'right', padding: '0 8px',
  color: 'var(--diff-gutter)', fontSize: 10.5,
  userSelect: 'none', flexShrink: 0,
  borderRight: '0.5px solid var(--border)',
};

function SideBySideRow({ left, right, lang }) {
  const cell = (line, side) => {
    if (!line) {
      return (
        <div style={{ flex: 1, background: 'rgba(0,0,0,0.04)',
                      borderRight: side === 'left' ? '0.5px solid var(--border)' : 'none' }} />
      );
    }
    const t = line.type;
    const bg =
      t === 'add' ? 'var(--add-bg)' :
      t === 'del' ? 'var(--del-bg)' : 'transparent';
    const prefix = t === 'add' ? '+' : t === 'del' ? '−' : ' ';
    const prefixColor =
      t === 'add' ? 'var(--add)' :
      t === 'del' ? 'var(--del)' : 'var(--diff-gutter)';
    const lineNo = t === 'ctx'
      ? (side === 'left' ? line.oldN : line.n)
      : line.n;
    return (
      <div style={{
        flex: 1, display: 'flex', background: bg, minWidth: 0,
        borderRight: side === 'left' ? '0.5px solid var(--border)' : 'none',
      }}>
        <div style={gutterStyle}>{lineNo}</div>
        <div style={{
          width: 18, textAlign: 'center', color: prefixColor,
          fontWeight: 600, flexShrink: 0, userSelect: 'none',
        }}>{prefix}</div>
        <div style={{
          flex: 1, paddingRight: 12, whiteSpace: 'pre',
          color:
            t === 'add' ? 'var(--diff-add-fg)' :
            t === 'del' ? 'var(--diff-del-fg)' : 'var(--diff-context)',
          overflowX: 'auto', minWidth: 0,
        }}>
          <HighlightedLine text={line.text} lang={lang} />
        </div>
      </div>
    );
  };
  return (
    <div style={{ display: 'flex', minHeight: 20, lineHeight: '20px' }}>
      {cell(left, 'left')}
      {cell(right, 'right')}
    </div>
  );
}

// ----------------------------------------------------------------- Hunk + File

const hunkHeaderStyle = {
  background: 'var(--bg-pane-soft)',
  borderTop: '0.5px solid var(--border)',
  borderBottom: '0.5px solid var(--border)',
  height: 24, display: 'flex', alignItems: 'center',
};

function DiffHunk({ hunk, lang, mode }) {
  if (mode === 'unified') {
    return (
      <div>
        <div style={hunkHeaderStyle}>
          <span style={{ paddingLeft: 8, color: 'var(--text-mute)', fontSize: 11, fontFamily: 'var(--font-mono)' }}>
            {hunk.header}
          </span>
        </div>
        <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5 }}>
          {hunk.lines.map((line, i) =>
            <DiffRow key={i} line={line} lang={lang} />)}
        </div>
      </div>
    );
  }
  const rows = pairForSplit(hunk.lines);
  return (
    <div>
      <div style={hunkHeaderStyle}>
        <span style={{ paddingLeft: 8, color: 'var(--text-mute)', fontSize: 11, fontFamily: 'var(--font-mono)' }}>
          {hunk.header}
        </span>
      </div>
      <div style={{ fontFamily: 'var(--font-mono)', fontSize: 11.5 }}>
        {rows.map((r, i) =>
          <SideBySideRow key={i} left={r.left} right={r.right} lang={lang} />)}
      </div>
    </div>
  );
}

function DiffBar({ add, del }) {
  const total = Math.max(add + del, 1);
  const addSegs = Math.round((add / total) * 5);
  return (
    <div style={{ display: 'flex', gap: 2, alignItems: 'center' }}>
      {Array.from({ length: 5 }).map((_, i) => (
        <div key={i} style={{
          width: 7, height: 7, borderRadius: 1,
          background:
            i < addSegs ? 'var(--add)' :
            i < 5 ? 'var(--del)' : 'var(--border)',
        }} />
      ))}
    </div>
  );
}

function DiffFile({ file, mode, collapsed, onToggle }) {
  return (
    <div style={{
      borderRadius: 8, overflow: 'hidden',
      border: '0.5px solid var(--border)',
      background: 'var(--bg-pane)',
      marginBottom: 14,
    }}>
      <div
        onClick={onToggle}
        style={{
          display: 'flex', alignItems: 'center', gap: 9,
          padding: '9px 12px',
          background: 'var(--bg-pane-soft)',
          borderBottom: collapsed ? 'none' : '0.5px solid var(--border)',
          cursor: 'pointer', userSelect: 'none',
        }}
      >
        <Icon name={collapsed ? 'chevronRight' : 'chevronDown'} size={12}
              style={{ color: 'var(--text-dim)', flexShrink: 0 }} />
        <Icon name="file" size={13}
              style={{ color: fileIconColor(file.lang), flexShrink: 0 }} />
        <span style={{
          fontFamily: 'var(--font-mono)', fontSize: 12,
          color: 'var(--text)', letterSpacing: -0.1,
          minWidth: 0, overflow: 'hidden',
          textOverflow: 'ellipsis', whiteSpace: 'nowrap',
        }}>{file.path}</span>
        <div style={{
          padding: '1px 6px', borderRadius: 3, flexShrink: 0,
          fontSize: 9.5, fontWeight: 600, letterSpacing: 0.4,
          textTransform: 'uppercase', fontFamily: 'var(--font-mono)',
          background:
            file.status === 'added' ? 'color-mix(in srgb, var(--add) 18%, transparent)' :
            file.status === 'deleted' ? 'color-mix(in srgb, var(--del) 18%, transparent)' :
            'var(--accent-soft)',
          color:
            file.status === 'added' ? 'var(--add)' :
            file.status === 'deleted' ? 'var(--del)' : 'var(--accent)',
        }}>{file.status}</div>
        <div style={{ flex: 1 }} />
        <div style={{ display: 'flex', alignItems: 'center', gap: 8,
                      fontFamily: 'var(--font-mono)', fontSize: 11, flexShrink: 0 }}>
          <span style={{ color: 'var(--add)' }}>+{file.add}</span>
          <span style={{ color: 'var(--del)' }}>−{file.del}</span>
          <DiffBar add={file.add} del={file.del} />
        </div>
      </div>
      {!collapsed && file.hunks.length > 0 && (
        <div style={{ background: 'var(--bg-pane)' }}>
          {file.hunks.map((h, i) =>
            <DiffHunk key={i} hunk={h} lang={file.lang} mode={mode} />)}
        </div>
      )}
      {!collapsed && file.hunks.length === 0 && (
        <div style={{
          padding: '20px 16px', color: 'var(--text-mute)', fontSize: 12,
          fontFamily: 'var(--font-mono)', textAlign: 'center',
        }}>
          (no hunks)
        </div>
      )}
    </div>
  );
}

// ----------------------------------------------------------------- Top-level

export function DiffView({ files, mode, setMode, scopeOptions, onScopeChange }) {
  const [selectedPath, setSelectedPath] = useState(files[0]?.path || null);
  const [collapsed, setCollapsed] = useState({});
  const fileRefs = useRef({});

  // If the file list changes (re-render with new data), update selection
  // to the first file when the previous selection is gone.
  if (selectedPath && !files.find(f => f.path === selectedPath)) {
    // setState during render is normally a no-no, but useEffect would
    // cause a flicker; this is safe because we always converge.
    queueMicrotask(() => setSelectedPath(files[0]?.path || null));
  }

  const tree = useMemo(() => buildTree(files), [files]);
  const totalAdd = files.reduce((s, f) => s + f.add, 0);
  const totalDel = files.reduce((s, f) => s + f.del, 0);

  const onPickFile = useCallback((path) => {
    setSelectedPath(path);
    const el = fileRefs.current[path];
    if (el) el.scrollIntoView({ block: 'start', behavior: 'smooth' });
  }, []);

  const isEmpty = files.length === 0;

  return (
    <div style={{ display: 'flex', height: '100%', overflow: 'hidden',
                  background: 'var(--bg-pane)' }}>
      <aside style={{
        width: 220, flexShrink: 0,
        borderRight: '0.5px solid var(--border)',
        display: 'flex', flexDirection: 'column',
        background: 'var(--bg-pane-soft)',
      }}>
        <div style={{ padding: '12px 14px 10px',
                       borderBottom: '0.5px solid var(--border)' }}>
          <div style={{
            fontSize: 10.5, fontWeight: 600,
            color: 'var(--text-mute)',
            letterSpacing: 1, textTransform: 'uppercase',
          }}>Files changed</div>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8, marginTop: 4 }}>
            <span style={{ fontSize: 18, fontWeight: 600,
                           color: 'var(--text)', letterSpacing: -0.4 }}>
              {files.length}
            </span>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--add)' }}>+{totalAdd}</span>
            <span style={{ fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--del)' }}>−{totalDel}</span>
          </div>
        </div>
        <div style={{ flex: 1, overflowY: 'auto', padding: '6px 0' }}>
          {isEmpty ? (
            <div style={{
              padding: '14px 14px', color: 'var(--text-faint)', fontSize: 11.5,
              fontFamily: 'var(--font-sans)',
            }}>
              No changes.
            </div>
          ) : (
            <FileTreeNode node={tree} selectedPath={selectedPath} onSelect={onPickFile} />
          )}
        </div>
      </aside>

      <main style={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <Toolbar mode={mode} setMode={setMode}
                 scopeOptions={scopeOptions} onScopeChange={onScopeChange} />
        <div style={{ flex: 1, overflowY: 'auto', padding: 14 }}>
          {isEmpty ? (
            <div style={{
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              height: '100%', color: 'var(--text-mute)', fontSize: 13,
            }}>
              No diff yet.
            </div>
          ) : files.map(file => (
            <div key={file.path}
                 ref={el => { fileRefs.current[file.path] = el; }}>
              <DiffFile
                file={file}
                mode={mode}
                collapsed={!!collapsed[file.path]}
                onToggle={() => setCollapsed(c => ({ ...c, [file.path]: !c[file.path] }))}
              />
            </div>
          ))}
        </div>
      </main>
    </div>
  );
}

// ----------------------------------------------------------------- Toolbar

function Toolbar({ mode, setMode, scopeOptions, onScopeChange }) {
  return (
    <div style={{
      height: 38, display: 'flex', alignItems: 'center',
      padding: '0 12px', gap: 8,
      borderBottom: '0.5px solid var(--border)',
      background: 'var(--bg-pane)',
    }}>
      {scopeOptions.branchEnabled && (
        <SegmentedControl
          options={[
            { value: 'branch', label: 'branch' },
            { value: 'uncommitted', label: 'uncommitted' },
          ]}
          value={scopeOptions.selected}
          onChange={onScopeChange}
        />
      )}
      <div style={{ flex: 1 }} />
      <SegmentedControl
        options={[
          { value: 'split', label: 'split' },
          { value: 'unified', label: 'unified' },
        ]}
        value={mode}
        onChange={setMode}
      />
    </div>
  );
}

function SegmentedControl({ options, value, onChange }) {
  return (
    <div style={{
      display: 'flex', padding: 2, flexShrink: 0,
      background: 'var(--bg-pane-soft)',
      border: '0.5px solid var(--border)',
      borderRadius: 7,
    }}>
      {options.map(o => (
        <button key={o.value}
                onClick={() => onChange(o.value)}
                style={{
                  padding: '3px 9px', fontSize: 11, fontWeight: 500,
                  color: value === o.value ? 'var(--text)' : 'var(--text-mute)',
                  background: value === o.value ? 'var(--bg-elev)' : 'transparent',
                  border: 'none', borderRadius: 5, cursor: 'pointer',
                  fontFamily: 'var(--font-sans)', textTransform: 'capitalize',
                  boxShadow: value === o.value ? '0 0.5px 2px rgba(0,0,0,0.1)' : 'none',
                }}>
          {o.label}
        </button>
      ))}
    </div>
  );
}
