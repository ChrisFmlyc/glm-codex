// Validate /v1/models and emit one tab-separated ID/context row per model.
// A context of 0 means the server does not advertise max_model_len.
const fs = require("node:fs");
try {
  const body = JSON.parse(fs.readFileSync(0, "utf8"));
  if (!Array.isArray(body.data) || body.data.length === 0) {
    throw new Error("expected a non-empty data array");
  }
  const rows = body.data.map((model) => {
    if (!model || typeof model.id !== "string" || !model.id || /[\x00-\x1f\x7f]/.test(model.id)) {
      throw new Error("each model must have a non-empty string id without control characters");
    }
    const ctx = model.max_model_len;
    if (ctx !== undefined && (!Number.isSafeInteger(ctx) || ctx <= 0)) {
      throw new Error("max_model_len must be a positive integer when provided");
    }
    return `${model.id}\t${ctx ?? 0}`;
  });
  process.stdout.write(rows.join("\n") + "\n");
} catch (error) {
  // Do not echo the endpoint's response: it may contain sensitive information.
  console.error("ERROR: invalid /v1/models response. Expected model IDs and optional positive max_model_len values.");
  process.exitCode = 1;
}
