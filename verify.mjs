#!/usr/bin/env node
// Reproduces the submitted build: compiles build/standard-json-input.json (the exact compiler input in the launch
// request) with solc 0.8.26+commit.8a97fa7a and checks that
//   1. every source in that input is byte-identical to the file at the same path in this repo, and
//   2. the creation and runtime bytecode equal build/artifacts/*.json (the artifacts in the request).
//
//   node verify.mjs [path-to-solc-0.8.26]        (default: solc-0.8.26 installed by foundry's svm)
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { createHash } from "node:crypto";

const here = new URL(".", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const home = process.env.HOME || process.env.USERPROFILE || "";
const candidates = [
  process.argv[2],
  join(process.env.APPDATA || "", "svm/0.8.26/solc-0.8.26.exe"),
  join(process.env.APPDATA || "", "svm/0.8.26/solc-0.8.26"),
  join(home, ".svm/0.8.26/solc-0.8.26"),
  join(home, ".foundry/svm/0.8.26/solc-0.8.26"),
].filter(Boolean);
const solc = candidates.find((f) => existsSync(f));
if (!solc) { console.error("solc 0.8.26 not found: run `forge build` once (installs it) or pass its path"); process.exit(1); }

const inputText = readFileSync(join(here, "build/standard-json-input.json"), "utf8");
const input = JSON.parse(inputText);
console.log(`input sha256 ${createHash("sha256").update(inputText).digest("hex")}`);
let failures = 0;
for (const [path, { content }] of Object.entries(input.sources)) {
  const file = join(here, path);
  if (!existsSync(file) || readFileSync(file, "utf8") !== content) { console.log(`FAIL source ${path} differs from the repo file`); failures++; }
}
console.log(`${Object.keys(input.sources).length} sources checked against the repo files`);

const version = spawnSync(solc, ["--version"], { encoding: "utf8" }).stdout;
if (!/0\.8\.26\+commit\.8a97fa7a/.test(version)) { console.error(`wrong solc: ${version}`); process.exit(1); }
const out = JSON.parse(spawnSync(solc, ["--standard-json"], { input: inputText, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 }).stdout);
const errors = (out.errors || []).filter((e) => e.severity === "error");
if (errors.length) { console.error(errors.map((e) => e.formattedMessage).join("\n")); process.exit(1); }

const where = { HolderVault: "src/HolderVault.sol", GenerativeHook: "src/GenerativeHook.sol", GenerativeInitializer: "src/GenerativeInitializer.sol", GenerativeToken: "src/GenerativeToken.sol" };
for (const f of readdirSync(join(here, "build/artifacts"))) {
  const name = f.replace(/\.json$/, "");
  const art = JSON.parse(readFileSync(join(here, "build/artifacts", f), "utf8"));
  const c = out.contracts[where[name]]?.[name];
  const same = c && `0x${c.evm.bytecode.object}`.replace(/^0x0x/, "0x") === `0x${art.bytecode.object.replace(/^0x/, "")}`
    && `0x${c.evm.deployedBytecode.object}`.replace(/^0x0x/, "0x") === `0x${art.deployedBytecode.object.replace(/^0x/, "")}`;
  console.log(`${same ? "PASS" : "FAIL"} ${name} creation + runtime bytecode match the submitted artifact`);
  if (!same) failures++;
}
process.exit(failures ? 1 : 0);
