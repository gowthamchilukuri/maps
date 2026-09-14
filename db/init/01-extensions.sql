\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS hstore;

ALTER TABLE IF EXISTS public.geometry_columns OWNER TO _renderd;
ALTER TABLE IF EXISTS public.spatial_ref_sys OWNER TO _renderd;
