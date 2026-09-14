import { AREA_PRESETS, normalizeArea } from "./areas.js";
import { publicDbHost, query } from "./db.js";
import {
  createJob,
  getSettings,
  importBackend,
  runningJobId,
  startImporter,
} from "./jobs.js";

function json(statusCode, body, extraHeaders = {}) {
  return {
    statusCode,
    headers: {
      "content-type": "application/json",
      "access-control-allow-origin": "*",
      "access-control-allow-headers": "content-type,authorization",
      "access-control-allow-methods": "GET,PUT,POST,OPTIONS",
      ...extraHeaders,
    },
    body: JSON.stringify(body),
  };
}

function parseBody(event) {
  if (!event.body) return {};
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, "base64").toString("utf8")
    : event.body;
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

function routeKey(event) {
  const method =
    event.requestContext?.http?.method ||
    event.httpMethod ||
    event.requestContext?.httpMethod ||
    "GET";
  let path = event.rawPath || event.path || "/";
  const stage = event.requestContext?.stage;
  if (stage && stage !== "$default" && path.startsWith(`/${stage}`)) {
    path = path.slice(stage.length + 1) || "/";
  }
  return { method: method.toUpperCase(), path };
}

function mapJob(r) {
  return {
    id: r.id,
    area: r.area,
    status: r.status,
    trigger: r.trigger,
    remote_md5: r.remote_md5,
    local_md5: r.local_md5,
    started_at: r.started_at ? new Date(r.started_at).toISOString() : null,
    finished_at: r.finished_at ? new Date(r.finished_at).toISOString() : null,
    error: r.error,
    created_at: r.created_at ? new Date(r.created_at).toISOString() : null,
  };
}

async function handle(method, path, event) {
  if (method === "OPTIONS") return json(204, {});

  if (method === "GET" && path === "/api/health") {
    await query("SELECT 1");
    return json(200, { status: "ok", backend: importBackend(), runtime: "nodejs" });
  }

  if (method === "GET" && path === "/api/areas") {
    return json(200, {
      presets: AREA_PRESETS,
      note: "Use monaco for smoke tests; centro for Rome region.",
    });
  }

  if (method === "GET" && path === "/api/settings") {
    return json(200, await getSettings());
  }

  if (method === "PUT" && path === "/api/settings") {
    const body = parseBody(event);
    const cur = await getSettings();
    const area = body.area != null ? normalizeArea(body.area) : cur.area;
    const hours =
      body.interval_hours != null ? Number(body.interval_hours) : cur.interval_hours;
    const enabled = body.enabled != null ? Boolean(body.enabled) : cur.enabled;
    if (!Number.isFinite(hours) || hours < 1) {
      return json(400, { error: "interval_hours must be >= 1" });
    }
    await query(
      `INSERT INTO control.settings (id, area, interval_hours, enabled, updated_at)
       VALUES (1, $1, $2, $3, now())
       ON CONFLICT (id) DO UPDATE
         SET area = EXCLUDED.area,
             interval_hours = EXCLUDED.interval_hours,
             enabled = EXCLUDED.enabled,
             updated_at = now()`,
      [area, hours, enabled]
    );
    return json(200, await getSettings());
  }

  if (method === "GET" && path === "/api/jobs") {
    const limit = Math.min(Number(event.queryStringParameters?.limit || 20), 100);
    const { rows } = await query(
      `SELECT id::text, area, status, trigger, remote_md5, local_md5,
              started_at, finished_at, error, created_at
       FROM control.jobs ORDER BY created_at DESC LIMIT $1`,
      [limit]
    );
    return json(200, rows.map(mapJob));
  }

  if (method === "GET" && path === "/api/jobs/latest") {
    const { rows } = await query(
      `SELECT id::text, area, status, trigger, remote_md5, local_md5,
              started_at, finished_at, error, created_at
       FROM control.jobs ORDER BY created_at DESC LIMIT 1`
    );
    return json(200, { job: rows[0] ? mapJob(rows[0]) : null });
  }

  const jobMatch = path.match(/^\/api\/jobs\/([^/]+)$/);
  if (method === "GET" && jobMatch) {
    const { rows } = await query(
      `SELECT id::text, area, status, trigger, remote_md5, local_md5,
              started_at, finished_at, error, created_at
       FROM control.jobs WHERE id = $1::uuid`,
      [jobMatch[1]]
    );
    if (!rows[0]) return json(404, { error: "job not found" });
    return json(200, mapJob(rows[0]));
  }

  const logsMatch = path.match(/^\/api\/jobs\/([^/]+)\/logs$/);
  if (method === "GET" && logsMatch) {
    const afterId = Number(event.queryStringParameters?.after_id || 0);
    const { rows } = await query(
      `SELECT id, ts, level, message
       FROM control.job_logs
       WHERE job_id = $1::uuid AND id > $2
       ORDER BY id ASC LIMIT 500`,
      [logsMatch[1], afterId]
    );
    return json(200, {
      logs: rows.map((r) => ({
        id: Number(r.id),
        ts: r.ts ? new Date(r.ts).toISOString() : null,
        level: r.level,
        message: r.message,
      })),
    });
  }

  if (method === "POST" && path === "/api/jobs/run") {
    if (await runningJobId()) {
      return json(409, { error: "an import job is already running" });
    }
    const body = parseBody(event);
    const settings = await getSettings();
    const area = body.area ? normalizeArea(body.area) : settings.area;
    const trigger = ["manual", "api", "schedule"].includes(body.trigger)
      ? body.trigger
      : "manual";
    const jobId = await createJob(area, trigger);
    const meta = (await startImporter(jobId, area, Boolean(body.force))) || {};
    return json(200, { job_id: jobId, area, status: "pending", ...meta });
  }

  if (method === "GET" && path === "/api/db/info") {
    const tablesRes = await query(
      `SELECT table_name FROM information_schema.tables
       WHERE table_schema = 'public' AND table_name LIKE 'planet_osm%'
       ORDER BY 1`
    );
    const tables = tablesRes.rows.map((r) => r.table_name);
    const counts = {};
    for (const t of tables) {
      const c = await query(`SELECT COUNT(*)::bigint AS n FROM public.${t}`);
      counts[t] = Number(c.rows[0].n);
    }
    const stateRes = await query(
      "SELECT area, md5, updated_at FROM control.area_state ORDER BY area"
    );
    return json(200, {
      database: publicDbHost(),
      tables,
      counts,
      area_state: stateRes.rows.map((r) => ({
        area: r.area,
        md5: r.md5,
        updated_at: r.updated_at ? new Date(r.updated_at).toISOString() : null,
      })),
    });
  }

  return json(404, { error: `not found: ${method} ${path}` });
}

export async function apiHandler(event) {
  try {
    const { method, path } = routeKey(event);
    return await handle(method, path, event);
  } catch (e) {
    console.error(e);
    return json(e.statusCode || 500, { error: e.message || String(e) });
  }
}
