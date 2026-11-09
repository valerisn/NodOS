import { get, post } from "./api.js";
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

// ---------------------------------------------------------------- docker

const DOCKER_HINTS = {
  "docker is not reachable": "NodOS cannot reach Docker. Check that the socket exists and that the user running NodOS can read it.",
  "docker integration is turned off": "Docker is turned off in the NodOS config (docker_socket = off).",
};

function stateLevel(state) {
  if (state === "running") return "ok";
  if (state === "exited" || state === "created") return "idle";
  return "warn"; // restarting, paused, dead, removing
}

export function dockerView({ role }) {
  const admin = role === "admin";
  const body = h("tbody");
  const message = h("p", { class: "muted", role: "status" });
  const flash = h("p", { class: "flash", role: "status", hidden: true });
  const table = h(
    "table",
    { hidden: true },
    h("thead", {}, h("tr", {}, h("th", {}, "Container"), h("th", {}, "State"), h("th", {}, "Status"), h("th", { class: "num" }, admin ? "Actions" : ""))),
    body,
  );
  const logTitle = h("h2", {});
  const logPre = h("pre", { class: "logs", tabindex: "0" });
  const logClose = h("button", { type: "button", class: "quiet" }, "Close");
  const logRefresh = h("button", { type: "button", class: "quiet" }, "Refresh");
  const logBlock = h("section", { class: "block", hidden: true }, h("div", { class: "block-head" }, logTitle, h("span", { class: "spacer" }), logRefresh, logClose), logPre);

  let timer = null;
  let busy = false;
  let logRef = null;
  let alive = true;

  function say(text, bad) {
    flash.hidden = !text;
    flash.textContent = text || "";
    flash.dataset.bad = bad ? "1" : "";
  }

  function explain(err) {
    return DOCKER_HINTS[err.message] || err.message;
  }

  async function load() {
    try {
      const d = await get("/docker/containers");
      if (!alive) return;
      message.textContent = d.containers.length === 0 ? "No containers yet." : d.total > d.containers.length ? `Showing ${d.containers.length} of ${d.total} containers.` : "";
      table.hidden = d.containers.length === 0;
      body.replaceChildren(...d.containers.map(row));
    } catch (err) {
      if (!alive) return;
      table.hidden = true;
      body.replaceChildren();
      message.textContent = err.status === 401 ? "Your session ended. Sign in again." : explain(err);
    }
  }

  function button(label, onClick, disabled) {
    const b = h("button", { type: "button", class: "quiet", disabled: disabled ? true : false }, label);
    b.addEventListener("click", onClick);
    return b;
  }

  function row(c) {
    const running = c.state === "running";
    const actions = h("td", { class: "num actions" });
    if (admin) {
      // append(null) would print the word "null", so only pass real nodes.
      actions.append(
        ...[
          button("Logs", () => openLogs(c)),
          running ? button("Restart", () => act(c, "restart")) : button("Start", () => act(c, "start")),
          running ? button("Stop", () => act(c, "stop")) : undefined,
        ].filter(Boolean),
      );
    }
    const dot = h("span", { class: "state", "data-level": stateLevel(c.state) }, c.state);
    return h("tr", {}, h("td", {}, h("div", { class: "mount-name" }, c.name || c.id), h("div", { class: "mount-dev" }, `${c.image}, ${c.id}`)), h("td", {}, dot), h("td", {}, c.status), actions);
  }

  async function act(c, verb) {
    if (busy) return;
    if (verb !== "start" && !confirm(`${verb === "stop" ? "Stop" : "Restart"} ${c.name || c.id}?`)) return;
    busy = true;
    say(`${verb === "stop" ? "Stopping" : verb === "restart" ? "Restarting" : "Starting"} ${c.name}...`);
    try {
      const r = await post(`/docker/containers/${encodeURIComponent(c.id)}/${verb}`);
      const past = { start: "started", stop: "stopped", restart: "restarted" }[verb];
      say(r.result === "unchanged" ? `${c.name} was already ${past === "stopped" ? "stopped" : "running"}.` : `${c.name} ${past}.`);
    } catch (err) {
      say(`Could not ${verb} ${c.name}: ${explain(err)}`, true);
    } finally {
      busy = false;
      await load();
    }
  }

  async function loadLogs() {
    if (!logRef) return;
    try {
      const d = await get(`/docker/containers/${encodeURIComponent(logRef.id)}/logs?tail=200`);
      logPre.textContent = d.lines.length ? d.lines.join("\n") : "No log output.";
      if (d.truncated) logPre.append("\n[older lines cut to fit]");
      logPre.scrollTop = logPre.scrollHeight;
    } catch (err) {
      logPre.textContent = "Could not read logs: " + explain(err);
    }
  }

  function openLogs(c) {
    logRef = c;
    logTitle.textContent = `Logs: ${c.name || c.id}`;
    logPre.textContent = "Loading...";
    logBlock.hidden = false;
    loadLogs();
  }
  logRefresh.addEventListener("click", loadLogs);
  logClose.addEventListener("click", () => {
    logRef = null;
    logBlock.hidden = true;
  });

  const el = h("div", {}, flash, message, table, logBlock);
  return {
    el,
    activate() {
      alive = true;
      load();
      timer = setInterval(load, 5000);
    },
    deactivate() {
      alive = false;
      clearInterval(timer);
    },
    // The container list is polled, not streamed.
    update() {},
  };
}

// ---------------------------------------------------------------- audit

export function auditView({ role }) {
  const body = h("tbody");
  const message = h("p", { class: "muted", role: "status" });
  const table = h(
    "table",
    { hidden: true },
    h("thead", {}, h("tr", {}, h("th", {}, "Time"), h("th", {}, "Who"), h("th", {}, "Action"), h("th", {}, "Target"), h("th", {}, "Result"), h("th", {}, "From"))),
    body,
  );
  let timer = null;
  let alive = true;

  async function load() {
    if (role !== "admin") {
      message.textContent = "The audit log is visible to administrators only.";
      return;
    }
    try {
      const d = await get("/audit?limit=150");
      if (!alive) return;
      message.textContent = d.entries.length === 0 ? "Nothing recorded yet." : "";
      table.hidden = d.entries.length === 0;
      body.replaceChildren(
        ...d.entries.map((e) =>
          h(
            "tr",
            { class: e.ok ? "" : "bad" },
            h("td", { class: "when" }, new Date(e.ts * 1000).toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" })),
            h("td", {}, e.actor),
            h("td", {}, e.action),
            h("td", { class: "mount-dev" }, e.target),
            h("td", {}, e.ok ? "ok" : "failed"),
            h("td", { class: "mount-dev" }, e.ip),
          ),
        ),
      );
    } catch (err) {
      if (!alive) return;
      message.textContent = err.status === 401 ? "Your session ended. Sign in again." : "Could not load the audit log: " + err.message;
    }
  }

  return {
    el: h("div", {}, message, table),
    activate() {
      alive = true;
      load();
      timer = setInterval(load, 10000);
    },
    deactivate() {
      alive = false;
      clearInterval(timer);
    },
    update() {},
  };
}

export const views = { overview: overviewView, storage: storageView, network: networkView, docker: dockerView, audit: auditView };
