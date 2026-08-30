(function (root, factory) {
  const navigation = factory();
  if (typeof module === 'object' && module.exports) module.exports = navigation;
  if (root) root.MLXWorkbenchNavigation = navigation;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  function selectPanel(document, name, panels) {
    panels.forEach(function (panel) {
      const panelNode = document.getElementById('panel-' + panel);
      if (panelNode) panelNode.hidden = panel !== name;
    });
    Array.prototype.forEach.call(document.querySelectorAll('.tab'), function (tab) {
      tab.classList.toggle('is-active', tab.dataset.panel === name);
    });
    const dropdown = document.querySelector('.more-dropdown');
    if (dropdown) dropdown.hidden = true;
  }

  return { selectPanel };
}));
