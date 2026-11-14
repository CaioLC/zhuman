/* The scene engine the ambience prototypes share (arrival.html, shelter.html).

   A scene is a grid of cells, one glyph and one ink each, rebuilt every tick: a fixed
   backdrop copied in, then props, actors and particles written over it with put() and
   stamp(). Every random choice comes from a seeded generator, so a scene is the same on
   every run.

   The page supplies #stage, #scene, #cap-1, #cap-2 and #replay, and calls Scene.run().
   Keys: R or Space replays, Enter or a click on the scene skips to the end.
   `?t=12` freezes the scene at that many seconds, for a still. */

const Scene = (() => {
  // Inks, by class k1..k7 in scene.css: the theme's line, line-2, dim, fg, acc, warn, danger.
  const INK = { faint: 1, far: 2, near: 3, bright: 4, warm: 5, flame: 6, ember: 7 };
  const TICK = 1 / 15;

  function seeded(seed) {
    return () => {
      seed = seed + 0x6D2B79F5 | 0;
      let t = Math.imul(seed ^ seed >>> 15, 1 | seed);
      t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
      return ((t ^ t >>> 14) >>> 0) / 4294967296;
    };
  }

  // A String.raw block, one row per line, without its first and last line breaks.
  function art(raw) {
    return raw.replace(/^\n/, '').replace(/\n$/, '').split('\n');
  }

  function makeGrid(w, h) {
    return { w, h, ch: new Array(w * h).fill(' '), ink: new Uint8Array(w * h) };
  }

  function put(g, x, y, ch, ink) {
    if (x < 0 || x >= g.w || y < 0 || y >= g.h) return;
    g.ch[y * g.w + x] = ch;
    g.ink[y * g.w + x] = ch === ' ' ? 0 : ink;
  }

  // Bottom-aligned on `foot`; a space in the art leaves the cell under it alone. `ink` is one
  // ink or a function of the art's row; `clip` keeps the writes inside {x0, y0, x1, y1}.
  function stamp(g, lines, x, foot, ink, clip) {
    const top = foot - lines.length + 1;
    lines.forEach((line, r) => {
      const k = typeof ink === 'function' ? ink(r) : ink;
      for (let c = 0; c < line.length; c++) {
        const px = x + c, py = top + r;
        if (line[c] === ' ') continue;
        if (clip && (px < clip.x0 || px > clip.x1 || py < clip.y0 || py > clip.y1)) continue;
        put(g, px, py, line[c], k);
      }
    });
  }

  /* run({ width, height, backdrop, reset, step, compose, done, caption, captionClock })
       backdrop        the fixed grid every frame starts from
       reset()         returns a fresh run state
       step(s, dt)     advances it
       compose(s, g)   writes the moving things over the backdrop already in g
       done(s)         true once the scene has played out
       caption         two lines, typed out below the scene
       captionClock(s) seconds since the caption began, negative before it has */
  function run(scene) {
    const sceneEl = document.getElementById('scene');
    const capEls = [document.getElementById('cap-1'), document.getElementById('cap-2')];
    const escape = { '<': '&lt;', '>': '&gt;', '&': '&amp;' };
    const grid = makeGrid(scene.width, scene.height);
    let sim, frozen = false, looping = false, last = 0, owed = 0;

    function paint() {
      const g = grid, w = g.w;
      for (let i = 0; i < g.ch.length; i++) { g.ch[i] = scene.backdrop.ch[i]; g.ink[i] = scene.backdrop.ink[i]; }
      scene.compose(sim, g);

      let html = '';
      for (let y = 0; y < g.h; y++) {
        let text = '', ink = 0;
        const flush = () => {
          if (text) html += ink ? `<span class="k${ink}">${text}</span>` : text;
          text = '';
        };
        for (let x = 0; x < w; x++) {
          const i = y * w + x;
          if (g.ink[i] !== ink) { flush(); ink = g.ink[i]; }
          text += escape[g.ch[i]] || g.ch[i];
        }
        flush();
        html += '\n';
      }
      sceneEl.innerHTML = html;

      const since = scene.captionClock(sim);
      [0, 1.4].forEach((start, n) => {
        const shown = scene.caption[n].slice(0, Math.max(0, Math.floor((since - start) * 18)));
        if (capEls[n].textContent !== shown) capEls[n].textContent = shown;
      });
    }

    function loop(now) {
      if (frozen) { looping = false; return; }
      owed += Math.min(0.25, (now - last) / 1000);
      last = now;
      let stepped = false;
      while (owed >= TICK) { scene.step(sim, TICK); owed -= TICK; stepped = true; }
      if (stepped) paint();
      requestAnimationFrame(loop);
    }

    function runTo(test) {
      for (let n = 0; n < 20000 && !test(); n++) scene.step(sim, TICK);
      paint();
    }

    function play() {
      sim = scene.reset();
      const still = new URLSearchParams(location.search).get('t');
      frozen = still !== null;
      if (frozen) { runTo(() => sim.t >= Number(still)); return; }
      paint();
      last = performance.now();
      owed = 0;
      if (!looping) { looping = true; requestAnimationFrame(loop); }
    }

    document.getElementById('replay').addEventListener('click', play);
    document.getElementById('stage').addEventListener('click', () => runTo(() => scene.done(sim)));
    addEventListener('keydown', (event) => {
      if (event.target.closest('a, button')) return;
      if (event.key === 'r' || event.key === 'R' || event.key === ' ') { event.preventDefault(); play(); }
      if (event.key === 'Enter') runTo(() => scene.done(sim));
    });

    play();
  }

  return { INK, seeded, art, makeGrid, put, stamp, run };
})();
