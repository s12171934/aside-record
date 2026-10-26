// 녹화 에이전트가 page.evaluate(fakeMic, { mode, url }) 로 실행하는 가짜 마이크 주입 함수.
// mode: 'voice'(url 의 음원을 MediaRecorder.start 순간에 재생) | 'silent'(이득 0 스트림).
// 확인: document.documentElement.dataset.fakeMicCalls(getUserMedia 가로챈 수)·fakeMicPlays(음원 재생 수).
async ({ mode, url }) => {
  const code = `(() => {
    const mode = ${JSON.stringify(mode)};
    const url = ${JSON.stringify(url || '')};
    const md = navigator.mediaDevices;
    if (!window.__origGUM) window.__origGUM = md.getUserMedia.bind(md);
    if (!window.__origRecStart) window.__origRecStart = MediaRecorder.prototype.start;
    const bufPromise = mode === 'voice' ? fetch(url).then(r => r.arrayBuffer()) : Promise.resolve(null);
    window.__fakeMicStarters = new WeakMap();
    md.getUserMedia = async (c) => {
      if (!c || !c.audio) return window.__origGUM(c);
      const ds = document.documentElement.dataset; ds.fakeMicCalls = String(Number(ds.fakeMicCalls || 0) + 1);
      const buf = await bufPromise;
      const ctx = new AudioContext();
      const dst = ctx.createMediaStreamDestination();
      const o = ctx.createOscillator(); const g = ctx.createGain(); g.gain.value = 0; o.connect(g); g.connect(dst); o.start();
      if (buf) {
        const ab = await ctx.decodeAudioData(buf.slice(0));
        window.__fakeMicStarters.set(dst.stream, () => { ctx.resume(); const src = ctx.createBufferSource(); src.buffer = ab; src.connect(dst); src.start(ctx.currentTime + 0.3); ds.fakeMicPlays = String(Number(ds.fakeMicPlays || 0) + 1); });
      }
      return dst.stream;
    };
    MediaRecorder.prototype.start = function (...args) {
      const starter = window.__fakeMicStarters.get(this.stream);
      if (starter) starter();
      return window.__origRecStart.apply(this, args);
    };
    document.documentElement.dataset.fakeMic = mode;
  })();`;
  const s = document.createElement('script'); s.textContent = code; document.documentElement.appendChild(s); s.remove();
  return 'fake mic ready: ' + document.documentElement.dataset.fakeMic;
}
