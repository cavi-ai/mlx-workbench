"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const app = fs.readFileSync(path.join(root, "mlx_workbench/static/app.js"), "utf8");
const page = fs.readFileSync(path.join(root, "mlx_workbench/static/index.html"), "utf8");

test("Training Studio uses the confirmation-gated LoRA preview contract", () => {
  assert.match(page, /id="lora-form"/);
  assert.match(page, /id="lora-repo"/);
  assert.match(page, /id="lora-data"/);
  assert.doesNotMatch(page, /id="finetune-preview-form"/);
  assert.doesNotMatch(app, /\/api\/training\/preview/);
  assert.doesNotMatch(app, /Expected quality gain/);
  assert.match(app, /on\('lora-form', 'submit', previewLora\)/);
});
