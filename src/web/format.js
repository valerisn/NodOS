// Number formatting. Binary units (1024) for bytes because that is what df and
// free show, and a dashboard that disagrees with them looks broken.
const UNITS = ["B", "KB", "MB", "GB", "TB", "PB"];

export function bytes(n) {
  if (!Number.isFinite(n) || n < 0) return { value: "-", unit: "" };
  let i = 0;
  while (n >= 1024 && i < UNITS.length - 1) {
    n /= 1024;
    i++;
  }
  const digits = n >= 100 || i === 0 ? 0 : n >= 10 ? 1 : 2;
  return { value: n.toFixed(digits), unit: UNITS[i] };
}

export function bytesText(n) {
  const b = bytes(n);
  return b.unit ? `${b.value} ${b.unit}` : b.value;
}

export function rate(bps) {
  const b = bytes(bps);
  return { value: b.value, unit: b.unit ? `${b.unit}/s` : "" };
}

export function rateText(bps) {
  const r = rate(bps);
  return r.unit ? `${r.value} ${r.unit}` : r.value;
}

export function percent(x) {
  return Number.isFinite(x) ? x.toFixed(x >= 10 ? 0 : 1) : "-";
}

export function duration(seconds) {
  const s = Math.floor(seconds);
  const d = Math.floor(s / 86400);
  const h = Math.floor((s % 86400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

// green, amber, red thresholds for storage and per-core bars
export function level(pct) {
  if (pct >= 90) return "crit";
  if (pct >= 75) return "warn";
  return "ok";
}
