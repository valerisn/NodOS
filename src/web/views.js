import { get, post } from "./api.js";
import { StripChart } from "./chart.js";
import { bytes, bytesText, duration, level, percent, rate, rateText } from "./format.js";

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

function channel(name, chartOpts, axisStart = "10 min ago") {
  const value = h("div", { class: "channel-value" });
  const sub = h("div", { class: "channel-sub" });
  const chartEl = h("div", { class: "chart" });
  const root = h(
    "section",
    { class: "channel", "aria-label": name },
    h("div", { class: "channel-head" }, h("div", { class: "channel-name" }, name), value, sub),
    h("div", {}, chartEl, h("div", { class: "chart-axis" }, h("span", {}, axisStart), h("span", {}, "now"))),
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

export function storageView() {
  const body = h("tbody");
  const empty = h("p", { class: "empty", hidden: true }, "No disk-backed filesystems are mounted.");
  const table = h(
    "table",
    {},
    h("thead", {}, h("tr", {}, h("th", {}, "Mount"), h("th", { class: "usage" }, "Used"), h("th", { class: "num" }, "Free"), h("th", { class: "num" }, "Size"))),
    body,
  );
  const healthBody = h("tbody");
  const healthBlock = h(
    "section",
    { class: "block", hidden: true },
    h("h2", {}, "Disk and array health"),
    h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Item"), h("th", {}, "State"), h("th", {}, "Details"))), healthBody),
  );
  let healthTimer = null;
  async function loadHealth() {
    try {
      const d = await get("/storage-health");
      healthBlock.hidden = d.items.length === 0;
      healthBody.replaceChildren(
        ...d.items.map((it) =>
          h(
            "tr",
            { class: it.status === "crit" ? "bad" : "" },
            h("td", {}, h("div", { class: "mount-name" }, it.name), h("div", { class: "mount-dev" }, { raid: "RAID array", zpool: "ZFS pool", smart: "Disk" }[it.kind] || it.kind)),
            h("td", {}, h("span", { class: "state", "data-level": it.status === "ok" ? "ok" : it.status === "warn" ? "warn" : "crit" }, it.status === "ok" ? "healthy" : it.status === "warn" ? "check" : "problem")),
            h("td", { class: "mount-dev" }, it.detail),
          ),
        ),
      );
    } catch {
      healthBlock.hidden = true;
    }
  }
  const el = h("div", {}, table, empty, healthBlock);
  return {
    el,
    activate() {
      loadHealth();
      healthTimer = setInterval(loadHealth, 30000);
    },
    deactivate() {
      clearInterval(healthTimer);
    },
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

const DOCKER_HINTS = {
  "docker is not reachable": "NodOS cannot reach Docker. Check that the socket exists and that the user running NodOS can read it.",
  "docker integration is turned off": "Docker is turned off in the NodOS config (docker_socket = off).",
};

function logPanel(explain) {
  const title = h("h2", {});
  const pre = h("pre", { class: "logs", tabindex: "0" });
  const close = h("button", { type: "button", class: "quiet" }, "Close");
  const refresh = h("button", { type: "button", class: "quiet" }, "Refresh");
  const el = h("section", { class: "block", hidden: true }, h("div", { class: "block-head" }, title, h("span", { class: "spacer" }), refresh, close), pre);
  let loader = null;

  async function load() {
    if (!loader) return;
    try {
      const d = await loader();
      pre.textContent = d.lines.length ? d.lines.join("\n") : "No log output.";
      if (d.truncated) pre.append("\n[older lines cut to fit]");
      pre.scrollTop = pre.scrollHeight;
    } catch (err) {
      pre.textContent = "Could not read logs: " + explain(err);
    }
  }
  refresh.addEventListener("click", load);
  close.addEventListener("click", () => {
    loader = null;
    el.hidden = true;
  });
  return {
    el,
    open(name, fetchLines) {
      loader = fetchLines;
      title.textContent = `Logs: ${name}`;
      pre.textContent = "Loading...";
      el.hidden = false;
      load();
    },
  };
}

function stateLevel(state) {
  if (state === "running") return "ok";
  if (state === "exited" || state === "created") return "idle";
  return "warn";
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
  const logs = logPanel((err) => explain(err));
  const hist = { cpu: [], mem: [], id: null, name: "", timer: null, busy: false };
  const histCpu = channel("Processor", { series: [{ color: "primary" }], minMax: 10, label: (v) => (v < 10 ? v.toFixed(1) : Math.round(v)) + "%" }, "since you opened this");
  const histMem = channel("Memory", { series: [{ color: "secondary" }], minMax: 16 * 1024 * 1024, label: (v) => bytesText(v) }, "since you opened this");
  const histTitle = h("h2", {});
  const histText = h("p", { class: "muted", role: "status" });
  const histClose = h("button", { type: "button", class: "quiet" }, "Close");
  const histBlock = h("section", { class: "block", hidden: true }, h("div", { class: "block-head" }, histTitle, h("span", { class: "spacer" }), histClose), histText, histCpu.root, histMem.root);
  const imageBody = h("tbody");
  const imageTable = h(
    "table",
    { hidden: true },
    h("thead", {}, h("tr", {}, h("th", {}, "Image"), h("th", {}, "ID"), h("th", { class: "num" }, "Size"))),
    imageBody,
  );
  const imageNote = h("p", { class: "muted", role: "status" });
  const imageBlock = h("section", { class: "block", hidden: true }, h("h2", {}, "Images"), imageNote, imageTable);

  let timer = null;
  let busy = false;
  let alive = true;
  let imageTick = 0;

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
      if (imageTick++ % 6 === 0) loadImages();
    } catch (err) {
      if (!alive) return;
      table.hidden = true;
      body.replaceChildren();
      message.textContent = err.status === 401 ? "Your session ended. Sign in again." : explain(err);
    }
  }

  async function loadImages() {
    try {
      const d = await get("/docker/images");
      if (!alive) return;
      imageBlock.hidden = d.images.length === 0;
      imageNote.textContent = d.total > d.images.length ? `Showing ${d.images.length} of ${d.total} images.` : "";
      imageTable.hidden = d.images.length === 0;
      imageBody.replaceChildren(
        ...d.images.map((im) =>
          h("tr", {}, h("td", {}, im.tags.length ? im.tags.join(", ") : h("span", { class: "muted" }, "untagged")), h("td", { class: "mount-dev" }, im.id), h("td", { class: "num" }, bytesText(im.size))),
        ),
      );
    } catch {
      if (alive) imageBlock.hidden = true;
    }
  }

  function closeHistory() {
    clearInterval(hist.timer);
    hist.timer = null;
    hist.id = null;
    histBlock.hidden = true;
  }
  histClose.addEventListener("click", closeHistory);

  async function pollHistory() {
    if (hist.busy || !hist.id) return;
    hist.busy = true;
    const id = hist.id;
    try {
      const s = await get(`/docker/containers/${encodeURIComponent(id)}/stats`);
      if (hist.id !== id) return;
      if (s.cpu_percent !== null) hist.cpu.push(s.cpu_percent);
      hist.mem.push(s.mem_used);
      if (hist.cpu.length > 120) hist.cpu.shift();
      if (hist.mem.length > 120) hist.mem.shift();
      histCpu.value.textContent = s.cpu_percent === null ? "-" : s.cpu_percent.toFixed(1) + "%";
      histMem.value.textContent = bytesText(s.mem_used);
      histMem.sub.textContent = s.mem_limit > 0 ? `of ${bytesText(s.mem_limit)}` : "";
      histText.textContent = `${s.pids} processes, network in ${bytesText(s.net_rx)}, out ${bytesText(s.net_tx)}. Measured while this panel is open.`;
      histCpu.chart.setData([hist.cpu]);
      histMem.chart.setData([hist.mem]);
    } catch (err) {
      histText.textContent = explain(err);
    } finally {
      hist.busy = false;
    }
  }

  function showStats(c) {
    if (hist.id === c.id) return closeHistory();
    closeHistory();
    hist.id = c.id;
    hist.cpu = [];
    hist.mem = [];
    histTitle.textContent = c.name || c.id;
    histText.textContent = "Measuring...";
    histCpu.value.textContent = "-";
    histMem.value.textContent = "-";
    histMem.sub.textContent = "";
    histCpu.chart.setData([[]]);
    histMem.chart.setData([[]]);
    histBlock.hidden = false;
    histBlock.scrollIntoView({ block: "nearest", behavior: "smooth" });
    pollHistory();
    hist.timer = setInterval(pollHistory, 5000);
  }

  function button(label, onClick, disabled) {
    const b = h("button", { type: "button", class: "quiet", disabled: disabled ? true : false }, label);
    b.addEventListener("click", onClick);
    return b;
  }

  function row(c) {
    const running = c.state === "running";
    const actions = h("td", { class: "num actions" });
    if (running) actions.append(button("Stats", () => showStats(c)));
    if (admin) {
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

  function openLogs(c) {
    logs.open(c.name || c.id, () => get(`/docker/containers/${encodeURIComponent(c.id)}/logs?tail=200`));
  }

  const el = h("div", {}, flash, message, table, histBlock, imageBlock, logs.el);
  return {
    el,
    activate() {
      alive = true;
      imageTick = 0;
      load();
      timer = setInterval(load, 5000);
    },
    deactivate() {
      alive = false;
      clearInterval(timer);
      closeHistory();
    },
    update() {},
  };
}

const SERVICE_HINTS = {
  "no services are configured": "No services are listed yet. Add a services line to the NodOS config, for example: services = ssh, nginx",
  "systemd is not available on this host": "systemd is not available on this host.",
};

function activeLevel(active) {
  if (active === "active") return "ok";
  if (active === "failed") return "crit";
  if (active === "inactive") return "idle";
  return "warn";
}

export function serviceView({ role }) {
  const admin = role === "admin";
  const body = h("tbody");
  const message = h("p", { class: "muted", role: "status" });
  const flash = h("p", { class: "flash", role: "status", hidden: true });
  const table = h(
    "table",
    { hidden: true },
    h("thead", {}, h("tr", {}, h("th", {}, "Service"), h("th", {}, "State"), h("th", { class: "num" }, "PID"), h("th", { class: "num" }, admin ? "Actions" : ""))),
    body,
  );
  const explain = (err) => SERVICE_HINTS[err.message] || err.message;
  const logs = logPanel(explain);
  let timer = null;
  let busy = false;
  let alive = true;

  function say(text, bad) {
    flash.hidden = !text;
    flash.textContent = text || "";
    flash.dataset.bad = bad ? "1" : "";
  }

  function button(label, onClick) {
    const b = h("button", { type: "button", class: "quiet" }, label);
    b.addEventListener("click", onClick);
    return b;
  }

  function row(s) {
    const up = s.active === "active";
    const actions = h("td", { class: "num actions" });
    if (admin && s.load !== "not-found") {
      actions.append(
        ...[button("Logs", () => logs.open(s.unit, () => get(`/services/${encodeURIComponent(s.unit)}/logs?tail=200`))), up ? button("Restart", () => act(s, "restart")) : button("Start", () => act(s, "start")), up ? button("Stop", () => act(s, "stop")) : undefined].filter(Boolean),
      );
    }
    const state = s.load === "not-found" ? "not installed" : s.sub && s.sub !== s.active ? `${s.active} (${s.sub})` : s.active;
    return h(
      "tr",
      {},
      h("td", {}, h("div", { class: "mount-name" }, s.unit), h("div", { class: "mount-dev" }, s.description)),
      h("td", {}, h("span", { class: "state", "data-level": s.load === "not-found" ? "idle" : activeLevel(s.active) }, state)),
      h("td", { class: "num" }, s.pid ? String(s.pid) : "-"),
      actions,
    );
  }

  async function load() {
    try {
      const d = await get("/services");
      if (!alive) return;
      message.textContent = d.services.length === 0 ? "No services are listed yet. Add a services line to the NodOS config." : "";
      table.hidden = d.services.length === 0;
      body.replaceChildren(...d.services.map(row));
    } catch (err) {
      if (!alive) return;
      table.hidden = true;
      body.replaceChildren();
      message.textContent = err.status === 401 ? "Your session ended. Sign in again." : explain(err);
    }
  }

  async function act(s, verb) {
    if (busy) return;
    if (verb !== "start" && !confirm(`${verb === "stop" ? "Stop" : "Restart"} ${s.unit}?`)) return;
    busy = true;
    const ing = { start: "Starting", stop: "Stopping", restart: "Restarting" }[verb];
    say(`${ing} ${s.unit}...`);
    try {
      await post(`/services/${encodeURIComponent(s.unit)}/${verb}`);
      say(`${s.unit} ${{ start: "started", stop: "stopped", restart: "restarted" }[verb]}.`);
    } catch (err) {
      say(`Could not ${verb} ${s.unit}: ${explain(err)}`, true);
    } finally {
      busy = false;
      await load();
    }
  }

  return {
    el: h("div", {}, flash, message, table, logs.el),
    activate() {
      alive = true;
      load();
      timer = setInterval(load, 5000);
    },
    deactivate() {
      alive = false;
      clearInterval(timer);
    },
    update() {},
  };
}

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

export function settingsView({ role }) {
  const message = h("p", { class: "muted", role: "status" });
  const box = h("div", { hidden: true });

  function yesNo(v) {
    return v ? "on" : "off";
  }

  function section(title, rows) {
    return h(
      "section",
      { class: "block" },
      h("h2", {}, title),
      h("table", {}, h("tbody", {}, ...rows.map(([k, v]) => h("tr", {}, h("td", {}, k), h("td", { class: "mount-dev" }, String(v)))))),
    );
  }

  async function load() {
    if (role !== "admin") {
      message.textContent = "Settings are visible to administrators only.";
      return;
    }
    try {
      const s = await get("/settings");
      message.textContent = "These are read from the config file. To change one, edit the file and restart NodOS.";
      const a = s.alerts;
      box.replaceChildren(
        section("Server", [
          ["Version", s.version],
          ["Listen", `${s.listen}:${s.port}`],
          ["Data directory", s.data_dir],
          ["Log level", s.log_level],
          ["Secure cookies", yesNo(s.secure_cookies)],
          ["Trusted proxy", s.trusted_proxy || "none"],
          ["Sample interval", `${s.sample_interval_ms} ms`],
        ]),
        section("Integrations", [
          ["Docker socket", s.docker_socket === "off" ? "off" : s.docker_socket],
          ["Services", s.services.length ? s.services.join(", ") : "none"],
          ["Alert webhook", s.webhook_set ? "configured" : "not set"],
        ]),
        section("Updates", [
          ["Update check", yesNo(s.update_check)],
          ["Custom mirror", s.update_mirror_set ? "configured" : "not set (GitHub)"],
        ]),
        section("Alert thresholds", [
          ["CPU busy", `${a.cpu_warn}% for ${a.cpu_samples} samples`],
          ["Memory used", `warn ${a.mem_warn}%, critical ${a.mem_crit}%`],
          ["Disk used", `warn ${a.disk_warn}%, critical ${a.disk_crit}%`],
          ["Temperature", `warn ${a.temp_warn} C, critical ${a.temp_crit} C`],
          ["Swap used", `warn ${a.swap_warn}%`],
        ]),
      );
      box.hidden = false;
    } catch (err) {
      message.textContent = err.status === 403 ? "Settings are visible to administrators only." : err.message;
    }
  }

  return {
    el: h("div", {}, message, box),
    activate() {
      load();
    },
    deactivate() {},
    update() {},
  };
}

export const views = { overview: overviewView, storage: storageView, network: networkView, docker: dockerView, services: serviceView, audit: auditView, settings: settingsView };
