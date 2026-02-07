require("@chainlink/env-enc").config();

const path = require("path");
const { execFileSync } = require("child_process");

// Hardcoded MemeHubToken deploy config (edit this file to change behavior)
const CONTRACT_NAME = "SinglePairOrderBookDEX";
const BASE_ADDRESS = "0xd18d98fdFaBE86a7AD0114a9985F75f9FD6992DE";
const QUOTE_ADDRESS = "0x4a3FEA9668eE4a2802EaBf4808dFCdEBc474439e";

const OUT_FILE_REL = `deployments/pharos_atlantic.${CONTRACT_NAME}.latest.json`;

function toRepoPath(p) {
    return path.isAbsolute(p) ? p : path.join(__dirname, "..", p);
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
    const outFile = toRepoPath(OUT_FILE_REL);
    const ctorArgs = JSON.stringify([BASE_ADDRESS, QUOTE_ADDRESS]);

    console.log(`[INFO] Deploy ${CONTRACT_NAME}`);
    console.log(`[INFO] RPC=${rpcUrl}`);
    console.log(`[INFO] Out=${outFile}`);
    console.log(`[INFO] Constructor args=${ctorArgs}`);

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
