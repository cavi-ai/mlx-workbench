const assert = require("node:assert/strict");
const test = require("node:test");

const { splitGroups } = require("../mlx_workbench/static/duplicates.js");

test("splitGroups separates actionable exact groups from informational variants", () => {
  const dupes = [
    { kind: "exact", model_key: "a" },
    { kind: "variant", model_key: "b" },
    { kind: "exact", model_key: "c" },
  ];
  const groups = splitGroups(dupes);
  assert.deepEqual(groups.exact.map((g) => g.model_key), ["a", "c"]);
  assert.deepEqual(groups.variant.map((g) => g.model_key), ["b"]);
});

test("splitGroups tolerates missing and non-array input", () => {
  assert.deepEqual(splitGroups(null), { exact: [], variant: [] });
  assert.deepEqual(splitGroups(undefined), { exact: [], variant: [] });
  assert.deepEqual(splitGroups({}), { exact: [], variant: [] });
});
