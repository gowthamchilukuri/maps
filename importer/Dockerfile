# Geofabrik PBF → PostGIS (carto) + Planetiler→S3 + Nominatim DB (local PBF, no S3).
# Based on mediagis/nominatim so `nominatim import` is available in the same job.
FROM mediagis/nominatim:4.4

ARG PLANETILER_VERSION=0.8.4

USER root

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       curl \
       ca-certificates \
       bash \
       git \
       openjdk-17-jre-headless \
       unzip \
       python3 \
       python3-pip \
       postgresql-client \
  && pip3 install --break-system-packages --no-cache-dir awscli \
  && rm -rf /var/lib/apt/lists/*

# Carto style for planet_osm_* (map apps) — osm2pgsql is already in mediagis image
RUN git clone --depth 1 --branch v5.9.0 \
      https://github.com/gravitystorm/openstreetmap-carto.git \
      /openstreetmap-carto \
  && rm -rf /openstreetmap-carto/.git

# Planetiler fat jar (OSM → MBTiles → S3)
RUN mkdir -p /opt/planetiler \
  && curl -fsSL -o /opt/planetiler/planetiler.jar \
       "https://github.com/onthegomap/planetiler/releases/download/v${PLANETILER_VERSION}/planetiler.jar"

WORKDIR /app
COPY log.sh import.sh ./
COPY stages ./stages
RUN chmod +x /app/log.sh /app/import.sh /app/stages/*.sh

# Do not use mediagis default entrypoint (starts embedded Postgres / web).
ENTRYPOINT ["/app/import.sh"]
