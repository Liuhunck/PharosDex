require("@chainlink/env-enc").config();

const path = require("path");
const { ethers } = require("ethers");
const { parseArgv, writeJson, loadHardhatArtifact, parseJsonArg } = require("./lib/pharos-evm-helpers");

function printHelp() {
    console.log(
        `\nPharos deploy on EVM RPC (Pharos-friendly; no Hardhat tx sending)\n\nUsage:\n  node scripts/deploy-pharos.js --rpc <RPC_URL> --pk <PRIVATE_KEY> --contract <ContractName> [--args <JSON_ARRAY>]\n\nCommon options:\n  --rpc              RPC url (or env PHAROS_ATLANTIC_URL)\n  --pk               Private key (or env TEST_ACCOUNT_0)\n  --contract         Contract name (e.g. MemeHubToken)\n  --artifact          Optional artifact path (relative to repo root or absolute)\n  --args             Constructor args JSON array, e.g. '["MemeHub","MEH","1000"]'\n  --args-file        Path to a JSON file containing an array\n  --nonce            'latest' (default) or 'pending'\n  --gas-limit        Gas limit override (number)\n  --max-fee-gwei     Max fee per gas in gwei\n  --max-priority-fee-gwei  Max priority fee per gas in gwei\n  --out              Output deployment json path\n                    (default: deployments/pharos_atlantic.<contract>.latest.json if PHAROS_ATLANTIC_URL is used,\n                     otherwise deployments/pharos_evm.<contract>.latest.json)\n\nExamples:\n  node scripts/deploy-pharos.js --rpc %PHAROS_ATLANTIC_URL% --pk %TEST_ACCOUNT_0% --contract MemeHubToken --args '["MemeHub","MEH","1000000000000000000"]'\n`,
    );
}

function defaultOutFile({ rpcUrl, contractName }) {
    const isPharos = rpcUrl === process.env.PHAROS_ATLANTIC_URL && Boolean(process.env.PHAROS_ATLANTIC_URL);
    if (isPharos) {
        return path.join(__dirname, "..", "deployments", `pharos_atlantic.${contractName}.latest.json`);
    }
    return path.join(__dirname, "..", "deployments", `pharos_evm.${contractName}.latest.json`);
}

async function main() {
    const args = parseArgv(process.argv);
    if (args.help || args.h) {
        printHelp();
        return;
    }

    const rpcUrl = args.rpc || process.env.PHAROS_ATLANTIC_URL;
    const privateKey = args.pk || process.env.TEST_ACCOUNT_0;
    const contractName = args.contract;

    if (!rpcUrl) throw new Error("Missing --rpc (or env PHAROS_ATLANTIC_URL)");
    if (!privateKey) throw new Error("Missing --pk (or env TEST_ACCOUNT_0)");
    if (!contractName) throw new Error("Missing --contract <ContractName>");

    let ctorArgs = [];
    if (args["args-file"]) {
        const filePath = path.isAbsolute(args["args-file"])
            ? args["args-file"]
            : path.join(__dirname, "..", args["args-file"]);
        ctorArgs = require(filePath);
    } else if (args.args) {
        ctorArgs = parseJsonArg(String(args.args), "--args");
    }

    if (!Array.isArray(ctorArgs)) {
        throw new Error("Constructor args must be a JSON array.");
    }

    const { artifact, artifactPath } = loadHardhatArtifact(contractName, args.artifact);
    if (!artifact?.abi || !artifact?.bytecode) {
        throw new Error(`Artifact is missing abi/bytecode: ${artifactPath}`);
    }

    const provider = new ethers.JsonRpcProvider(rpcUrl);
    const wallet = new ethers.Wallet(privateKey, provider);

    const network = await provider.getNetwork();
    console.log(`[INFO] Connected chainId=${network.chainId.toString()}`);
    console.log(`[INFO] Deployer=${wallet.address}`);
    console.log(`[INFO] Artifact=${artifactPath}`);

    const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode, wallet);

    const nonceTag = String(args.nonce || "latest");
    const nonce = await provider.getTransactionCount(wallet.address, nonceTag);

    const overrides = { nonce };
    if (args["gas-limit"]) {
        const gl = Number(args["gas-limit"]);
        if (!Number.isFinite(gl) || gl <= 0) throw new Error("Invalid --gas-limit");
        overrides.gasLimit = gl;
    }

    if (args["max-fee-gwei"]) {
        overrides.maxFeePerGas = ethers.parseUnits(String(args["max-fee-gwei"]), "gwei");
    }
    if (args["max-priority-fee-gwei"]) {
        overrides.maxPriorityFeePerGas = ethers.parseUnits(String(args["max-priority-fee-gwei"]), "gwei");
    }

    console.log(`[INFO] Nonce=${nonce} (tag=${nonceTag})`);
    console.log(`[INFO] Deploying ${contractName} with args=${JSON.stringify(ctorArgs)}`);

    const contract = await factory.deploy(...ctorArgs, overrides);
    const tx = contract.deploymentTransaction();
    console.log(`[INFO] Deploy tx=${tx.hash}`);

    await contract.waitForDeployment();
    const address = await contract.getAddress();
    console.log(`[OK] Deployed at=${address}`);

    const outFile = args.out
        ? path.isAbsolute(args.out)
            ? args.out
            : path.join(__dirname, "..", args.out)
        : defaultOutFile({ rpcUrl, contractName });

    writeJson(outFile, {
        contractName,
        address,
        chainId: network.chainId.toString(),
        rpcUrl,
        deployer: wallet.address,
        deployTxHash: tx.hash,
        constructorArgs: ctorArgs,
        artifactPath: path.relative(path.join(__dirname, ".."), artifactPath).replace(/\\/g, "/"),
        deployedAt: new Date().toISOString(),
    });

    console.log(`[INFO] Wrote ${outFile}`);
}

main().catch((err) => {
    console.error(err);
    process.exitCode = 1;
});
