/** Control API base (Lambda HTTP API or local docker). */
export const API_BASE = (
  import.meta.env.VITE_SIGEO_MAP_API_BASE || "http://localhost:8092"
).replace(/\/$/, "");

export async function api(path: string, opts: RequestInit = {}) {
  const url = path.startsWith("http") ? path : API_BASE + path;
  const headers = new Headers(opts.headers || {});
  headers.set("Content-Type", "application/json");
  const res = await fetch(url, { ...opts, headers });
  if (!res.ok) {
    const t = await res.text();
    let msg = t || res.statusText;
    try {
      const j = JSON.parse(t);
      if (j.error) msg = j.error;
    } catch {
      /* keep text */
    }
    throw new Error(msg);
  }
  if (res.status === 204) return null;
  return res.json();
}
