(function (root, factory) {
  const formatters = factory();
  if (typeof module === 'object' && module.exports) module.exports = formatters;
  if (root) root.MLXWorkbenchFormatters = formatters;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  function bytes(count) {
    if (typeof count !== 'number' || !Number.isFinite(count) || count < 0) return '—';
    let value = count;
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    let index = 0;
    while (value >= 1024 && index < units.length - 1) { value /= 1024; index += 1; }
    return value.toFixed(value >= 10 || index === 0 ? 0 : 1) + units[index];
  }

  return { bytes };
}));
