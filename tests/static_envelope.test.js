const assert = require("node:assert/strict");
const test = require("node:test");

const { unwrap } = require("../mlx_workbench/static/envelope.js");

test("unwrap returns data for an ok envelope", () => {
  assert.deepEqual(unwrap({ status: "ok", data: { a: 1 } }, 200), { a: 1 });
});

test("unwrap joins message and remediation for error envelopes", () => {
  assert.throws(
    () => unwrap({ status: "error", error: { message: "bad plan", remediation: "Preview first." } }, 400),
    (error) => error.message === "bad plan\nPreview first.",
  );
});

test("unwrap surfaces the http status when the payload is unusable", () => {
  assert.throws(() => unwrap(null, 502), /Request failed \(502\)\./);
  assert.throws(() => unwrap({ status: "error", error: {} }, 500), /Request failed \(500\)\./);
});
