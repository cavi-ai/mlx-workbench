const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs');
const vm = require('node:vm');

test('quarantine renders native folder review without offering the web file purge', async () => {
  const source = fs.readFileSync(require.resolve('../mlx_workbench/static/app.js'), 'utf8');
  const renderer = source.slice(source.indexOf('async function renderQuarantined()'), source.indexOf('async function purgeQuarantined('));
  const element = (tag, cls, text) => ({ tag, text, children: [], appendChild(child) { this.children.push(child); }, addEventListener() {} });
  const container = element('div');
  const context = vm.createContext({
    $: () => container, element, bytes: String,
    api: async () => ({ records: [
      { exists: true, to: '/quarantine/file.gguf', bytes: 10 },
      { exists: true, to: '/quarantine/model', bytes: 20, kind: 'mlxDirectory' },
    ] }),
  });
  await vm.runInContext(renderer + '\nrenderQuarantined()', context);
  assert.equal(container.children[0].children.filter(node => node.tag === 'button').length, 1);
  assert.equal(container.children[1].children.filter(node => node.tag === 'button').length, 0);
  assert.match(container.children[1].children.at(-1).text, /native app/);
});
