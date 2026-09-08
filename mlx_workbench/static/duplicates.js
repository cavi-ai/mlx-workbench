(function (root, factory) {
  const duplicates = factory();
  if (typeof module === 'object' && module.exports) module.exports = duplicates;
  if (root) root.MLXWorkbenchDuplicates = duplicates;
}(typeof globalThis === 'undefined' ? this : globalThis, function () {
  // Only exact groups are actionable (quarantine); variant groups are
  // informational and never get a removal affordance.
  function splitGroups(dupes) {
    const list = Array.isArray(dupes) ? dupes : [];
    return {
      exact: list.filter(function (group) { return group.kind === 'exact'; }),
      variant: list.filter(function (group) { return group.kind === 'variant'; }),
    };
  }

  return { splitGroups };
}));
