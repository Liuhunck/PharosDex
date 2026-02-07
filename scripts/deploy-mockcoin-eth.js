require("@chainlink/env-enc").config();

const path = require("path");
const { execFileSync } = require("child_process");

// Hardcoded MockERC20 deploy config (edit this file to change behavior)
const CONTRACT_NAME = "MockERC20";
const TOKEN_NAME = "Ether";
const TOKEN_SYMBOL = "ETH";
const TOKEN_DECIMALS = 18;

const OUT_FILE_REL = `deployments/pharos_atlantic.${CONTRACT_NAME}.${TOKEN_SYMBOL}.latest.json`;

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

    const outFile = toRepoPath(OUT_FILE_REL);
    const ctorArgs = JSON.stringify([TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS]);

    console.log(`[INFO] Deploy ${CONTRACT_NAME} (${TOKEN_SYMBOL})`);
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
