// Inline SVG icons. Same set the design uses, drawn at 16x16 viewBox.
// Render via `<Icon name="..." size={N} />`.

export function Icon({ name, size = 14, style }) {
  const path = ICONS[name];
  if (!path) return null;
  return (
    <svg
      viewBox="0 0 16 16"
      width={size}
      height={size}
      style={{ display: 'inline-block', verticalAlign: 'middle', ...style }}
    >
      {path}
    </svg>
  );
}

const ICONS = {
  chevronRight: (
    <path d="M6 4l4 4-4 4" fill="none" stroke="currentColor"
          strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
  ),
  chevronDown: (
    <path d="M4 6l4 4 4-4" fill="none" stroke="currentColor"
          strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
  ),
  folder: (
    <path d="M2 5a1 1 0 0 1 1-1h3l1.5 1.5H13a1 1 0 0 1 1 1V12a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5z"
          fill="none" stroke="currentColor" strokeWidth="1.4" />
  ),
  folderOpen: (
    <g fill="none" stroke="currentColor" strokeWidth="1.4">
      <path d="M2 5a1 1 0 0 1 1-1h3l1.5 1.5H13a1 1 0 0 1 1 1V7H2V5z" />
      <path d="M2 7h12l-1 5.2a1 1 0 0 1-1 0.8H4a1 1 0 0 1-1-0.8L2 7z" />
    </g>
  ),
  file: (
    <g fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinejoin="round">
      <path d="M4 2h6l3 3v9a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1z" />
      <path d="M10 2v3h3" />
    </g>
  ),
  diff: (
    <g fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round">
      <path d="M5 3v3" /><path d="M3.5 4.5h3" /><path d="M5 10v3" />
      <path d="M3.5 12.5l3-3" /><path d="M11 3l-3 3" /><path d="M11 6V3h-3" />
      <path d="M8 13l3-3" /><path d="M11 13v-3h-3" />
    </g>
  ),
  reload: (
    <g fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3.5 4.5A5.5 5.5 0 1 1 2.5 8.5" />
      <path d="M5.5 4.5h-2v-2" />
    </g>
  ),
};
