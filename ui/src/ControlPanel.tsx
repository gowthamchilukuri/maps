import { useCallback, useEffect, useMemo, useState } from "react";
import { api, API_BASE } from "./api";

type AreaPreset = { id: string; label: string; hint?: string };
type Job = {
  id: string;
  area: string;
  status: string;
  trigger?: string;
  remote_md5?: string;
  created_at?: string;
  started_at?: string;
  finished_at?: string;
  error?: string;
};
type LogLine = { id: number; ts?: string; level: string; message: string };

type Props = {
  email: string;
  onSignOut?: () => void;
};

export default function ControlPanel({ email, onSignOut }: Props) {
  const [areaPresets, setAreaPresets] = useState<AreaPreset[]>([]);
  const [areaPreset, setAreaPreset] = useState("monaco");
  const [intervalHours, setIntervalHours] = useState(12);
  const [enabled, setEnabled] = useState(true);
  const [settingsMsg, setSettingsMsg] = useState(
    "Import writes planet_osm_*. Start with monaco."
  );
  const [dbInfo, setDbInfo] = useState("Loading…");
  const [jobs, setJobs] = useState<Job[]>([]);
  const [currentJobId, setCurrentJobId] = useState<string | null>(null);
  const [job, setJob] = useState<Job | null>(null);
  const [logs, setLogs] = useState<LogLine[]>([]);
  const [lastLogId, setLastLogId] = useState(0);
  const [busy, setBusy] = useState(false);

  const selectedArea = useMemo(() => areaPreset, [areaPreset]);

  const loadAreas = useCallback(async () => {
    const data = await api("/api/areas");
    setAreaPresets(data.presets || []);
  }, []);

  const loadSettings = useCallback(async () => {
    const s = await api("/api/settings");
    setAreaPreset(s.area === "rome" ? "centro" : s.area);
    setIntervalHours(s.interval_hours);
    setEnabled(s.enabled);
  }, []);

  const saveSettings = useCallback(async () => {
    await api("/api/settings", {
      method: "PUT",
      body: JSON.stringify({
        area: selectedArea,
        interval_hours: Number(intervalHours),
        enabled,
      }),
    });
    setSettingsMsg(`Saved area=${selectedArea} · ${new Date().toLocaleTimeString()}`);
  }, [selectedArea, intervalHours, enabled]);

  const loadDbInfo = useCallback(async () => {
    try {
      const info = await api("/api/db/info");
      const lines = [
        `api: ${API_BASE}`,
        `host: ${info.database}`,
        `tables: ${(info.tables || []).join(", ") || "(none yet)"}`,
      ];
      if (info.counts) {
        for (const [k, v] of Object.entries(info.counts)) {
          lines.push(`${k}: ${Number(v).toLocaleString()}`);
        }
      }
      setDbInfo(lines.join("\n"));
    } catch (e) {
      setDbInfo(e instanceof Error ? e.message : String(e));
    }
  }, []);

  const refreshJobs = useCallback(async () => {
    const list: Job[] = await api("/api/jobs?limit=15");
    setJobs(list);
    setCurrentJobId((prev) => prev || list[0]?.id || null);
  }, []);

  const refreshJob = useCallback(async () => {
    if (!currentJobId) {
      setJob(null);
      return;
    }
    const j: Job = await api(`/api/jobs/${currentJobId}`);
    setJob(j);
    const logRes = await api(`/api/jobs/${currentJobId}/logs?after_id=${lastLogId}`);
    if (logRes.logs?.length) {
      setLogs((prev) => [...prev, ...logRes.logs]);
      setLastLogId(logRes.logs[logRes.logs.length - 1].id);
    }
  }, [currentJobId, lastLogId]);

  const refresh = useCallback(async () => {
    await Promise.all([refreshJobs(), refreshJob(), loadDbInfo()]);
  }, [refreshJobs, refreshJob, loadDbInfo]);

  const runNow = async () => {
    setBusy(true);
    try {
      await saveSettings();
      const r = await api("/api/jobs/run", {
        method: "POST",
        body: JSON.stringify({
          area: selectedArea,
          force: false,
          trigger: "manual",
        }),
      });
      setCurrentJobId(r.job_id);
      setLastLogId(0);
      setLogs([]);
      await refresh();
    } catch (e) {
      alert(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  useEffect(() => {
    loadAreas()
      .then(() => loadSettings())
      .then(() => refresh())
      .catch((e) => alert(e.message));
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const t = setInterval(() => {
      refresh().catch(() => {});
    }, 3000);
    return () => clearInterval(t);
  }, [refresh]);

  useEffect(() => {
    setLastLogId(0);
    setLogs([]);
  }, [currentJobId]);

  return (
    <>
      <header>
        <div>
          <h1>Sigeo map service</h1>
          <p>Geofabrik → PostGIS · Amplify Cognito</p>
        </div>
        <div className="user">
          <span>{email}</span>
          <button type="button" className="secondary" style={{ width: "auto" }} onClick={onSignOut}>
            Sign out
          </button>
        </div>
      </header>
      <main>
        <section className="card">
          <h2>Settings</h2>
          <label htmlFor="areaPreset">Area</label>
          <select
            id="areaPreset"
            value={areaPreset}
            onChange={(e) => setAreaPreset(e.target.value)}
          >
            {areaPresets.map((p) => (
              <option key={p.id} value={p.id}>
                {p.label}
                {p.hint ? ` — ${p.hint}` : ""}
              </option>
            ))}
          </select>

          <label htmlFor="interval" style={{ marginTop: "0.75rem" }}>
            Interval (hours)
          </label>
          <input
            id="interval"
            type="number"
            min={1}
            value={intervalHours}
            onChange={(e) => setIntervalHours(Number(e.target.value))}
          />

          <label
            style={{ marginTop: "0.75rem", display: "flex", gap: "0.5rem", alignItems: "center" }}
          >
            <input
              type="checkbox"
              checked={enabled}
              onChange={(e) => setEnabled(e.target.checked)}
              style={{ width: "auto" }}
            />
            Scheduler enabled
          </label>

          <div className="row">
            <button type="button" onClick={() => saveSettings().catch((e) => alert(e.message))}>
              Save settings
            </button>
            <button type="button" className="secondary" disabled={busy} onClick={runNow}>
              Run now
            </button>
          </div>
          <p className="meta" style={{ marginTop: "0.75rem" }}>
            {settingsMsg}
          </p>

          <h2 style={{ marginTop: "1.25rem" }}>Database</h2>
          <div className="meta pre">{dbInfo}</div>

          <h2 style={{ marginTop: "1.25rem" }}>Recent jobs</h2>
          <div style={{ overflow: "auto", maxHeight: 220 }}>
            <table>
              <thead>
                <tr>
                  <th>When</th>
                  <th>Area</th>
                  <th>Status</th>
                </tr>
              </thead>
              <tbody>
                {jobs.map((j) => (
                  <tr
                    key={j.id}
                    style={{ cursor: "pointer" }}
                    onClick={() => setCurrentJobId(j.id)}
                  >
                    <td>{(j.created_at || "").replace("T", " ").slice(0, 19)}</td>
                    <td>{j.area}</td>
                    <td>
                      <span className={`badge ${j.status}`}>{j.status}</span>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>

        <section className="card">
          <h2>
            Latest job <span className={`badge ${job?.status || ""}`}>{job?.status || "—"}</span>
          </h2>
          <div className="meta pre">
            {job
              ? `id=${job.id}\narea=${job.area} trigger=${job.trigger}\nmd5=${job.remote_md5 || "—"}\nstarted=${job.started_at || "—"} finished=${job.finished_at || "—"}\n${job.error ? `error=${job.error}` : ""}`
              : "No jobs yet"}
          </div>
          <h2 style={{ marginTop: "1rem" }}>Logs</h2>
          <div id="logs">
            {logs.map((line) => (
              <div key={line.id} className={line.level === "error" ? "log-err" : "log-info"}>
                {(line.ts || "").slice(11, 19)} [{line.level}] {line.message}
              </div>
            ))}
          </div>
        </section>
      </main>
    </>
  );
}
