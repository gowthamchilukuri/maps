import { SecretsManagerClient, GetSecretValueCommand } from "@aws-sdk/client-secrets-manager";
import pg from "pg";

const { Pool } = pg;

let pool;
let cachedUrl;

function wantsSsl(connectionString) {
  const mode = (process.env.PGSSLMODE || "").toLowerCase();
  if (mode === "disable") return false;
  if (["require", "verify-full", "verify-ca", "no-verify"].includes(mode)) return true;
  if (/[?&]sslmode=(require|verify-full|verify-ca|no-verify)/i.test(connectionString || "")) {
    return true;
  }
  // Secrets Manager / RDS path
  if (!process.env.DATABASE_URL) return true;
  return false;
}

function stripSslMode(connectionString) {
  try {
    const u = new URL(connectionString);
    u.searchParams.delete("sslmode");
    u.searchParams.delete("sslrootcert");
    return u.toString();
  } catch {
    return connectionString.replace(/([?&])sslmode=[^&]*/gi, "$1").replace(/[?&]$/, "");
  }
}

async function resolveDatabaseUrl() {
  if (process.env.DATABASE_URL) return process.env.DATABASE_URL;
  if (cachedUrl) return cachedUrl;
  const secretId = process.env.DB_SECRET_ARN || process.env.DB_SECRET_NAME || "sigeo-map/db";
  const region =
    process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION || "eu-central-1";
  const client = new SecretsManagerClient({ region });
  const out = await client.send(new GetSecretValueCommand({ SecretId: secretId }));
  const s = JSON.parse(out.SecretString);
  const user = encodeURIComponent(s.username);
  const password = encodeURIComponent(s.password);
  const host = s.host;
  const port = s.port || 5432;
  const dbname = s.dbname || "gis";
  cachedUrl = `postgresql://${user}:${password}@${host}:${port}/${dbname}`;
  return cachedUrl;
}

export async function getPool() {
  if (pool) return pool;
  const raw = await resolveDatabaseUrl();
  pool = new Pool({
    connectionString: stripSslMode(raw),
    ssl: wantsSsl(raw) ? { rejectUnauthorized: false } : false,
    max: 2,
    idleTimeoutMillis: 10_000,
  });
  return pool;
}

export async function query(text, params = []) {
  const p = await getPool();
  return p.query(text, params);
}

export function publicDbHost() {
  const url = process.env.DATABASE_URL || cachedUrl || "";
  const at = url.lastIndexOf("@");
  return at >= 0 ? url.slice(at + 1) : url || "secrets-manager";
}
