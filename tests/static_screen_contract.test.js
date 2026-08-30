"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const page = fs.readFileSync(path.join(root, "mlx_workbench/static/index.html"), "utf8");
const views = require(path.join(root, "mlx_workbench/static/library_views.js"));

test("duplicate and model detail screens use the current scan contract", () => {
  assert.equal(views.duplicateScanMessage(null), "Run a duplicate scan to check the configured GGUF roots.");
  assert.equal(views.duplicateScanMessage([]), "No duplicate filenames found.");
  assert.equal(views.duplicateScanMessage([{ group_id: "same.gguf" }]), null);
  assert.deepEqual(
    views.modelDetailsFacts({
      path: "/models/example.gguf",
      status: "pending",
      architecture: "qwen35",
      quantization: "Q8_0",
      bytes: 42,
    }, (value) => value + "B"),
    [
      ["Local path", "/models/example.gguf"],
      ["Status", "pending"],
      ["Architecture", "qwen35"],
      ["Quantization", "Q8_0"],
      ["Size", "42B"],
    ],
  );
  assert.match(page, /matching filenames/);
  assert.doesNotMatch(page, /Variant Duplicates/);
  assert.match(page, /id="dialog" class="dialog" role="dialog" aria-modal="true"/);
  assert.match(page, /id="model-details-modal" class="dialog" role="dialog" aria-modal="true"/);
});
