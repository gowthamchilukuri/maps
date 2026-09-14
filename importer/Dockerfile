# Downloads Geofabrik/OSM.fr PBF and loads into PostGIS via osm2pgsql.
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
       osm2pgsql \
       postgresql-client \
       curl \
       ca-certificates \
       bash \
       git \
  && rm -rf /var/lib/apt/lists/*

# Carto style defines the planet_osm_* column layout Mapnik apps expect
RUN git clone --depth 1 --branch v5.9.0 \
      https://github.com/gravitystorm/openstreetmap-carto.git \
      /openstreetmap-carto \
  && rm -rf /openstreetmap-carto/.git

WORKDIR /app
COPY log.sh import.sh ./
RUN chmod +x /app/log.sh /app/import.sh

ENTRYPOINT ["/app/import.sh"]
