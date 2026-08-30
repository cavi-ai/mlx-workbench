"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const root = path.resolve(__dirname, "..");
const app = fs.readFileSync(path.join(root, "mlx_workbench/static/app.js"), "utf8");

test("duplicate rendering distinguishes evidence-backed exact and variant groups", () => {
  assert.match(app, /group\.kind === 'exact'/);
  assert.match(app, /group\.redundant\.forEach/);
  assert.match(app, /group\.kind === 'variant'/);
  assert.match(app, /group\.members\.forEach/);
  assert.doesNotMatch(app, /group\.group_id/);
  assert.doesNotMatch(app, /group\.files/);
});
