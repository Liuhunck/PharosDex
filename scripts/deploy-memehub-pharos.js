require("@chainlink/env-enc").config();

const path = require("path");
const { execFileSync } = require("child_process");
const { ethers } = require("ethers");

// Hardcoded MemeHubToken deploy config (edit this file to change behavior)
const CONTRACT_NAME = "MemeHubToken";
const TOKEN_NAME = "MemeHub";
const TOKEN_SYMBOL = "MEH";
const TOKEN_DECIMALS = 18;
const INITIAL_SUPPLY_TOKENS = "1000000"; // whole tokens (human-readable)

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

    if (!Number.isInteger(TOKEN_DECIMALS) || TOKEN_DECIMALS < 0 || TOKEN_DECIMALS > 255) {
        throw new Error("Invalid TOKEN_DECIMALS (expected integer 0..255)");
    }

    const initialSupply = ethers.parseUnits(String(INITIAL_SUPPLY_TOKENS), TOKEN_DECIMALS).toString();
    const outFile = toRepoPath(OUT_FILE_REL);
    const ctorArgs = JSON.stringify([TOKEN_NAME, TOKEN_SYMBOL, initialSupply]);

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
