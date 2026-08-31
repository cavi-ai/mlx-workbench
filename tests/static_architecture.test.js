const assert = require("node:assert/strict");
const test = require("node:test");

const { architectureFacts } = require("../mlx_workbench/static/architecture.js");

test("architectureFacts renders only scan metadata that is actually reported", () => {
  const facts = architectureFacts({
    architecture: "qwen35",
    quantization: "Q8_0",
    tensor_count: 866,
    bytes: 29_047_084_448,
  }, (value) => `${value} bytes`);

  assert.deepEqual(facts, [
    ["Architecture", "qwen35"],
    ["Quantization", "Q8_0"],
    ["Tensors", "866"],
    ["Size", "29047084448 bytes"],
  ]);
});
