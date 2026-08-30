const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const source = fs.readFileSync(
  path.join(__dirname, "../mlx_workbench/static/app.js"),
  "utf8",
);

test("Convert Selected uses the visible control while preparing batch previews", () => {
  assert.match(
    source,
    /const button = \$\('queue-selected'\) \|\| \$\('convert-selected'\);/,
  );
});
