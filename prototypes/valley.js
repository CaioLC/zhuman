/* The valley the outdoor scenes share (arrival.html, thanks.html): the far range, the near
   hills, the ground, the trees, and the stars over them. Built once from one seed, so it is
   the same place in every scene. Needs scene.js. */

const Valley = (() => {
  const { INK, seeded, art, makeGrid, put, stamp } = Scene;

  const W = 100, H = 32;
  const HORIZON = 21;   // the row the ground line sits on; the ground is every row below

  const BARE_TREE = art(String.raw`
 \   |   /
  \ \|  / _/
 __\ | /_/
    \|/
     |/
     |
     |
    /|\
`);

  const FIR = art(String.raw`
   ^
  /|\
 /_|_\
  /|\
 / | \
/__|__\
   |
`);

  const FAR_FIR = art(String.raw`
 ^
/|\
/|\
 |
`);

  // Each prop stands on a ground row; a lower row is nearer, and is drawn over a higher one.
  const PROPS = [
    { art: FAR_FIR, x: 6, foot: 23, ink: INK.far },
    { art: FIR, x: 12, foot: 25, ink: INK.near },
    { art: FAR_FIR, x: 36, foot: 22, ink: INK.far },
    { art: FAR_FIR, x: 40, foot: 23, ink: INK.far },
    { art: FAR_FIR, x: 92, foot: 22, ink: INK.far },
    { art: BARE_TREE, x: 76, foot: 29, ink: INK.near },
  ];

  // A ridge is a height at every cell edge, each within one of its neighbour. A cell climbs,
  // falls or runs flat between its two edges, and hides whatever stood behind it.
  function ridge(g, edge, ink) {
    for (let x = 0; x < W; x++) {
      const a = edge[x], b = edge[x + 1];
      const row = HORIZON - Math.min(a, b);
      for (let y = row; y <= HORIZON; y++) put(g, x, y, ' ', 0);
      put(g, x, row, b > a ? '/' : b < a ? '\\' : '_', ink);
    }
  }

  function build() {
    const g = makeGrid(W, H);
    const rand = seeded(1848);

    // The far range: straight-sided peaks, each an apex column and a height.
    const peaks = [[9, 5], [21, 9], [31, 6], [45, 4], [62, 11], [73, 6], [87, 8], [98, 4]];
    const far = [];
    for (let j = 0; j <= W; j++) {
      far.push(Math.max(0, ...peaks.map(([c, h]) => h - Math.abs(j - c))));
    }
    ridge(g, far, INK.far);

    // The near hills: low and rolling.
    const near = [];
    for (let j = 0; j <= W; j++) {
      const want = Math.max(0, Math.round(1.1 + 1.4 * Math.sin(j * 0.045 + 2.1) + 0.8 * Math.sin(j * 0.11 + 5)));
      const prev = j ? near[j - 1] : want;
      near.push(Math.max(prev - 1, Math.min(prev + 1, want)));
    }
    ridge(g, near, INK.near);

    // The ground: drifts, and what little grows on it.
    for (let n = 0; n < 9; n++) {
      const y = HORIZON + 2 + Math.floor(rand() * (H - HORIZON - 3));
      const x = Math.floor(rand() * W);
      const len = 4 + Math.floor(rand() * 9);
      for (let i = 0; i < len; i++) if (rand() < 0.7) put(g, x + i, y, '_', INK.faint);
    }
    const tufts = ['.', '.', '.', ',', "'", '"'];
    for (let y = HORIZON + 1; y < H; y++) {
      for (let x = 0; x < W; x++) {
        if (rand() < 0.035) put(g, x, y, tufts[Math.floor(rand() * tufts.length)], INK.far);
      }
    }

    // The stars: thicker toward the top, none below the skyline or behind a tree. Most are
    // faint, a few are bright, and each twinkles to its own period.
    const stars = [];
    for (let x = 0; x < W; x++) {
      const skyline = HORIZON - Math.max(far[x], far[x + 1], near[x], near[x + 1]);
      for (let y = 0; y < skyline; y++) {
        if (rand() >= 0.04 * (1 - 0.6 * y / HORIZON)) continue;
        const pick = rand(), period = 1.5 + rand() * 3.5, phase = rand() * Math.PI * 2;
        const hidden = PROPS.some((p) => x >= p.x && x < p.x + p.art[0].length + 4 && y > p.foot - p.art.length && y <= p.foot);
        if (!hidden) stars.push({ x, y, size: pick < 0.7 ? 0 : pick < 0.94 ? 1 : 2, period, phase });
      }
    }
    return { grid: g, stars };
  }

  const { grid: BACKDROP, stars: STARS } = build();

  // The sky `t` seconds in.
  function drawStars(g, t) {
    for (const star of STARS) {
      const glow = Math.sin(t * 2 * Math.PI / star.period + star.phase);
      if (star.size === 0) put(g, star.x, star.y, '.', glow > 0.2 ? INK.far : INK.faint);
      else if (star.size === 1) put(g, star.x, star.y, '·', glow > 0.2 ? INK.near : INK.far);
      else put(g, star.x, star.y, glow > 0.5 ? '*' : glow > -0.3 ? '+' : '·', glow > -0.3 ? INK.near : INK.far);
    }
  }

  // The trees, as things to draw in ground-row order beside a scene's own.
  function props(g) {
    return PROPS.map((p) => ({ foot: p.foot, draw: () => stamp(g, p.art, p.x, p.foot, p.ink) }));
  }

  return { W, H, HORIZON, BACKDROP, drawStars, props };
})();
