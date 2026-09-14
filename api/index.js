import { apiHandler } from "./src/api.js";
import { scheduledTick } from "./src/jobs.js";

/** API Gateway HTTP API → control REST API */
export async function handler(event, context) {
  context.callbackWaitsForEmptyEventLoop = false;
  return apiHandler(event);
}

/** EventBridge schedule → maybe start importer */
export async function schedulerHandler(event, context) {
  context.callbackWaitsForEmptyEventLoop = false;
  console.log("scheduler event", JSON.stringify(event));
  const result = await scheduledTick();
  console.log("scheduler result", JSON.stringify(result));
  return result;
}
