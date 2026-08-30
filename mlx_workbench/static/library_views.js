(function (root, factory) {
  const views = factory();
  if (typeof module === 'object' && module.exports) module.exports = views;
  if (root) root.MLXWorkbenchLibraryViews = views;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  function duplicateScanMessage(duplicates) {
    if (duplicates === null) return 'Run a duplicate scan to check the configured GGUF roots.';
    if (Array.isArray(duplicates) && duplicates.length === 0) return 'No duplicate filenames found.';
    return null;
  }

  function modelDetailsFacts(model, formatBytes) {
    return [
      ['Local path', model.path],
      ['Status', model.status || 'unknown'],
      ['Architecture', model.architecture || '—'],
      ['Quantization', model.quantization || '—'],
      ['Size', formatBytes(model.bytes)],
    ];
  }

  return { duplicateScanMessage, modelDetailsFacts };
}));
