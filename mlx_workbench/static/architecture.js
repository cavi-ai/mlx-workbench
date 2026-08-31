(function (root, factory) {
  const architecture = factory();
  if (typeof module === 'object' && module.exports) module.exports = architecture;
  if (root) root.MLXWorkbenchArchitecture = architecture;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  function architectureFacts(architecture, formatBytes) {
    const facts = [];
    if (architecture.architecture) facts.push(['Architecture', String(architecture.architecture)]);
    if (architecture.quantization) facts.push(['Quantization', String(architecture.quantization)]);
    if (Number.isInteger(architecture.tensor_count) && architecture.tensor_count >= 0) {
      facts.push(['Tensors', String(architecture.tensor_count)]);
    }
    if (typeof architecture.bytes === 'number' && Number.isFinite(architecture.bytes) && architecture.bytes >= 0) {
      facts.push(['Size', formatBytes(architecture.bytes)]);
    }
    return facts;
  }

  return { architectureFacts };
}));
