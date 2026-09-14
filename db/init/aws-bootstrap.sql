-- Run once on RDS/Aurora as master user, connected to database `gis`.
\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;

CREATE SCHEMA IF NOT EXISTS control;

CREATE TABLE IF NOT EXISTS control.settings (
  id              integer PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  area            text        NOT NULL DEFAULT 'monaco',
  interval_hours  integer     NOT NULL DEFAULT 12 CHECK (interval_hours >= 1),
  enabled         boolean     NOT NULL DEFAULT true,
  updated_at      timestamptz NOT NULL DEFAULT now()
);

INSERT INTO control.settings (id, area, interval_hours, enabled)
VALUES (1, 'monaco', 12, true)
ON CONFLICT (id) DO NOTHING;

CREATE TABLE IF NOT EXISTS control.area_state (
  area       text PRIMARY KEY,
  md5        text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS control.jobs (
  id          uuid PRIMARY KEY,
  area        text        NOT NULL,
  status      text        NOT NULL,
  trigger     text        NOT NULL,
  remote_md5  text,
  local_md5   text,
  started_at  timestamptz,
  finished_at timestamptz,
  error       text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT jobs_status_check CHECK (
    status IN ('pending', 'running', 'success', 'failed', 'skipped')
  ),
  CONSTRAINT jobs_trigger_check CHECK (
    trigger IN ('manual', 'schedule', 'api')
  )
);

CREATE INDEX IF NOT EXISTS jobs_created_at_idx ON control.jobs (created_at DESC);
CREATE INDEX IF NOT EXISTS jobs_status_idx ON control.jobs (status);

CREATE TABLE IF NOT EXISTS control.job_logs (
  id      bigserial PRIMARY KEY,
  job_id  uuid        NOT NULL REFERENCES control.jobs (id) ON DELETE CASCADE,
  ts      timestamptz NOT NULL DEFAULT now(),
  level   text        NOT NULL DEFAULT 'info',
  message text        NOT NULL
);

CREATE INDEX IF NOT EXISTS job_logs_job_id_ts_idx ON control.job_logs (job_id, ts);
