import { defineBackend } from "@aws-amplify/backend";
import { auth } from "./auth/resource";

/**
 * Amplify Gen2 backend for the admin console.
 * Auth only — Geofabrik import control API stays on API Gateway + Lambda.
 */
defineBackend({
  auth,
});
