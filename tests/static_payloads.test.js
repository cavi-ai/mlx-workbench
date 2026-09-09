const assert = require("node:assert/strict");
const test = require("node:test");

const { tokenize, convertStartBody } = require("../mlx_workbench/static/payloads.js");

test("tokenize splits on whitespace and drops empties", () => {
  assert.deepEqual(tokenize("  a  b\tc\n"), ["a", "b", "c"]);
  assert.deepEqual(tokenize(""), []);
});

test("convertStartBody carries the GGUF path from the plan source", () => {
  const body = convertStartBody({
    q_bits: 4, out: "/out/model", preview_hash: "h", source: { path: "/models/x.gguf" },
  });
  assert.deepEqual(body, { q_bits: 4, out: "/out/model", preview_hash: "h", path: "/models/x.gguf" });
  assert.equal("repo" in body, false);
});

test("convertStartBody carries the repo when there is no source path", () => {
  const body = convertStartBody({
    q_bits: 8, out: null, preview_hash: "h", repo: "org/model",
  });
  assert.deepEqual(body, { q_bits: 8, out: null, preview_hash: "h", repo: "org/model" });
  assert.equal("path" in body, false);
});

test("convertStartBody never emits both path and repo", () => {
  const body = convertStartBody({
    q_bits: 4, out: null, preview_hash: "h", source: { path: "/x.gguf" }, repo: "org/model",
  });
  assert.equal("path" in body, true);
  assert.equal("repo" in body, false);
});
