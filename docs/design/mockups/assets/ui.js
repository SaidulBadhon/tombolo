// Shared helpers for the Tombolo mockups: an inline icon sprite, the brand mark,
// a fake (non-functional) QR code, and a reusable Android home screen.

const ICONS = {
  home: '<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
  back: '<path d="M15 18l-6-6 6-6"/>',
  recents: '<rect x="5" y="5" width="14" height="14" rx="3"/>',
  chat: '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
  phone: '<path d="M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1.9.4 1.8.7 2.7a2 2 0 0 1-.5 2.1L8 9.8a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.4c.9.3 1.8.6 2.7.7a2 2 0 0 1 1.7 2z"/>',
  camera: '<path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3z"/><circle cx="12" cy="13" r="3"/>',
  image: '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="9" cy="9" r="2"/><path d="m21 15-3.1-3.1a2 2 0 0 0-2.8 0L6 21"/>',
  map: '<path d="M14.1 5.1 9.9 2.9a2 2 0 0 0-1.8 0L3.6 5.2A1 1 0 0 0 3 6.1v13.3a1 1 0 0 0 1.4.9l3.7-1.9a2 2 0 0 1 1.8 0l4.2 2.2a2 2 0 0 0 1.8 0l4.5-2.3a1 1 0 0 0 .6-.9V4.1a1 1 0 0 0-1.4-.9l-3.7 1.9a2 2 0 0 1-1.8 0z"/><path d="M15 5.8v15M9 3.2v15"/>',
  music: '<path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/>',
  calendar: '<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>',
  mail: '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="m22 7-8.97 5.7a1.94 1.94 0 0 1-2.06 0L2 7"/>',
  globe: '<circle cx="12" cy="12" r="10"/><path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20M2 12h20"/>',
  sliders: '<path d="M4 21v-7M4 10V3M12 21v-9M12 8V3M20 21v-5M20 12V3M1 14h6M9 8h6M17 16h6"/>',
  note: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4z"/>',
  cloud: '<path d="M17.5 19H9a7 7 0 1 1 6.7-9h1.8a4.5 4.5 0 1 1 0 9z"/>',
  folder: '<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.7-.9l-.8-1.2A2 2 0 0 0 7.9 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2z"/>',
  wallet: '<rect x="2" y="6" width="20" height="14" rx="2"/><path d="M2 10h20M16 15h2"/>',
  heart: '<path d="M19 14c1.5-1.5 3-3.2 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.8 0-3 .5-4.5 2-1.5-1.5-2.7-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4 3 5.5l7 7z"/>',
  mic: '<rect x="9" y="2" width="6" height="12" rx="3"/><path d="M19 10v2a7 7 0 0 1-14 0v-2M12 19v3"/>',
  search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
  wifi: '<path d="M12 20h.01M2 8.8a15 15 0 0 1 20 0M5 12.9a10 10 0 0 1 14 0M8.5 16.4a5 5 0 0 1 7 0"/>',
  usb: '<circle cx="10" cy="7" r="1"/><circle cx="4" cy="20" r="1"/><path d="M4.7 19.3 19 5"/><path d="m21 3-3 1 2 2Z"/><path d="M9.26 7.68 5 12l2 5"/><path d="m10 14 5 2 3.5-3.5"/><path d="m18 12 1-1 1 1-1 1Z"/>',
  battery: '<rect x="2" y="7" width="17" height="10" rx="2.5"/><path d="M22 11v2"/><rect x="4.2" y="9.2" width="10" height="5.6" rx="1" fill="currentColor" stroke="none"/>',
  signal: '<path d="M2 20h.01M7 20v-4M12 20v-8M17 20V8M22 4v16"/>',
  bell: '<path d="M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9"/><path d="M10.3 21a1.94 1.94 0 0 0 3.4 0"/>',
  clipboard: '<rect x="8" y="2" width="8" height="4" rx="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/>',
  upload: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M17 8l-5-5-5 5M12 3v12"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4M7 10l5 5 5-5M12 15V3"/>',
  rotate: '<path d="M21 12a9 9 0 1 1-9-9c2.5 0 4.8 1 6.5 2.7L21 8"/><path d="M21 3v5h-5"/>',
  volume: '<path d="M11 5 6 9H2v6h4l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M19 5a10 10 0 0 1 0 14"/>',
  more: '<circle cx="12" cy="12" r="1.2"/><circle cx="19" cy="12" r="1.2"/><circle cx="5" cy="12" r="1.2"/>',
  lock: '<rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  shield: '<path d="M20 13c0 5-3.5 7.5-7.7 9a1 1 0 0 1-.7 0C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.2-2.7a1.2 1.2 0 0 1 1.5 0C14.5 3.8 17 5 19 5a1 1 0 0 1 1 1z"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  x: '<path d="M18 6 6 18M6 6l12 12"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',
  laptop: '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M2 20h20"/>',
  smartphone: '<rect x="5" y="2" width="14" height="20" rx="3"/><path d="M11 18h2"/>',
  qr: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM21 14v.01M14 21h.01M17 21h4v-4"/>',
  file: '<path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/>',
  link: '<path d="M10 13a5 5 0 0 0 7.5.5l3-3a5 5 0 0 0-7-7l-1.7 1.7"/><path d="M14 11a5 5 0 0 0-7.5-.5l-3 3a5 5 0 0 0 7 7l1.7-1.7"/>',
  zap: '<path d="M4 14a1 1 0 0 1-.8-1.6l9.9-10.2a.5.5 0 0 1 .9.5l-1.9 6A1 1 0 0 0 13 10h7a1 1 0 0 1 .8 1.6l-9.9 10.2a.5.5 0 0 1-.9-.5l1.9-6A1 1 0 0 0 11 14z"/>',
  terminal: '<path d="m4 17 6-6-6-6M12 19h8"/>',
  eye: '<path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  chevron: '<path d="m9 18 6-6-6-6"/>',
  chevdown: '<path d="m6 9 6 6 6-6"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  copy: '<rect x="8" y="8" width="14" height="14" rx="2"/><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2"/>',
  send: '<path d="m22 2-7 20-4-9-9-4z"/><path d="M22 2 11 13"/>',
  fingerprint: '<path d="M12 10a2 2 0 0 0-2 2c0 1.02-.1 2.51-.26 4"/><path d="M14 13.12c0 2.38 0 6.38-1 8.88"/><path d="M17.29 21.02c.12-.6.43-2.3.5-3.02"/><path d="M2 12a10 10 0 0 1 18-6"/><path d="M2 16h.01"/><path d="M21.8 16c.2-2 .131-5.354 0-6"/><path d="M5 19.5C5.5 18 6 15 6 12a6 6 0 0 1 .34-2"/><path d="M8.65 22c.21-.66.45-1.32.57-2"/><path d="M9 6.8a6 6 0 0 1 9 5.2v2"/>',
  pause: '<rect x="6" y="4" width="4" height="16" rx="1"/><rect x="14" y="4" width="4" height="16" rx="1"/>',
  play: '<path d="M7 4v16l13-8z"/>',
  skip: '<path d="m5 4 10 8-10 8zM19 5v14"/>',
  swap: '<path d="M8 3 4 7l4 4M4 7h16M16 21l4-4-4-4M20 17H4"/>',
  moon: '<path d="M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z"/>',
  maximize: '<path d="M8 3H5a2 2 0 0 0-2 2v3M21 8V5a2 2 0 0 0-2-2h-3M3 16v3a2 2 0 0 0 2 2h3M16 21h3a2 2 0 0 0 2-2v-3"/>',
  keyboard: '<rect x="2" y="4" width="20" height="16" rx="2"/><path d="M6 8h.01M10 8h.01M14 8h.01M18 8h.01M8 12h.01M12 12h.01M16 12h.01M7 16h10"/>',
  scan: '<path d="M3 7V5a2 2 0 0 1 2-2h2M17 3h2a2 2 0 0 1 2 2v2M21 17v2a2 2 0 0 1-2 2h-2M7 21H5a2 2 0 0 1-2-2v-2"/>',
  bluetooth: '<path d="m7 7 10 10-5 5V2l5 5L7 17"/>',
  info: '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
  alert: '<path d="m21.7 18-8-14a2 2 0 0 0-3.5 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.7-3"/><path d="M12 9v4M12 17h.01"/>',
  gauge: '<path d="m12 14 4-4"/><path d="M3.34 19a10 10 0 1 1 17.32 0"/>',
  arrowup: '<path d="M12 19V5M5 12l7-7 7 7"/>',
  sparkle: '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5 18 18M6 18l2.5-2.5M15.5 8.5 18 6"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
  cast: '<path d="M2 8V6a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v12a2 2 0 0 1-2 2h-6"/><path d="M2 12a9 9 0 0 1 8 8M2 16a5 5 0 0 1 4 4M2 20h.01"/>',
  pin: '<path d="M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 0 1 16 0z"/><circle cx="12" cy="10" r="3"/>',
  nav: '<path d="m3 11 19-9-9 19-2-8z"/>',
  headphones: '<path d="M3 14h3a2 2 0 0 1 2 2v3a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-7a9 9 0 0 1 18 0v7a2 2 0 0 1-2 2h-1a2 2 0 0 1-2-2v-3a2 2 0 0 1 2-2h3"/>',
  gamepad: '<path d="M6 12h4M8 10v4M15 13h.01M18 11h.01"/><rect x="2" y="6" width="20" height="12" rx="6"/>',
  hotspot: '<circle cx="12" cy="12" r="2"/><path d="M16.2 7.8a6 6 0 0 1 0 8.4M7.8 16.2a6 6 0 0 1 0-8.4M19 5a10 10 0 0 1 0 14M5 19A10 10 0 0 1 5 5"/>',
};

// The brand mark: a phone stepping into a window — two overlapping rounded rects.
const LOGO_SVG = `<svg viewBox="0 0 48 48" fill="none">
  <rect x="5" y="12" width="28" height="21" rx="4.5" stroke="#fff" stroke-width="3.2" opacity=".95"/>
  <rect x="25" y="8" width="17" height="31" rx="5" fill="#fff"/>
  <rect x="28.5" y="12" width="10" height="21" rx="2" fill="url(#lgx)"/>
  <defs><linearGradient id="lgx" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2fd38f"/><stop offset="1" stop-color="#3b7cf6"/></linearGradient></defs>
</svg>`;

function icon(name, cls = '') {
  return `<svg class="i ${cls}" viewBox="0 0 24 24">${ICONS[name] || ''}</svg>`;
}

// Deterministic fake QR code (visual only — encodes nothing).
function qrSVG(size = 220, seed = 7, color = '#111') {
  const n = 29;
  let s = seed;
  const rnd = () => ((s = (s * 1103515245 + 12345) & 0x7fffffff) / 0x7fffffff);
  const m = Array.from({ length: n }, () => Array(n).fill(0));
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) m[y][x] = rnd() > 0.52 ? 1 : 0;
  const finder = (ox, oy) => {
    for (let y = -1; y < 8; y++) for (let x = -1; x < 8; x++) {
      const X = ox + x, Y = oy + y;
      if (X < 0 || Y < 0 || X >= n || Y >= n) continue;
      const edge = x === 0 || x === 6 || y === 0 || y === 6;
      const core = x >= 2 && x <= 4 && y >= 2 && y <= 4;
      m[Y][X] = x >= 0 && x <= 6 && y >= 0 && y <= 6 && (edge || core) ? 1 : 0;
    }
  };
  finder(0, 0); finder(n - 7, 0); finder(0, n - 7);
  for (let y = -2; y <= 2; y++) for (let x = -2; x <= 2; x++) {
    const ring = Math.max(Math.abs(x), Math.abs(y));
    m[n - 9 + y][n - 9 + x] = ring === 1 ? 0 : 1;
  }
  for (let i = 8; i < n - 8; i++) { m[6][i] = i % 2 === 0 ? 1 : 0; m[i][6] = i % 2 === 0 ? 1 : 0; }
  // clear a centre patch for the logo
  const c0 = 11, c1 = 17;
  for (let y = c0; y <= c1; y++) for (let x = c0; x <= c1; x++) m[y][x] = 0;
  const cell = size / n;
  let rects = '';
  for (let y = 0; y < n; y++) for (let x = 0; x < n; x++) {
    if (m[y][x]) rects += `<rect x="${(x * cell).toFixed(2)}" y="${(y * cell).toFixed(2)}" width="${(cell + 0.3).toFixed(2)}" height="${(cell + 0.3).toFixed(2)}" rx="${(cell * 0.18).toFixed(2)}"/>`;
  }
  const lc = (c0 + 0.5) * cell, ls = (c1 - c0) * cell;
  return `<svg width="${size}" height="${size}" viewBox="0 0 ${size} ${size}"><g fill="${color}">${rects}</g>
    <rect x="${lc}" y="${lc}" width="${ls}" height="${ls}" rx="${ls * 0.24}" fill="url(#qrg)"/>
    <g transform="translate(${lc + ls * 0.16} ${lc + ls * 0.16}) scale(${(ls * 0.68) / 48})">${LOGO_SVG.replace(/<\/?svg[^>]*>/g, '').replace(/lgx/g, 'lgq')}</g>
    <defs><linearGradient id="qrg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#2fd38f"/><stop offset=".5" stop-color="#1fb8c9"/><stop offset="1" stop-color="#3b7cf6"/></linearGradient></defs></svg>`;
}

// A Pixel-style Android home screen used inside the mirrored phone windows.
function homeScreenHTML() {
  const a = (cls, ic, label) => `<div class="app"><div class="ic ${cls}">${icon(ic)}</div>${label}</div>`;
  return `<div class="home">
    <div class="and-status">10:24<div class="r">${icon('signal')}${icon('wifi')}${icon('battery')}<span style="font-size:12px">87%</span></div></div>
    <div class="glance"><div class="d">Sunday, Oct 25</div><div class="w">${icon('cloud', 'sm')} 18°C · Light rain at 4 PM</div></div>
    <div class="widget" style="display:flex;gap:12px;align-items:center">
      <div style="width:56px;height:56px;border-radius:14px;background:linear-gradient(135deg,#8b5cf6,#ec4899)"></div>
      <div style="flex:1;min-width:0"><div style="font-weight:600;font-size:14px;color:#2b2236">Midnight Drive</div><div style="font-size:12px;color:#5a5468;margin-top:2px">Neon Harbor</div>
        <div style="height:4px;border-radius:4px;background:rgba(0,0,0,.12);margin-top:10px"><div style="width:42%;height:100%;border-radius:4px;background:#2b2236"></div></div></div>
      <div style="width:40px;height:40px;border-radius:50%;background:#2b2236;color:#fff;display:grid;place-items:center">${icon('pause', 'sm')}</div>
    </div>
    <div class="app-grid" style="margin-top:34px">
      ${a('c-cal', 'calendar', 'Calendar')}${a('c-photo', 'image', 'Gallery')}${a('c-map', 'map', 'Maps')}${a('c-weather', 'cloud', 'Weather')}
      ${a('c-music', 'music', 'Music')}${a('c-note', 'note', 'Notes')}${a('c-files', 'folder', 'Files')}${a('c-set', 'sliders', 'Settings')}
    </div>
    <div class="dock-row app-grid">${a('c-phone', 'phone', '')}${a('c-msg', 'chat', '')}${a('c-web', 'globe', '')}${a('c-cam', 'camera', '')}</div>
    <div class="search-pill">${icon('search')}<span>Search</span><span style="margin-left:auto">${icon('mic')}</span></div>
    <div class="gesture-bar"></div>
  </div>`;
}

document.addEventListener('DOMContentLoaded', () => {
  document.querySelectorAll('[data-i]').forEach((el) => { el.outerHTML = icon(el.dataset.i, el.className); });
  document.querySelectorAll('.logo').forEach((el) => { if (!el.innerHTML.trim()) el.innerHTML = LOGO_SVG; });
  document.querySelectorAll('[data-qr]').forEach((el) => { el.innerHTML = qrSVG(+el.dataset.qr || 220, +el.dataset.seed || 7); });
  document.querySelectorAll('[data-home]').forEach((el) => { el.innerHTML = homeScreenHTML(); });
});
