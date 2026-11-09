import { StripChart } from "./chart.js";
import { bytes, bytesText, duration, level, percent, rate, rateText } from "./format.js";

// Tiny DOM builder. Strings become text nodes, never HTML, so nothing from the
// server can inject markup.
export function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === false || v === null || v === undefined) continue;
    if (k === "class") el.className = v;
    else el.setAttribute(k, v === true ? "" : String(v));
  }
  for (const kid of kids.flat()) {
    if (kid === null || kid === undefined || kid === false) continue;
    el.append(kid);
  }
  return el;
}

function setValue(el, value, unit) {
  el.textContent = value;
  if (unit) el.append(h("small", {}, unit));
}

// ---------------------------------------------------------------- overview

function channel(name, chartOpts) {
  const value = h("div", { class: "channel-value" });
  const sub = h("div", { class: "channel-sub" });
  const chartEl = h("div", { class: "chart" });
  const root = h(
    "section",
    { class: "channel", "aria-label": name },
    h("div", { class: "channel-head" }, h("div", { class: "channel-name" }, name), value, sub),
    h("div", {}, chartEl, h("div", { class: "chart-axis" }, h("span", {}, "10 min ago"), h("span", {}, "now"))),
  );
  return { root, value, sub, chart: new StripChart(chartEl, chartOpts) };
}

function netTotals(snap) {
  let rx = 0, tx = 0, rxBytes = 0, txBytes = 0;
  for (const i of snap.network) {
    if (i.name === "lo") continue;
    rx += i.rx_bps;
    tx += i.tx_bps;
    rxBytes += i.rx_bytes;
    txBytes += i.tx_bytes;
  }
  return { rx, tx, rxBytes, txBytes };
}

export function overviewView() {
  const cpu = channel("Processor", { series: [{ color: "primary" }], max: 100, label: (v) => Math.round(v) + "%" });
  const mem = channel("Memory", { series: [{ color: "secondary" }], max: 100, label: (v) => Math.round(v) + "%" });
  const rx = channel("Network in", { series: [{ color: "primary" }], minMax: 10 * 1024, label: (v) => rateText(v) });
  const tx = channel("Network out", { series: [{ color: "secondary" }], minMax: 10 * 1024, label: (v) => rateText(v) });

  const coresBox = h("div", { class: "cores" });
  const coresBlock = h("section", { class: "block", hidden: true }, h("h2", {}, "Cores"), coresBox);
  const tempsBox = h("div", { class: "temps" });
  const tempsBlock = h("section", { class: "block", hidden: true }, h("h2", {}, "Temperatures"), tempsBox);

  const el = h("div", {}, cpu.root, mem.root, rx.root, tx.root, coresBlock, tempsBlock);

  return {
    el,
    update(snap, hist) {
      setValue(cpu.value, percent(snap.cpu.percent), "%");
      cpu.sub.textContent = `${snap.cpu.cores.length} cores, load ${snap.load.map((l) => l.toFixed(2)).join("  ")}`;
      cpu.chart.setData([hist.cpu]);

      const memPct = snap.memory.total_kb ? (snap.memory.used_kb / snap.memory.total_kb) * 100 : 0;
      setValue(mem.value, percent(memPct), "%");
      let memSub = `${bytesText(snap.memory.used_kb * 1024)} of ${bytesText(snap.memory.total_kb * 1024)}`;
      if (snap.memory.swap_total_kb > 0) memSub += `, swap ${bytesText(snap.memory.swap_used_kb * 1024)}`;
      mem.sub.textContent = memSub;
      mem.chart.setData([hist.mem]);

      const net = netTotals(snap);
      const r = rate(net.rx), t = rate(net.tx);
      setValue(rx.value, r.value, r.unit);
      rx.sub.textContent = `${bytesText(net.rxBytes)} received since boot`;
      rx.chart.setData([hist.rx]);
      setValue(tx.value, t.value, t.unit);
      tx.sub.textContent = `${bytesText(net.txBytes)} sent since boot`;
      tx.chart.setData([hist.tx]);

      // Cores: rebuild only when the count changes, otherwise patch in place.
      const cores = snap.cpu.cores;
      coresBlock.hidden = cores.length === 0;
      if (coresBox.children.length !== cores.length) {
        coresBox.replaceChildren(
          ...cores.map((_, i) =>
            h(
              "div",
              { class: "core" },
              h("div", { class: "core-top" }, h("span", {}, "Core " + i), h("b", {}, "")),
              h("div", { class: "bar" }, h("i", {})),
            ),
          ),
        );
      }
      cores.forEach((p, i) => {
        const node = coresBox.children[i];
        node.querySelector("b").textContent = percent(p) + "%";
        node.querySelector(".bar").dataset.level = level(p);
        node.querySelector("i").style.width = Math.min(p, 100) + "%";
      });

      tempsBlock.hidden = snap.temperatures.length === 0;
      tempsBox.replaceChildren(
        ...snap.temperatures.map((t) => h("div", { class: "temp" }, h("b", {}, t.celsius.toFixed(0) + "°C"), h("span", {}, t.label))),
      );
    },
  };
}

// ---------------------------------------------------------------- storage

export function storageView() {
  const body = h("tbody");
  const empty = h("p", { class: "empty", hidden: true }, "No disk-backed filesystems are mounted.");
  const table = h(
    "table",
    {},
    h("thead", {}, h("tr", {}, h("th", {}, "Mount"), h("th", { class: "usage" }, "Used"), h("th", { class: "num" }, "Free"), h("th", { class: "num" }, "Size"))),
    body,
  );
  const el = h("div", {}, table, empty);
  return {
    el,
    update(snap) {
      empty.hidden = snap.storage.length > 0;
      table.hidden = snap.storage.length === 0;
      body.replaceChildren(
        ...snap.storage.map((m) => {
          const pct = m.total_bytes ? (m.used_bytes / m.total_bytes) * 100 : 0;
          const bar = h("div", { class: "bar" }, h("i", {}));
          bar.dataset.level = level(pct);
          bar.firstChild.style.width = Math.min(pct, 100) + "%";
          return h(
            "tr",
            {},
            h("td", {}, h("div", { class: "mount-name" }, m.mount), h("div", { class: "mount-dev" }, `${m.device}, ${m.fstype}`)),
            h("td", { class: "usage" }, m.total_bytes === undefined ? "unavailable" : `${bytesText(m.used_bytes)} (${percent(pct)}%)`, bar),
            h("td", { class: "num" }, m.avail_bytes === undefined ? "-" : bytesText(m.avail_bytes)),
            h("td", { class: "num" }, m.total_bytes === undefined ? "-" : bytesText(m.total_bytes)),
          );
        }),
      );
    },
  };
}

// ---------------------------------------------------------------- network

export function networkView() {
  const body = h("tbody");
  const el = h(
    "table",
    {},
    h(
      "thead",
      {},
      h("tr", {}, h("th", {}, "Interface"), h("th", { class: "num" }, "In"), h("th", { class: "num" }, "Out"), h("th", { class: "num" }, "Received"), h("th", { class: "num" }, "Sent"), h("th", { class: "num" }, "Errors")),
    ),
    body,
  );
  return {
    el,
    update(snap) {
      body.replaceChildren(
        ...snap.network.map((i) =>
          h(
            "tr",
            {},
            h("td", {}, h("div", { class: "mount-name" }, i.name)),
            h("td", { class: "num" }, rateText(i.rx_bps)),
            h("td", { class: "num" }, rateText(i.tx_bps)),
            h("td", { class: "num" }, bytesText(i.rx_bytes)),
            h("td", { class: "num" }, bytesText(i.tx_bytes)),
            h("td", { class: "num" }, String(i.rx_errors + i.tx_errors)),
          ),
        ),
      );
    },
  };
}

export const views = { overview: overviewView, storage: storageView, network: networkView };
