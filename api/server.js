import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { apiHandler } from "./src/api.js";

const PORT = Number(process.env.PORT || 8092);
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const UI_DIR = process.env.UI_DIR || path.join(__dirname, "..", "ui");

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

/** Node request → API Gateway HTTP API v2 event (shared handler with Lambda). */
function toApiGatewayEvent(req, bodyBuf) {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  const queryStringParameters = {};
  for (const [k, v] of url.searchParams) queryStringParameters[k] = v;
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    headers[k] = Array.isArray(v) ? v.join(",") : String(v ?? "");
  }
  return {
    version: "2.0",
    routeKey: `${req.method} ${url.pathname}`,
    rawPath: url.pathname,
    rawQueryString: url.search.startsWith("?") ? url.search.slice(1) : url.search,
    headers,
    queryStringParameters:
      Object.keys(queryStringParameters).length > 0 ? queryStringParameters : null,
    requestContext: {
      http: {
        method: req.method || "GET",
        path: url.pathname,
        protocol: "HTTP/1.1",
        sourceIp: req.socket?.remoteAddress || "",
      },
      stage: "$default",
    },
    body: bodyBuf.length ? bodyBuf.toString("utf8") : null,
    isBase64Encoded: false,
  };
}

function contentType(filePath) {
  switch (path.extname(filePath).toLowerCase()) {
    case ".html":
      return "text/html; charset=utf-8";
    case ".js":
      return "application/javascript; charset=utf-8";
    case ".css":
      return "text/css; charset=utf-8";
    case ".json":
      return "application/json; charset=utf-8";
    default:
      return "application/octet-stream";
  }
}

function serveUi(req, res) {
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
  let rel = decodeURIComponent(url.pathname);
  if (rel === "/") rel = "/index.html";
  const root = path.resolve(UI_DIR);
  const filePath = path.resolve(root, "." + rel);
  if (!filePath.startsWith(root + path.sep) && filePath !== root) {
    res.writeHead(403).end("forbidden");
    return;
  }
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404).end("UI not found");
      return;
    }
    res.writeHead(200, { "content-type": contentType(filePath) });
    res.end(req.method === "HEAD" ? undefined : data);
  });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    if (url.pathname === "/api" || url.pathname.startsWith("/api/")) {
      const bodyBuf = await readBody(req);
      const result = await apiHandler(toApiGatewayEvent(req, bodyBuf));
      res.writeHead(result.statusCode || 200, result.headers || {});
      res.end(result.body ?? "");
      return;
    }
    if (req.method === "GET" || req.method === "HEAD") {
      serveUi(req, res);
      return;
    }
    res.writeHead(404, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "not found" }));
  } catch (e) {
    console.error(e);
    res.writeHead(500, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: e.message || String(e) }));
  }
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`sigeo-map-service control API listening on :${PORT} (admin UI: Amplify / ui npm run dev)`);
});
