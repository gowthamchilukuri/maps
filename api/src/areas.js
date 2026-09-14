/** Known Geofabrik / OSM.fr extracts. */
export const AREA_PRESETS = [
  { id: "monaco", label: "Monaco (tiny smoke test)", hint: "~1 MB" },
  { id: "centro", label: "Italy Centro (includes Rome)", hint: "~120 MB" },
  { id: "rome", label: "Rome (alias → centro)", hint: "same as centro" },
  { id: "italy", label: "Italy (full)", hint: "large" },
  { id: "isole", label: "Isole", hint: "OSM.fr" },
  { id: "nord-est", label: "Nord-Est", hint: "Geofabrik" },
  { id: "nord-ovest", label: "Nord-Ovest", hint: "Geofabrik" },
  { id: "sud", label: "Sud", hint: "Geofabrik" },
];

export function normalizeArea(raw) {
  const a = String(raw || "")
    .trim()
    .toLowerCase()
    .replace(/^\/+|\/+$/g, "");
  if (!a) return "monaco";
  if (a === "rome") return "centro";
  return a;
}

/** Use flat-nodes for larger extracts (saves RAM on osm2pgsql). */
export function flatNodesFor(area) {
  const a = normalizeArea(area);
  if (["monaco"].includes(a)) return "false";
  return "true";
}
