import { get, post, setCsrf } from "./api.js";
import { CAPACITY } from "./chart.js";
import { duration } from "./format.js";
import { views } from "./views.js";

const $ = (id) => document.getElementById(id);

const hist = { cpu: [], mem: [], rx: [], tx: [] };
let role = "viewer";
let latest = null;
let lastTs = 0;
let current = null;
let source = null;
let retryTimer = null;

function showLogin() {
  stopStream();
  if (current && current.view.deactivate) current.view.deactivate();
  current = null;
  setCsrf("");
  $("app").hidden = true;
  clearInterval(updateTimer);
  $("update").hidden = true;
  renderAlerts([]);
  $("login").hidden = false;
  $("password").value = "";
  $("username").focus();
}

function showApp(me) {
  $("login").hidden = true;
  $("app").hidden = false;
  $("whoami").textContent = me.username;
  role = me.role;
  $("nav-audit").hidden = role !== "admin";
  setCsrf(me.csrf);
  route();
  startStream();
  startUpdateChecks();
}

function setConn(state, text) {
  const el = $("conn");
  el.dataset.state = state;
  el.textContent = text;
}

function renderAlerts(list) {
  const box = $("alerts");
  box.hidden = list.length === 0;
  box.replaceChildren(
    ...list.map((a) => {
      const unit = a.kind === "temperature_high" ? "°C" : "%";
      const li = document.createElement("li");
      li.dataset.level = a.level;
      const title = document.createElement("b");
      title.textContent = a.subject ? `${a.title}: ${a.subject}` : a.title;
      const val = document.createElement("span");
      val.textContent = `${a.value}${unit}`;
      const when = document.createElement("span");
      when.className = "when";
      when.textContent = "since " + new Date(a.since * 1000).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
      li.append(title, val, when);
      return li;
    }),
  );
}

let updateTimer = null;

function dismissedVersion() {
  try {
    return localStorage.getItem("nodos.update.dismissed") || "";
  } catch {
    return "";
  }
}

function rememberDismissed(version) {
  try {
    localStorage.setItem("nodos.update.dismissed", version);
  } catch {
  }
}

async function checkUpdate() {
  try {
    const u = await get("/update");
    const box = $("update");
    if (!u.available || u.latest === dismissedVersion()) {
      box.hidden = true;
      return;
    }
    $("update-text").textContent = `NodOS ${u.latest.replace(/^v/, "")} is available. You have ${u.current}. To update, run this on the server:`;
    $("update-cmd").textContent = u.command;
    const link = $("update-link");
    link.hidden = !/^https:\/\//.test(u.page);
    if (!link.hidden) link.href = u.page;
    $("update-dismiss").dataset.version = u.latest;
    box.hidden = false;
  } catch {
  }
}

function startUpdateChecks() {
  clearInterval(updateTimer);
  checkUpdate();
  updateTimer = setInterval(checkUpdate, 30 * 60 * 1000);
}

$("update-dismiss").addEventListener("click", () => {
  rememberDismissed($("update-dismiss").dataset.version || "");
  $("update").hidden = true;
});

function notice(text) {
  $("notice").hidden = !text;
  $("notice").textContent = text || "";
}

function routeName() {
  const name = location.hash.replace(/^#\/?/, "") || "overview";
  return name in views ? name : "overview";
}

function route() {
  const name = routeName();
  for (const a of $("nav").querySelectorAll("a")) {
    if (a.dataset.route === name) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
  if (current && current.name === name) return;
  if (current && current.view.deactivate) current.view.deactivate();
  const view = views[name]({ role });
  $("view").replaceChildren(view.el);
  current = { name, view };
  if (view.activate) view.activate();
  if (latest) view.update(latest, hist);
}

window.addEventListener("hashchange", () => {
  if (!$("app").hidden) route();
});

function pushPoint(snap) {
  const memPct = snap.memory.total_kb ? (snap.memory.used_kb / snap.memory.total_kb) * 100 : 0;
  let rx = 0, tx = 0;
  for (const i of snap.network) {
    if (i.name === "lo") continue;
    rx += i.rx_bps;
    tx += i.tx_bps;
  }
  const point = { cpu: snap.cpu.percent, mem: memPct, rx, tx };
  for (const k of Object.keys(hist)) {
    hist[k].push(point[k]);
    if (hist[k].length > CAPACITY) hist[k].shift();
  }
}

function onSnapshot(snap) {
  latest = snap;
  if (snap.ts > lastTs) {
    pushPoint(snap);
    lastTs = snap.ts;
  }
  $("host-name").textContent = snap.hostname || "This server";
  $("host-meta").textContent = [snap.os, snap.kernel && "kernel " + snap.kernel, "up " + duration(snap.uptime_s)].filter(Boolean).join(", ");
  document.title = `${snap.hostname || "NodOS"} - NodOS`;
  if (current) current.view.update(snap, hist);
}

async function seedHistory() {
  try {
    const h = await get("/history");
    hist.cpu = h.cpu;
    hist.mem = h.mem;
    hist.rx = h.rx_bps;
    hist.tx = h.tx_bps;
    lastTs = h.ts.length ? h.ts[h.ts.length - 1] : 0;
  } catch {
  }
}

function stopStream() {
  if (source) source.close();
  source = null;
  clearTimeout(retryTimer);
}

async function startStream() {
  stopStream();
  setConn("connecting", "Connecting");
  try {
    await seedHistory();
    const snap = await get("/system");
    notice("");
    onSnapshot(snap);
  } catch (err) {
    if (err.status === 401) return showLogin();
    if (err.status === 503) {
      setConn("down", "No data");
      notice("This host is not reporting metrics yet. Host monitoring needs Linux, and the first reading takes a couple of seconds.");
      retryTimer = setTimeout(startStream, 5000);
      return;
    }
  }

  source = new EventSource("/api/v1/stream");
  source.addEventListener("open", () => setConn("live", "Live"));
  source.addEventListener("snapshot", (e) => {
    setConn("live", "Live");
    notice("");
    try {
      onSnapshot(JSON.parse(e.data));
    } catch {
    }
  });
  source.addEventListener("alerts", (e) => {
    try {
      renderAlerts(JSON.parse(e.data).alerts);
    } catch {
    }
  });
  source.addEventListener("error", async () => {
    setConn("down", "Reconnecting");
    if (source && source.readyState === EventSource.CLOSED) {
      source.close();
      try {
        await get("/me");
        retryTimer = setTimeout(startStream, 5000);
      } catch (err) {
        if (err.status === 401) showLogin();
        else retryTimer = setTimeout(startStream, 5000);
      }
    }
  });
}

$("login-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = $("login-button");
  const err = $("login-error");
  err.hidden = true;
  btn.disabled = true;
  try {
    const me = await post("/login", { username: $("username").value.trim(), password: $("password").value });
    showApp(me);
  } catch (ex) {
    err.textContent = ex.status === 429 ? "Too many failed attempts. Wait 15 minutes and try again." : ex.status === 401 ? "Wrong username or password." : "Sign-in failed: " + ex.message;
    err.hidden = false;
  } finally {
    btn.disabled = false;
  }
});

$("logout").addEventListener("click", async () => {
  try {
    await post("/logout");
  } catch {
  }
  latest = null;
  lastTs = 0;
  current = null;
  for (const k of Object.keys(hist)) hist[k] = [];
  showLogin();
});

(async () => {
  try {
    showApp(await get("/me"));
  } catch {
    showLogin();
  }
})();
