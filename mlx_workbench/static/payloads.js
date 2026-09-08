(function (root, factory) {
  const payloads = factory();
  if (typeof module === 'object' && module.exports) module.exports = payloads;
  if (root) root.MLXWorkbenchPayloads = payloads;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  function tokenize(value) {
    return value.trim().split(/\s+/).filter(Boolean);
  }

  // Confirmation body for a reviewed conversion plan: exactly one of path
  // (GGUF source) or repo (HF cache source), never both.
  function convertStartBody(plan) {
    const body = {
      q_bits: plan.q_bits,
      out: plan.out,
      preview_hash: plan.preview_hash,
    };
    if (plan.source && plan.source.path) {
      body.path = plan.source.path;
    } else if (plan.repo) {
      body.repo = plan.repo;
    }
    return body;
  }

  return { tokenize, convertStartBody };
}));
