import { mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";

import {
  OUTPUT_REL,
  PRODUCT_ID,
  REPO_ROOT,
  SOURCE_REL,
  UNRESOLVED_TOKEN,
  computeContentSha256,
  listFilesRecursive,
  navigationPaths,
  parseOptions,
  releaseInput,
  resolveReleaseIdentity,
  stampReleaseTokens,
} from "./lib.mjs";

async function exists(location) {
  try {
    await stat(location);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function expectedFiles(sourceRoot, release) {
  const values = new Map();
  const sourcePaths = await listFilesRecursive(sourceRoot);
  for (const sourcePath of sourcePaths) {
    const outputPath = sourcePath.startsWith("pages/") ? sourcePath.slice(6) : sourcePath;
    const stamped = stampReleaseTokens(await readFile(path.join(sourceRoot, sourcePath), "utf8"), release);
    if (UNRESOLVED_TOKEN.test(stamped)) throw new Error(`unresolved template token in ${sourcePath}`);
    values.set(outputPath, Buffer.from(stamped));
  }
  const navigation = JSON.parse(values.get("navigation.json").toString("utf8"));
  for (const page of navigationPaths(navigation)) {
    if (!values.has(page)) throw new Error(`navigation path missing: ${page}`);
  }
  return values;
}

/// Decide what to do with an existing output tree.
///
/// - Absent or byte-identical: nothing to do ("clean").
/// - Present with the exact same file set but stale content (a source edit
///   after the last build): regenerate in place so the build self-heals
///   instead of demanding a manual `rm -rf`.
/// - Present with extra or missing files: that is not stale output but an
///   artifact of a different schema or a stray write; refuse so a human
///   looks.
async function prepareOutputTree(outputRoot, expected) {
  if (!(await exists(outputRoot))) {
    for (const [relative, bytes] of expected) {
      const target = path.join(outputRoot, relative);
      await mkdir(path.dirname(target), { recursive: true });
      await writeFile(target, bytes, { flag: "wx" });
    }
    return "fresh";
  }
  const actualPaths = await listFilesRecursive(outputRoot);
  const expectedPaths = [...expected.keys(), "manifest.json"].sort();
  if (JSON.stringify(actualPaths) === JSON.stringify(expectedPaths)) {
    let clean = true;
    for (const [relative, bytes] of expected) {
      const actual = await readFile(path.join(outputRoot, relative));
      if (!actual.equals(bytes)) clean = false;
    }
    return clean ? "clean" : await regenerateOutputTree(outputRoot, expected);
  }
  throw new Error(`dirty output: ${outputRoot}`);
}

async function regenerateOutputTree(outputRoot, expected) {
  await rm(outputRoot, { recursive: true, force: true });
  for (const [relative, bytes] of expected) {
    const target = path.join(outputRoot, relative);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, bytes, { flag: "wx" });
  }
  return "regenerated";
}

export async function buildDocumentation(input = {}) {
  const release = resolveReleaseIdentity(input);
  const sourceRoot = path.resolve(input.sourceRoot ?? path.join(REPO_ROOT, SOURCE_REL));
  const outputRoot = path.resolve(input.outputRoot ?? path.join(REPO_ROOT, OUTPUT_REL));
  if (sourceRoot === outputRoot || outputRoot.startsWith(`${sourceRoot}${path.sep}`)) {
    throw new Error("documentation output must be outside the source tree");
  }
  const files = await expectedFiles(sourceRoot, release);
  const outputTree = await prepareOutputTree(outputRoot, files);
  const contentSha256 = await computeContentSha256(outputRoot, [...files.keys()]);
  const manifest = {
    schemaVersion: 2,
    package: PRODUCT_ID,
    product: PRODUCT_ID,
    version: release.version,
    contentSha256,
    publicBasePath: `/docs/${PRODUCT_ID}/v${release.version}`,
    stableAlias: `/docs/${PRODUCT_ID}`,
    release: {
      tag: release.tag,
      commit: release.commit,
    },
    generatedAt: release.generatedAt,
  };
  const manifestBytes = Buffer.from(`${JSON.stringify(manifest, null, 2)}\n`);
  const manifestPath = path.join(outputRoot, "manifest.json");
  if (outputTree === "clean") {
    const actual = await readFile(manifestPath);
    if (!actual.equals(manifestBytes)) throw new Error("dirty output: manifest.json");
  } else {
    await writeFile(manifestPath, manifestBytes, { flag: "wx" });
  }
  return { outputRoot, manifest };
}

if (process.argv[1] && import.meta.filename === process.argv[1]) {
  const values = parseOptions(process.argv.slice(2));
  buildDocumentation({
    ...releaseInput(values),
    ...(values.source ? { sourceRoot: path.resolve(values.source) } : {}),
    ...(values.output ? { outputRoot: path.resolve(values.output) } : {}),
  }).then(({ outputRoot }) => {
    process.stdout.write(`${outputRoot}\n`);
  }).catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
