import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outFile = resolve(repoRoot, "src/frontend/public/deployment-manifest.json");
const githubUrl = "https://github.com/chainkeyicp/icp-lucky-burner";

const canisters = {
  lottery: {
    id: "m3n4c-3qaaa-aaaal-qw55a-cai",
    moduleHash: "0x8b11612d2d8da3dcf263c577374c69a61e00fb12600c0811656f20cf9d0adf90",
  },
  treasury: {
    id: "msox6-nyaaa-aaaal-qw54q-cai",
    moduleHash: "0x4b00c2f38c47337590739857f574d9ab458c7e756d11d61bc6a10fd770096b5c",
  },
  frontend: {
    id: "m4m2w-wiaaa-aaaal-qw55q-cai",
    moduleHash: "0x865eb25df5a6d857147e078bb33c727797957247f7af2635846d65c5397b36a6",
  },
};

function git(args) {
  return execFileSync("git", args, { cwd: repoRoot, encoding: "utf8" }).trim();
}

function command(args) {
  return execFileSync(args[0], args.slice(1), { cwd: repoRoot, encoding: "utf8" }).trim();
}

function liveModuleHash(canisterId) {
  if (process.env.DEPLOYMENT_READ_LIVE_STATUS !== "1") return null;
  try {
    const output = command(["dfx", "canister", "--network", "ic", "status", canisterId]);
    return output.match(/Module hash:\s*(0x[0-9a-f]+)/i)?.[1] ?? null;
  } catch {
    return null;
  }
}

const commit = process.env.DEPLOYMENT_GIT_COMMIT || git(["rev-parse", "HEAD"]);
const dirty = process.env.DEPLOYMENT_GIT_DIRTY
  ? process.env.DEPLOYMENT_GIT_DIRTY === "1"
  : git(["status", "--porcelain"]).length > 0;
const runUrl = process.env.DEPLOYMENT_VERIFY_RUN_URL
  || (process.env.GITHUB_RUN_ID ? `${githubUrl}/actions/runs/${process.env.GITHUB_RUN_ID}` : null);

for (const info of Object.values(canisters)) {
  info.moduleHash = liveModuleHash(info.id) || info.moduleHash;
}

const manifest = {
  schemaVersion: 1,
  generatedAt: new Date().toISOString(),
  gitCommit: commit,
  gitDirty: dirty,
  githubUrl,
  sourceUrl: `${githubUrl}/tree/${commit}`,
  verificationRunUrl: runUrl,
  customDomain: "https://luckyburner.fun/",
  canisters,
};

mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`Wrote ${outFile}`);
