require("@chainlink/env-enc").config();

const path = require("path");
const {
    parseArgv,
    readJsonIfExists,
    loadHardhatArtifact,
    findBuildInfoByContractName,
    encodeConstructorArgs,
    parseJsonArg,
    fetchJson,
} = require("./lib/pharos-evm-helpers");

const DEFAULT_API_BASE = "https://api.socialscan.io/pharos-atlantic-testnet";
const DEFAULT_BROWSER_BASE = "https://atlantic.pharosscan.xyz";
const DEFAULT_DEPLOYMENT_FILE = path.join(__dirname, "..", "deployments", "pharos_atlantic.latest.json");
function defaultDeploymentFileForContract(contractName) {
    return path.join(__dirname, "..", "deployments", `pharos_atlantic.${contractName}.latest.json`);
}

function printHelp() {
    console.log(
        `\nPharos verify via SocialScan-like API (Pharos-friendly; no Hardhat verify)\n\nUsage:\n  node scripts/verify-pharos.js [--deployment <FILE>] [--address <ADDR>] --contract <ContractName>\n\nCommon options:\n  --api            API base (default: ${DEFAULT_API_BASE})\n                  (or env PHAROS_VERIFY_API_BASE)\n  --browser        Explorer base URL (default: ${DEFAULT_BROWSER_BASE})\n                  (or env PHAROS_VERIFY_BROWSER_URL)\n  --deployment     Deployment json file (default: deployments/pharos_atlantic.latest.json)\n  --address        Contract address (if not in deployment file)\n  --contract       Contract name (or env PHAROS_VERIFY_CONTRACT, or deployment.contractName)\n  --artifact       Artifact path override\n  --args           Constructor args JSON array override\n  --license        License type string (default: MIT License (MIT))\n  --libraries      JSON array of {key,value} items (default: [])\n  --auth           Authorization header value (optional)\n\nExamples:\n  node scripts/verify-pharos.js --contract MemeHubToken\n  node scripts/verify-pharos.js --deployment deployments/pharos_atlantic.MemeHubToken.latest.json\n`,
    );
}

async function main() {
    const args = parseArgv(process.argv);
    if (args.help || args.h) {
        printHelp();
        return;
    }

    const contractHint = args.contract || process.env.PHAROS_VERIFY_CONTRACT;

    const apiBase = (args.api || process.env.PHAROS_VERIFY_API_BASE || DEFAULT_API_BASE).replace(/\/$/, "");

    const browserBase = (args.browser || process.env.PHAROS_VERIFY_BROWSER_URL || DEFAULT_BROWSER_BASE).replace(
        /\/$/,
        "",
    );

    const deploymentFile = args.deployment
        ? path.isAbsolute(args.deployment)
            ? args.deployment
            : path.join(__dirname, "..", args.deployment)
        : contractHint
        ? defaultDeploymentFileForContract(String(contractHint))
        : DEFAULT_DEPLOYMENT_FILE;

    const deployment = readJsonIfExists(deploymentFile);

    const address = args.address || args._[0] || deployment?.address;
    if (!address) throw new Error("Missing --address (or provide --deployment with address)");

    const contractName = contractHint || deployment?.contractName;
    if (!contractName) {
        throw new Error(
            "Missing --contract <ContractName> (or set env PHAROS_VERIFY_CONTRACT, or provide --deployment with contractName).",
        );
    }

    const ctorArgs = args.args ? parseJsonArg(String(args.args), "--args") : deployment?.constructorArgs || [];

    if (!Array.isArray(ctorArgs)) {
        throw new Error("Constructor args must be a JSON array.");
    }

    const licenseType = args.license || process.env.PHAROS_VERIFY_LICENSE_TYPE || "MIT License (MIT)";

    const libraries = args.libraries ? parseJsonArg(String(args.libraries), "--libraries") : [];

    if (!Array.isArray(libraries)) {
        throw new Error("--libraries must be a JSON array (e.g. '[]' or '[{" + '"key":"Lib","value":"0x.."' + "}]').");
    }

    let artifact;
    let artifactPath;
    let buildInfo;

    try {
        ({ artifact, artifactPath } = loadHardhatArtifact(contractName, args.artifact || deployment?.artifactPath));
        buildInfo = findBuildInfoByContractName(contractName);
    } catch (e) {
        const msg = String(e?.message || e);
        throw new Error(
            `Failed to load Hardhat artifact/build-info for contract '${contractName}'.\n` +
                `- Ensure you ran: npx hardhat compile\n` +
                `- Ensure the contract name is correct\n` +
                `- Or pass --artifact <path/to/<ContractName>.json>\n` +
                `Original error: ${msg}`,
        );
    }

    const compilerVersion = `v${buildInfo.solcLongVersion || buildInfo.solcVersion}`;
    const input = buildInfo.input;

    const optimizerEnabled = Boolean(input?.settings?.optimizer?.enabled);
    const optimizerRuns = input?.settings?.optimizer?.runs ?? 200;
    const evmVersion = input?.settings?.evmVersion ?? "default (compiler defaults)";

    const ctorEncoded = encodeConstructorArgs(artifact.abi, ctorArgs);

    console.log(`[INFO] API base: ${apiBase}`);
    console.log(`[INFO] Address: ${address}`);
    console.log(`[INFO] Contract: ${contractName}`);
    console.log(`[INFO] Artifact: ${artifactPath}`);
    console.log(`[INFO] Compiler: ${compilerVersion}`);
    console.log(`[INFO] Optimizer: ${optimizerEnabled ? "yes" : "no"} (runs=${optimizerRuns})`);
    console.log(`[INFO] EVM: ${evmVersion}`);
    console.log(`[INFO] License: ${licenseType}`);
    console.log(`[INFO] Libraries: ${JSON.stringify(libraries)}`);

    const headers = {};
    const auth = args.auth || process.env.PHAROS_VERIFY_AUTH;
    if (auth) headers.Authorization = String(auth);

    const check = await fetchJson(`${apiBase}/v1/explorer/verify_contract/check`, {
        method: "POST",
        headers: { "content-type": "application/json", ...headers },
        body: JSON.stringify({ address }),
    });

    if (check?.already_verified) {
        console.log("Already verified (per API). Done.");
        console.log(`[OK] Open: ${browserBase}/address/${address}#code`);
        return;
    }

    const form = new FormData();
    form.append("address", address);
    form.append("compiler_type", "Solidity (Standard-Json-Input)");
    form.append("license_type", licenseType);
    form.append("evm_version", evmVersion);
    form.append("compiler_version", compilerVersion);
    form.append("libraries", JSON.stringify(libraries));
    form.append("optimization", optimizerEnabled ? "yes" : "no");
    form.append("constructor_arguments", ctorEncoded);
    form.append("optimization_runs", String(optimizerRuns));

    const inputJson = JSON.stringify(input);
    const inputBlob = new Blob([inputJson], { type: "application/json" });
    form.append("files", inputBlob, "standard-json-input.json");

    console.log("[INFO] Submitting verification request...");

    const result = await fetchJson(`${apiBase}/v1/explorer/verify_contract/verify`, {
        method: "POST",
        headers,
        body: form,
    });

    console.log("Verification submitted.");
    console.log(typeof result === "string" ? result : JSON.stringify(result));
    console.log(`[OK] Open: ${browserBase}/address/${address}#code`);
}

main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
});
