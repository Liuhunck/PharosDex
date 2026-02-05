require("@chainlink/env-enc").config();

const path = require("path");
const { execFileSync } = require("child_process");

// Deploy a PharosSpotMarket instance with existing base/quote token addresses.
// Usage:
//   set PHAROS_ATLANTIC_URL=...
//   set TEST_ACCOUNT_0=...
//   node scripts/deploy-spotmarket-pharos.js --base <BASE_ADDR> --quote <QUOTE_ADDR>

const CONTRACT_NAME = "PharosSpotMarket";

function toRepoPath(p) {
    return path.isAbsolute(p) ? p : path.join(__dirname, "..", p);
}

function parseArgv(argv) {
    const out = {};
    for (let i = 2; i < argv.length; i++) {
        const a = argv[i];
        if (!a.startsWith("--")) continue;
        const key = a.slice(2);
        const val = argv[i + 1];
        out[key] = val;
        i++;
    }
    return out;
}

function runNodeScript(scriptFileName, args) {
    const scriptPath = path.join(__dirname, scriptFileName);
    execFileSync(process.execPath, [scriptPath, ...args], { stdio: "inherit" });
}

async function main() {
    const rpcUrl = process.env.PHAROS_ATLANTIC_URL;
    const privateKey = process.env.TEST_ACCOUNT_0;
    if (!rpcUrl) throw new Error("Missing env PHAROS_ATLANTIC_URL");
    if (!privateKey) throw new Error("Missing env TEST_ACCOUNT_0");

    const args = parseArgv(process.argv);
    const base = args.base;
    const quote = args.quote;
    if (!base) throw new Error("Missing --base <BASE_TOKEN_ADDRESS>");
    if (!quote) throw new Error("Missing --quote <QUOTE_TOKEN_ADDRESS>");

    const outFile = toRepoPath(`deployments/pharos_atlantic.${CONTRACT_NAME}.latest.json`);
    const ctorArgs = JSON.stringify([base, quote]);

    console.log(`[INFO] Deploy ${CONTRACT_NAME}`);
    console.log(`[INFO] RPC=${rpcUrl}`);
    console.log(`[INFO] Base=${base}`);
    console.log(`[INFO] Quote=${quote}`);
    console.log(`[INFO] Out=${outFile}`);

    runNodeScript("deploy-pharos.js", [
        "--rpc",
        rpcUrl,
        "--pk",
        privateKey,
        "--contract",
        CONTRACT_NAME,
        "--args",
        ctorArgs,
        "--out",
        outFile,
    ]);
}

main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
});
