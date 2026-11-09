// Thin fetch wrapper. The CSRF token lives in memory only: a page reload
// re-fetches it from /me, so it never touches storage.
let csrf = "";

export function setCsrf(token) {
  csrf = token || "";
}

export async function request(method, path, body) {
  const headers = {};
  if (body !== undefined) headers["content-type"] = "application/json";
  if (method !== "GET") headers["x-csrf-token"] = csrf;
  const res = await fetch("/api/v1" + path, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
    credentials: "same-origin",
  });
  let data = null;
  try {
    data = await res.json();
  } catch {
    // Empty or non-JSON body; the status code still tells the story.
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
