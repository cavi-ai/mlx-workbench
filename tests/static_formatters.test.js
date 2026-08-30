const assert = require("node:assert/strict");
const test = require("node:test");

const { bytes } = require("../mlx_workbench/static/formatters.js");

test("bytes distinguishes a real zero from an unavailable size", () => {
  assert.equal(bytes(0), "0B");
  assert.equal(bytes(null), "—");
  assert.equal(bytes(undefined), "—");
  assert.equal(bytes(2_684_354_560), "2.5GB");
});
