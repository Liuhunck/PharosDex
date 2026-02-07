require("@chainlink/env-enc").config();

const path = require("path");
const { execFileSync } = require("child_process");

// Hardcoded MockERC20 verify config (edit this file to change behavior)
const CONTRACT_NAME = "SinglePairOrderBookDEX";
const DEPLOYMENT_FILE_REL = `deployments/pharos_atlantic.${CONTRACT_NAME}.latest.json`;

const VERIFY_API_BASE = "https://api.socialscan.io/pharos-atlantic-testnet";
const VERIFY_BROWSER_BASE = "https://atlantic.pharosscan.xyz";
const VERIFY_LICENSE_TYPE = "MIT License (MIT)";
const VERIFY_LIBRARIES = []; // e.g. [{ key: "MyLib", value: "0x..." }]

function toRepoPath(p) {
    return path.isAbsolute(p) ? p : path.join(__dirname, "..", p);
}

function runNodeScript(scriptFileName, args) {
    const scriptPath = path.join(__dirname, scriptFileName);
    execFileSync(process.execPath, [scriptPath, ...args], { stdio: "inherit" });
}

async function main() {
    const deploymentFile = toRepoPath(DEPLOYMENT_FILE_REL);

    const verifyArgs = [
        "--deployment",
        deploymentFile,
        "--contract",
        CONTRACT_NAME,
        "--api",
        VERIFY_API_BASE,
        "--browser",
        VERIFY_BROWSER_BASE,
        "--license",
        VERIFY_LICENSE_TYPE,
        "--libraries",
        JSON.stringify(VERIFY_LIBRARIES),
    ];

    const auth = process.env.PHAROS_VERIFY_AUTH;
    if (auth) verifyArgs.push("--auth", String(auth));

    runNodeScript("verify-pharos.js", verifyArgs);
}

main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
});
