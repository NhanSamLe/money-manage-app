// Fails if the version recorded in VERSION differs from any packaged component.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const read = (p) => readFileSync(join(root, p), "utf8");
const SEMVER = /^\d+\.\d+\.\d+$/;

const expected = read("VERSION").trim();
if (!SEMVER.test(expected)) fail(`VERSION is not MAJOR.MINOR.PATCH: "${expected}"`);

const found = {
  "apps/api/package.json": JSON.parse(read("apps/api/package.json")).version,
  "apps/api/src/shared/version.ts": /API_VERSION\s*=\s*"([^"]+)"/.exec(read("apps/api/src/shared/version.ts"))?.[1],
  "apps/android/pubspec.yaml": /^version:\s*(\d+\.\d+\.\d+)\+\d+\s*$/m.exec(read("apps/android/pubspec.yaml"))?.[1],
};

const bad = Object.entries(found).filter(([, v]) => v !== expected);
if (bad.length > 0) fail(bad.map(([f, v]) => `${f}: ${v ?? "not found"} (expected ${expected})`).join("\n"));
console.log(`OK: all components at ${expected}`);

function fail(msg) {
  console.error(`Version mismatch:\n${msg}`);
  process.exit(1);
}
