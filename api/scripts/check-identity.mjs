// Fails when vars.APPLE_APP_BUNDLE_ID in wrangler.jsonc differs from
// APP_BUNDLE_ID in ../app-identity.xcconfig. Runs as part of `npm test`.
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const xcconfigPath = resolve(here, "../../app-identity.xcconfig");
const wranglerPath = resolve(here, "../wrangler.jsonc");

function fail(message) {
  console.error(`check-identity: ${message}`);
  process.exit(1);
}

// JSONC to JSON: drop comments outside strings, then trailing commas.
function stripJsonc(text) {
  let out = "";
  let inString = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    const next = text[i + 1];
    if (inString) {
      out += ch;
      if (ch === "\\") out += text[++i] ?? "";
      else if (ch === '"') inString = false;
    } else if (ch === '"') {
      inString = true;
      out += ch;
    } else if (ch === "/" && next === "/") {
      while (i < text.length && text[i] !== "\n") i++;
      out += "\n";
    } else if (ch === "/" && next === "*") {
      const end = text.indexOf("*/", i + 2);
      i = end === -1 ? text.length : end + 1;
    } else {
      out += ch;
    }
  }
  return out.replace(/,(\s*[}\]])/g, "$1");
}

const xcconfig = readFileSync(xcconfigPath, "utf8");
const match = xcconfig.match(/^\s*APP_BUNDLE_ID\s*=\s*(\S+)\s*$/m);
if (!match) fail(`APP_BUNDLE_ID not found in ${xcconfigPath}`);
const expected = match[1];

let wrangler;
try {
  wrangler = JSON.parse(stripJsonc(readFileSync(wranglerPath, "utf8")));
} catch (error) {
  fail(`could not parse ${wranglerPath}: ${error.message}`);
}
const actual = wrangler?.vars?.APPLE_APP_BUNDLE_ID;

if (actual !== expected) {
  fail(
    `bundle ID mismatch: wrangler.jsonc vars.APPLE_APP_BUNDLE_ID is ${JSON.stringify(actual)}, ` +
      `app-identity.xcconfig APP_BUNDLE_ID is ${JSON.stringify(expected)}. ` +
      "Change wrangler.jsonc to match app-identity.xcconfig.",
  );
}
console.log(`check-identity: bundle ID ${expected} matches`);
