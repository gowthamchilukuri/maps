import { ECSClient, RunTaskCommand } from "@aws-sdk/client-ecs";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { flatNodesFor } from "./areas.js";
import { query } from "./db.js";

const region =
  process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || "eu-central-1";

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

export async function runningJobId() {
  const { rows } = await query(
    `SELECT id::text FROM control.jobs
     WHERE status IN ('pending','running')
     ORDER BY created_at DESC LIMIT 1`
  );
  return rows[0]?.id || null;
}

export async function createJob(area, trigger) {
  const jobId = randomUUID();
  await query(
    `INSERT INTO control.jobs (id, area, status, trigger, created_at)
     VALUES ($1::uuid, $2, 'pending', $3, now())`,
    [jobId, area, trigger]
  );
  return jobId;
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
              { name: "CACHE_MB", value: process.env.CACHE_MB || "2048" },
              { name: "FLAT_NODES", value: flatNodesFor(area) },
              { name: "PGSSLMODE", value: process.env.PGSSLMODE || "require" },
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
    `CACHE_MB=${process.env.CACHE_MB || "2048"}`,
    "-e",
    `FLAT_NODES=${flatNodesFor(area)}`,
    "-v",
    `${hostDir}/data/pbf:/pbf`,
    "-v",
    `${hostDir}/data/import-tmp:/tmp/osm2pgsql`,
    image,
  ];
  const child = spawn("docker", args, { stdio: "ignore", detached: true });
  child.unref();
  return { backend: "docker", image };
}

export async function startImporter(jobId, area, force = false) {
  if (importBackend() === "ecs") return startImporterEcs(jobId, area, force);
  return startImporterDocker(jobId, area, force);
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
