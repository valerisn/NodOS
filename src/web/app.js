import { get, getLocal, post, postLocal, setCsrf, setServer } from "./api.js";
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
let pollTimer = null;
let pollRound = 0;
let serverList = [];
let selected = null;

function showLogin() {
  stopStream();
  if (current && current.view.deactivate) current.view.deactivate();
  current = null;
  setCsrf("");
  setServer(null);
  selected = null;
  $("server-pick-box").hidden = true;
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
  $("nav-settings").hidden = role !== "admin";
  setCsrf(me.csrf);
  setServer(null);
  selected = null;
  route();
  startStream();
  startUpdateChecks();
  loadServers();
}

async function loadServers() {
  try {
    const d = await getLocal("/servers");
    serverList = d.servers;
  } catch {
    serverList = [];
  }
  const pick = $("server-pick");
  $("server-pick-box").hidden = serverList.length === 0;
  pick.replaceChildren(new Option("This server", ""), ...serverList.map((s) => new Option(s.name, s.name)));
  pick.value = selected || "";
}

function resetLive() {
  stopStream();
  latest = null;
  lastTs = 0;
  for (const k of Object.keys(hist)) hist[k] = [];
  renderAlerts([]);
  $("update").hidden = true;
  $("host-name").textContent = "-";
  $("host-meta").textContent = "";
  if (current && current.view.deactivate) current.view.deactivate();
  current = null;
}

function selectServer(name) {
  const entry = serverList.find((s) => s.name === name);
  selected = entry ? entry.name : null;
  resetLive();
  setServer(selected, entry ? entry.host : "");
  route();
  startStream();
  startUpdateChecks();
}

$("server-pick").addEventListener("change", (e) => selectServer(e.target.value));

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
      const plain = a.kind === "raid_problem" || a.kind === "zpool_problem" || a.kind === "disk_health";
      const li = document.createElement("li");
      li.dataset.level = a.level;
      const title = document.createElement("b");
      title.textContent = a.subject ? `${a.title}: ${a.subject}` : a.title;
      const val = document.createElement("span");
      val.textContent = plain ? a.level : `${a.value}${unit}`;
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
  return Object.hasOwn(views, name) ? name : "overview";
}

const titles = { overview: "Overview", storage: "Storage", network: "Network", docker: "Docker", apps: "Apps", services: "Services", audit: "Audit log", settings: "Settings" };

function route() {
  const name = routeName();
  $("page-title").textContent = titles[name] || "";
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
  clearTimeout(pollTimer);
}

// another server cannot be streamed through the hub, so it is polled instead
async function pollRemote() {
  const name = selected;
  try {
    const snap = await get("/system");
    if (selected !== name) return;
    setConn("live", "Live");
    notice("");
    onSnapshot(snap);
    if (pollRound % 3 === 0) {
      const a = await get("/alerts");
      if (selected === name) renderAlerts(a.alerts);
    }
    pollRound += 1;
  } catch (err) {
    if (selected !== name) return;
    if (err.status === 401) return showLogin();
    setConn("down", "Unreachable");
    notice(err.status === 502 || err.status === 504 ? `${name} cannot be reached from this server. Check that it is running and that its address and token are right.` : err.status === 503 ? "That server is not reporting metrics yet." : err.message);
  }
  if (selected === name) pollTimer = setTimeout(pollRemote, 2000);
}

async function startStream() {
  stopStream();
  setConn("connecting", "Connecting");
  if (selected) {
    pollRound = 0;
    await seedHistory();
    pollRemote();
    return;
  }
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
        await getLocal("/me");
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
    const body = { username: $("username").value.trim(), password: $("password").value };
    if (!$("code-row").hidden) body.code = $("code").value.trim();
    const me = await postLocal("/login", body);
    $("code-row").hidden = true;
    $("code").value = "";
    showApp(me);
  } catch (ex) {
    if (ex.status === 401 && ex.message === "two-factor code required") {
      $("code-row").hidden = false;
      $("code").focus();
      err.textContent = "Enter the 6 digit code from your authenticator app.";
      err.hidden = false;
      return;
    }
    err.textContent = ex.status === 429 ? "Too many failed attempts. Wait 15 minutes and try again." : ex.status === 401 ? "Wrong username or password." : "Sign-in failed: " + ex.message;
    err.hidden = false;
  } finally {
    btn.disabled = false;
  }
});

$("logout").addEventListener("click", async () => {
  try {
    await postLocal("/logout");
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
    showApp(await getLocal("/me"));
  } catch {
    showLogin();
  }
})();
