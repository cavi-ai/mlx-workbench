const assert = require("node:assert/strict");
const test = require("node:test");

const { element, pill, notify } = require("../mlx_workbench/static/dom.js");

function fakeNode(tag) {
  return { tag, className: "", textContent: "", hidden: false };
}

function fakeDocument(nodes = {}) {
  return {
    createElement: (tag) => fakeNode(tag),
    getElementById: (id) => nodes[id] || null,
  };
}

test("element builds a node with class and text only when given", () => {
  const node = element(fakeDocument(), "div", "card", "hello");
  assert.equal(node.tag, "div");
  assert.equal(node.className, "card");
  assert.equal(node.textContent, "hello");

  const bare = element(fakeDocument(), "span");
  assert.equal(bare.className, "");
  assert.equal(bare.textContent, "");
});

test("pill renders the status into both class and text", () => {
  const node = pill(fakeDocument(), "running");
  assert.equal(node.tag, "span");
  assert.equal(node.className, "pill pill-running");
  assert.equal(node.textContent, "running");
});

test("notify shows and clears the notice", () => {
  const notice = fakeNode("div");
  const document = fakeDocument({ notice });

  notify(document, "notice", "scan complete");
  assert.equal(notice.textContent, "scan complete");
  assert.equal(notice.hidden, false);

  notify(document, "notice", "");
  assert.equal(notice.textContent, "");
  assert.equal(notice.hidden, true);
});

test("notify tolerates a missing notice node", () => {
  assert.doesNotThrow(() => notify(fakeDocument(), "notice", "x"));
});
