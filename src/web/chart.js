export const CAPACITY = 300;

const PAD_RIGHT = 70;
const PAD_Y = 6;

function css(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

export function niceCeil(x) {
  if (x <= 0) return 1;
  const exp = Math.pow(10, Math.floor(Math.log10(x)));
  const f = x / exp;
  const nice = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10;
  return nice * exp;
}

export class StripChart {
  constructor(el, opts) {
    this.opts = opts;
    this.data = opts.series.map(() => []);
    this.canvas = document.createElement("canvas");
    this.canvas.setAttribute("aria-hidden", "true");
    el.append(this.canvas);
    this.ro = new ResizeObserver(() => this.draw());
    this.ro.observe(el);
  }

  setData(arrays) {
    this.data = arrays.map((a) => a.slice(-CAPACITY));
    this.draw();
  }

  draw() {
    const { canvas, opts } = this;
    const dpr = window.devicePixelRatio || 1;
    const w = canvas.clientWidth;
    const h = canvas.clientHeight;
    if (w === 0 || h === 0) return;
    if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(h * dpr);
    }
    const ctx = canvas.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, w, h);

    let max = opts.max;
    if (max === undefined) {
      let peak = 0;
      for (const s of this.data) for (const v of s) if (v > peak) peak = v;
      max = niceCeil(Math.max(peak * 1.1, opts.minMax || 1));
    }

    const plotW = w - PAD_RIGHT;
    const plotH = h - PAD_Y * 2;
    const y = (v) => PAD_Y + plotH - (Math.min(v, max) / max) * plotH;

    ctx.font = "11px " + getComputedStyle(document.body).fontFamily;
    ctx.textBaseline = "middle";
    ctx.textAlign = "left";
    ctx.lineWidth = 1;
    for (const f of [1, 0.5, 0]) {
      const gy = Math.round(y(max * f)) + 0.5;
      ctx.strokeStyle = css("--rule");
      ctx.beginPath();
      ctx.moveTo(0, gy);
      ctx.lineTo(plotW, gy);
      ctx.stroke();
      ctx.fillStyle = css("--muted");
      const ty = Math.min(Math.max(gy, 7), h - 7);
      ctx.fillText(opts.label(max * f), plotW + 8, ty);
    }

    const step = plotW / (CAPACITY - 1);
    this.data.forEach((series, si) => {
      if (series.length < 2) return;
      const color = css("--" + opts.series[si].color);
      const x0 = plotW - (series.length - 1) * step;
      ctx.beginPath();
      series.forEach((v, i) => {
        const px = x0 + i * step;
        if (i === 0) ctx.moveTo(px, y(v));
        else ctx.lineTo(px, y(v));
      });
      ctx.strokeStyle = color;
      ctx.lineWidth = 1.6;
      ctx.lineJoin = "round";
      ctx.stroke();
      if (si === 0) {
        ctx.lineTo(plotW, PAD_Y + plotH);
        ctx.lineTo(x0, PAD_Y + plotH);
        ctx.closePath();
        ctx.globalAlpha = 0.1;
        ctx.fillStyle = color;
        ctx.fill();
        ctx.globalAlpha = 1;
      }
    });
  }
}
