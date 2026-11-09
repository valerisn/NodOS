import { get, post, setCsrf } from "./api.js";
import { CAPACITY } from "./chart.js";
import { duration } from "./format.js";
import { views } from "./views.js";

const $ = (id) => document.getElementById(id);

// Rolling history for the charts, seeded from /history then extended by the stream.
const hist = { cpu: [], mem: [], rx: [], tx: [] };
let role = "viewer";
let latest = null;
let lastTs = 0;
let current = null; // { name, view }
let source = null; // EventSource
let retryTimer = null;

// ---------------------------------------------------------------- screens

function showLogin() {
  stopStream();
  if (current && current.view.deactivate) current.view.deactivate();
  current = null;
  setCsrf("");
  $("app").hidden = true;
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

function notice(text) {
  $("notice").hidden = !text;
  $("notice").textContent = text || "";
}

// ---------------------------------------------------------------- routing

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

// ---------------------------------------------------------------- data

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
  // The server sends the current snapshot again on connect, and /history may
  // already include it. Plot each timestamp once.
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
    // Charts just start empty; the stream will fill them in.
  }
}

// ---------------------------------------------------------------- stream

function stopStream() {
  if (source) source.close();
  source = null;
  clearTimeout(retryTimer);
}

async function startStream() {
  stopStream();
  setConn("connecting", "Connecting");
  // The first snapshot can lag by one sample interval, so ask for it directly
  // and paint immediately instead of showing an empty page.
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
      // A malformed event is dropped; the next one will be fine.
    }
  });
  source.addEventListener("alerts", (e) => {
    try {
      renderAlerts(JSON.parse(e.data).alerts);
    } catch {
      // Keep whatever alerts are on screen; the next change resends the list.
    }
  });
  source.addEventListener("error", async () => {
    setConn("down", "Reconnecting");
    // EventSource retries on its own for dropped connections. If it gave up
    // (readyState CLOSED) the server answered with an error status, so find
    // out why: session gone means sign in again, anything else means retry.
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

// ---------------------------------------------------------------- auth

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
    // Already signed out server-side; fall through to the login screen.
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
