(function (root, factory) {
  const envelope = factory();
  if (typeof module === 'object' && module.exports) module.exports = envelope;
  if (root) root.MLXWorkbenchEnvelope = envelope;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  // The workbench API contract: {status: 'ok', data} or {status: 'error',
  // error: {message, remediation}}. unwrap throws on anything else.

  function unwrap(payload, httpStatus) {
    if (!payload || payload.status !== 'ok') {
      const error = (payload && payload.error) || {};
      throw new Error([error.message, error.remediation].filter(Boolean).join('\n') ||
        'Request failed (' + httpStatus + ').');
    }
    return payload.data;
  }

  return { unwrap };
}));
