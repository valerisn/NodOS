let csrf = "";
let server = null;
let serverHost = "";

/** Chooses which machine the dashboard talks to. null is this one. */
export function setServer(name, host) {
  server = name || null;
  serverHost = host || "";
}

export const isRemote = () => server !== null;

/** Hostname for links that should open on the selected machine. */
export const currentHost = () => (server ? serverHost : location.hostname);

export function setCsrf(token) {
  csrf = token || "";
}

export async function request(method, path, body, local = false) {
  const headers = {};
  if (body !== undefined) headers["content-type"] = "application/json";
  if (method !== "GET") headers["x-csrf-token"] = csrf;
  const prefix = server && !local ? "/api/v1/remote/" + encodeURIComponent(server) : "/api/v1";
  const res = await fetch(prefix + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: "same-origin",
  });
  let data = null;
  try {
    data = await res.json();
  } catch {
    // body can be empty or not json, the status code still tells the story
  }
  if (!res.ok) {
    const err = new Error((data && data.error) || res.statusText);
    err.status = res.status;
    throw err;
  }
  return data;
}

export const get = (path) => request("GET", path);
export const post = (path, body) => request("POST", path, body);
export const getLocal = (path) => request("GET", path, undefined, true);
export const postLocal = (path, body) => request("POST", path, body, true);
