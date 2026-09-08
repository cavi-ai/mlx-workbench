(function (root, factory) {
  const dom = factory();
  if (typeof module === 'object' && module.exports) module.exports = dom;
  if (root) root.MLXWorkbenchDOM = dom;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  // DOM helpers take the document explicitly so tests can stub it.

  function element(document, tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function pill(document, status) {
    return element(document, 'span', 'pill pill-' + status, status);
  }

  function notify(document, id, message) {
    const notice = document.getElementById(id);
    if (!notice) return;
    notice.textContent = message || '';
    notice.hidden = !message;
  }

  return { element, pill, notify };
}));
