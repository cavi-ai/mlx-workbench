const assert = require("node:assert/strict");
const test = require("node:test");

const { selectPanel } = require("../mlx_workbench/static/navigation.js");

function makeDocument() {
  const panelNames = ["models", "training-studio"];
  const panels = new Map(panelNames.map((name) => [
    `panel-${name}`,
    { hidden: name !== "models" },
  ]));
  const tabs = [
    { dataset: { panel: "models" }, classList: makeClassList(true) },
    { dataset: { panel: "training-studio" }, classList: makeClassList(false) },
    { dataset: {}, classList: makeClassList(false) },
  ];
  const dropdown = { hidden: false };
  return {
    dropdown,
    panels,
    tabs,
    getElementById(id) { return panels.get(id) || null; },
    querySelector(selector) {
      return selector === ".more-dropdown" ? dropdown : null;
    },
    querySelectorAll(selector) {
      return selector === ".tab" ? tabs : [];
    },
  };
}

function makeClassList(active) {
  return {
    active,
    toggle(name, next) {
      if (name === "is-active") this.active = next;
    },
  };
}

test("selectPanel hides More after selecting a secondary screen", () => {
  const document = makeDocument();

  selectPanel(document, "training-studio", ["models", "training-studio"]);

  assert.equal(document.dropdown.hidden, true);
  assert.equal(document.panels.get("panel-models").hidden, true);
  assert.equal(document.panels.get("panel-training-studio").hidden, false);
  assert.equal(document.tabs[0].classList.active, false);
  assert.equal(document.tabs[1].classList.active, true);
});
