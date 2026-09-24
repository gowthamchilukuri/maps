import { ECSClient, RunTaskCommand, StopTaskCommand } from "@aws-sdk/client-ecs";
import { spawnSync } from "node:child_process";
import { randomUUID } from "node:crypto";
import { flatNodesFor } from "./areas.js";
import { query } from "./db.js";

const region =
  process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || "eu-central-1";

let schemaReady = false;
async function ensureJobSchema() {
  if (schemaReady) return;
  await query(`ALTER TABLE control.jobs ADD COLUMN IF NOT EXISTS task_ref text`);
  await query(`ALTER TABLE control.jobs DROP CONSTRAINT IF EXISTS jobs_status_check`);
  await query(`
    ALTER TABLE control.jobs ADD CONSTRAINT jobs_status_check CHECK (
      status IN ('pending', 'running', 'success', 'failed', 'skipped', 'cancelled')
    )
  `);
  schemaReady = true;
}

export function importBackend() {
  const explicit = (process.env.IMPORT_BACKEND || "").toLowerCase().trim();
  if (explicit) return explicit;
  if (process.env.ECS_CLUSTER || process.env.AWS_EXECUTION_ENV) return "ecs";
  return "docker";
}

export async function getSettings() {
  const { rows } = await query(
    "SELECT area, interval_hours, enabled, updated_at FROM control.settings WHERE id = 1"
  );
  if (!rows[0]) {
    return {
      area: process.env.DEFAULT_AREA || "monaco",
      interval_hours: Number(process.env.DEFAULT_INTERVAL_HOURS || 12),
      enabled: true,
      updated_at: null,
    };
  }
  const r = rows[0];
  return {
    area: r.area,
    interval_hours: r.interval_hours,
    enabled: r.enabled,
    updated_at: r.updated_at ? new Date(r.updated_at).toISOString() : null,
  };
}

export async function setSchedulerEnabled(enabled) {
  const cur = await getSettings();
  await query(
    `INSERT INTO control.settings (id, area, interval_hours, enabled, updated_at)
     VALUES (1, $1, $2, $3, now())
     ON CONFLICT (id) DO UPDATE
       SET enabled = EXCLUDED.enabled, updated_at = now()`,
    [cur.area, cur.interval_hours, Boolean(enabled)]
  );
  return getSettings();
}

export async function runningJobId() {
  const { rows } = await query(
    `SELECT id::text FROM control.jobs
     WHERE status IN ('pending','running')
     ORDER BY created_at DESC LIMIT 1`
  );
  return rows[0]?.id || null;
}

export async function createJob(area, trigger) {
  await ensureJobSchema();
  const jobId = randomUUID();
  await query(
    `INSERT INTO control.jobs (id, area, status, trigger, created_at)
     VALUES ($1::uuid, $2, 'pending', $3, now())`,
    [jobId, area, trigger]
  );
  return jobId;
}

async function saveTaskRef(jobId, taskRef) {
  await ensureJobSchema();
  if (!taskRef) return;
  await query(`UPDATE control.jobs SET task_ref = $2 WHERE id = $1::uuid`, [
    jobId,
    taskRef,
  ]);
}

async function startImporterEcs(jobId, area, force = false) {
  const cluster = process.env.ECS_CLUSTER;
  const taskDef = process.env.ECS_TASK_DEFINITION || "sigeo-map-importer";
  const subnets = (process.env.ECS_SUBNETS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  const securityGroups = (process.env.ECS_SECURITY_GROUPS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (!cluster || !subnets.length || !securityGroups.length) {
    const err = new Error("ECS_CLUSTER, ECS_SUBNETS, ECS_SECURITY_GROUPS are required");
    err.statusCode = 500;
    throw err;
  }
  const client = new ECSClient({ region });
  const out = await client.send(
    new RunTaskCommand({
      cluster,
      launchType: "FARGATE",
      taskDefinition: taskDef,
      networkConfiguration: {
        awsvpcConfiguration: {
          subnets,
          securityGroups,
          assignPublicIp: (process.env.ECS_ASSIGN_PUBLIC_IP || "ENABLED").toUpperCase(),
        },
      },
      overrides: {
        containerOverrides: [
          {
            name: process.env.ECS_CONTAINER_NAME || "importer",
            environment: [
              { name: "OSM_AREA", value: area },
              { name: "FORCE", value: force ? "true" : "false" },
              { name: "JOB_ID", value: jobId },
              { name: "CACHE_MB", value: process.env.CACHE_MB || "1024" },
              { name: "FLAT_NODES", value: flatNodesFor(area) },
              { name: "PGSSLMODE", value: process.env.PGSSLMODE || "require" },
              {
                name: "ENABLE_OSM2PGSQL",
                value: process.env.ENABLE_OSM2PGSQL || "true",
              },
              {
                name: "ENABLE_PLANETILER",
                value: process.env.ENABLE_PLANETILER || "false",
              },
              {
                name: "ENABLE_NOMINATIM",
                value: process.env.ENABLE_NOMINATIM || "false",
              },
              {
                name: "MBTILES_S3_BUCKET",
                value: process.env.MBTILES_S3_BUCKET || "",
              },
              {
                name: "MBTILES_S3_PREFIX",
                value: process.env.MBTILES_S3_PREFIX || "mbtiles",
              },
              {
                name: "NOMINATIM_PGHOST",
                value: process.env.NOMINATIM_PGHOST || "",
              },
              {
                name: "NOMINATIM_PGUSER",
                value: process.env.NOMINATIM_PGUSER || "nominatim",
              },
              {
                name: "NOMINATIM_PGPASSWORD",
                value: process.env.NOMINATIM_PGPASSWORD || "",
              },
              {
                name: "NOMINATIM_PGDATABASE",
                value: process.env.NOMINATIM_PGDATABASE || "nominatim",
              },
              {
                name: "PLANETILER_JAVA_OPTS",
                value: process.env.PLANETILER_JAVA_OPTS || "-Xmx4g",
              },
            ],
          },
        ],
      },
    })
  );
  const taskArn = out.tasks?.[0]?.taskArn || null;
  if (!taskArn) {
    const reason = out.failures?.[0]?.reason || "RunTask returned no task";
    const err = new Error(reason);
    err.statusCode = 500;
    throw err;
  }
  await saveTaskRef(jobId, taskArn);
  return { backend: "ecs", taskArn };
}

function startImporterDocker(jobId, area, force = false) {
  const image = process.env.IMPORTER_IMAGE || "sigeo-map-importer:latest";
  const network = process.env.DOCKER_NETWORK || "sigeo-map-net";
  const hostDir = process.env.HOST_PROJECT_DIR;
  if (!hostDir) {
    const err = new Error("HOST_PROJECT_DIR is required for docker backend");
    err.statusCode = 500;
    throw err;
  }
  const args = [
    "run",
    "-d",
    "--rm",
    "--network",
    network,
    "-e",
    `PGHOST=postgis`,
    "-e",
    `PGPORT=5432`,
    "-e",
    `PGDATABASE=${process.env.PGDATABASE || "gis"}`,
    "-e",
    `PGUSER=${process.env.PGUSER || "_renderd"}`,
    "-e",
    `PGPASSWORD=${process.env.PGPASSWORD || ""}`,
    "-e",
    `OSM_AREA=${area}`,
    "-e",
    `FORCE=${force ? "true" : "false"}`,
    "-e",
    `JOB_ID=${jobId}`,
    "-e",
    `CACHE_MB=${process.env.CACHE_MB || "1024"}`,
    "-e",
    `FLAT_NODES=${flatNodesFor(area)}`,
    "-v",
    `${hostDir}/data/pbf:/pbf`,
    "-v",
    `${hostDir}/data/import-tmp:/tmp/osm2pgsql`,
    image,
  ];
  const result = spawnSync("docker", args, { encoding: "utf8" });
  if (result.status !== 0) {
    const err = new Error(result.stderr || result.stdout || "docker run failed");
    err.statusCode = 500;
    throw err;
  }
  const containerId = (result.stdout || "").trim();
  saveTaskRef(jobId, containerId).catch(() => {});
  return { backend: "docker", image, containerId };
}

export async function startImporter(jobId, area, force = false) {
  if (importBackend() === "ecs") return startImporterEcs(jobId, area, force);
  return startImporterDocker(jobId, area, force);
}

/** Stop a pending/running import (ECS StopTask or docker stop). */
export async function stopImporter(jobId) {
  await ensureJobSchema();
  const { rows } = await query(
    `SELECT id::text, status, task_ref
     FROM control.jobs WHERE id = $1::uuid`,
    [jobId]
  );
  const job = rows[0];
  if (!job) {
    const err = new Error("job not found");
    err.statusCode = 404;
    throw err;
  }
  if (!["pending", "running"].includes(job.status)) {
    const err = new Error(`job is already ${job.status}`);
    err.statusCode = 409;
    throw err;
  }

  const backend = importBackend();
  if (backend === "ecs") {
    const cluster = process.env.ECS_CLUSTER;
    if (!cluster) {
      const err = new Error("ECS_CLUSTER is required to stop tasks");
      err.statusCode = 500;
      throw err;
    }
    if (!job.task_ref) {
      const err = new Error(
        "No ECS task ARN stored for this job (started before stop support). Stop it in ECS console."
      );
      err.statusCode = 409;
      throw err;
    }
    const client = new ECSClient({ region });
    await client.send(
      new StopTaskCommand({
        cluster,
        task: job.task_ref,
        reason: "Stopped from Sigeo map console",
      })
    );
  } else if (job.task_ref) {
    spawnSync("docker", ["stop", job.task_ref], { encoding: "utf8" });
  }

  await query(
    `UPDATE control.jobs
     SET status = 'cancelled', finished_at = now(),
         error = COALESCE(error, 'stopped by user')
     WHERE id = $1::uuid`,
    [jobId]
  );
  await query(
    `INSERT INTO control.job_logs (job_id, level, message)
     VALUES ($1::uuid, 'info', 'Job cancelled by user')`,
    [jobId]
  );
  return { job_id: jobId, status: "cancelled", backend };
}

export async function scheduledTick() {
  const settings = await getSettings();
  if (!settings.enabled) return { action: "skip", reason: "disabled" };
  if (await runningJobId()) return { action: "skip", reason: "already_running" };

  const { rows } = await query(
    `SELECT EXTRACT(EPOCH FROM (now() - finished_at)) / 3600.0 AS age
     FROM control.jobs
     WHERE status IN ('success', 'skipped')
     ORDER BY finished_at DESC NULLS LAST
     LIMIT 1`
  );
  const age = rows[0]?.age != null ? Number(rows[0].age) : null;
  if (age != null && age < settings.interval_hours) {
    return { action: "skip", reason: "interval_not_elapsed", age_hours: age };
  }

  const jobId = await createJob(settings.area, "schedule");
  const meta = await startImporter(jobId, settings.area, false);
  return { action: "started", job_id: jobId, area: settings.area, ...meta };
}
