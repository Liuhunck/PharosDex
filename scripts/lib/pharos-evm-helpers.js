const fs = require("fs");
const path = require("path");
const { ethers } = require("ethers");

function parseArgv(argv) {
    const out = { _: [] };

    for (let i = 2; i < argv.length; i++) {
        const arg = argv[i];

        if (!arg.startsWith("--")) {
            out._.push(arg);
            continue;
        }

        const withoutPrefix = arg.slice(2);
        const eq = withoutPrefix.indexOf("=");
        const key = eq >= 0 ? withoutPrefix.slice(0, eq) : withoutPrefix;
        const inlineValue = eq >= 0 ? withoutPrefix.slice(eq + 1) : undefined;

        if (inlineValue !== undefined) {
            out[key] = inlineValue;
            continue;
        }

        const next = argv[i + 1];
        if (next !== undefined && !next.startsWith("--")) {
            out[key] = next;
            i++;
            continue;
        }

        out[key] = true;
    }

    return out;
}

function readJsonIfExists(filePath) {
    if (!filePath) return null;
    if (!fs.existsSync(filePath)) return null;
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, data) {
    fs.mkdirSync(path.dirname(filePath), { recursive: true });
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2), "utf8");
}

function walkFiles(dirPath, onFile) {
    if (!fs.existsSync(dirPath)) return;
    const entries = fs.readdirSync(dirPath, { withFileTypes: true });
    for (const entry of entries) {
        const full = path.join(dirPath, entry.name);
        if (entry.isDirectory()) {
            walkFiles(full, onFile);
        } else if (entry.isFile()) {
            onFile(full);
        }
    }
}

function findHardhatArtifactPath(contractName) {
    const contractsRoot = path.join(__dirname, "..", "..", "artifacts", "contracts");
    if (!fs.existsSync(contractsRoot)) {
        throw new Error("Missing artifacts/contracts. Run `npm run compile` first.");
    }

    const matches = [];
    walkFiles(contractsRoot, (filePath) => {
        if (path.basename(filePath) !== `${contractName}.json`) return;
        matches.push(filePath);
    });

    if (matches.length === 0) {
        throw new Error(
            `Cannot find artifact for contract ${contractName} under artifacts/contracts. You can pass --artifact <path> explicitly.`,
        );
    }

    if (matches.length === 1) return matches[0];

    // Prefer the typical Hardhat path: artifacts/contracts/<Something>.sol/<Contract>.json
    const preferred = matches.find((p) => path.basename(path.dirname(p)).endsWith(".sol"));
    return preferred || matches.sort((a, b) => a.length - b.length)[0];
}

function loadArtifactByPath(artifactPath) {
    if (!fs.existsSync(artifactPath)) {
        throw new Error(`Artifact not found: ${artifactPath}`);
    }
    return JSON.parse(fs.readFileSync(artifactPath, "utf8"));
}

function loadHardhatArtifact(contractName, artifactPathOverride) {
    const artifactPath = artifactPathOverride
        ? path.isAbsolute(artifactPathOverride)
            ? artifactPathOverride
            : path.join(__dirname, "..", "..", artifactPathOverride)
        : findHardhatArtifactPath(contractName);

    return { artifact: loadArtifactByPath(artifactPath), artifactPath };
}

function findBuildInfoByContractName(contractName) {
    const buildInfoDir = path.join(__dirname, "..", "..", "artifacts", "build-info");
    if (!fs.existsSync(buildInfoDir)) {
        throw new Error("Missing artifacts/build-info. Run `npm run compile` first.");
    }

    const candidates = fs
        .readdirSync(buildInfoDir)
        .filter((f) => f.endsWith(".json"))
        .map((f) => path.join(buildInfoDir, f));

    if (candidates.length === 0) {
        throw new Error("No build-info JSON found under artifacts/build-info. Run `npm run compile` first.");
    }

    let first = null;
    for (const filePath of candidates) {
        const raw = fs.readFileSync(filePath, "utf8");
        const buildInfo = JSON.parse(raw);
        if (!first) first = buildInfo;

        const contracts = buildInfo?.output?.contracts;
        if (!contracts || typeof contracts !== "object") continue;

        for (const sourcePath of Object.keys(contracts)) {
            const sourceContracts = contracts[sourcePath];
            if (sourceContracts && Object.prototype.hasOwnProperty.call(sourceContracts, contractName)) {
                return buildInfo;
            }
        }
    }

    return first;
}

function normalizeArgValue(type, value) {
    if (value === null || value === undefined) return value;

    if (type === "address") return String(value);
    if (type === "bool") return value === true || String(value).toLowerCase() === "true";

    if (/^u?int\d*$/.test(type)) {
        return BigInt(String(value));
    }

    if (/^bytes(\d+)?$/.test(type)) {
        return String(value);
    }

    return value;
}

function encodeConstructorArgs(abi, args) {
    const ctor = Array.isArray(abi) ? abi.find((x) => x && x.type === "constructor") : null;
    const inputs = ctor?.inputs ?? [];

    if (inputs.length === 0) return "";

    if (!Array.isArray(args) || args.length !== inputs.length) {
        throw new Error(
            `Constructor args mismatch. ABI expects ${inputs.length} args (${inputs
                .map((i) => i.type)
                .join(", ")}); got ${Array.isArray(args) ? args.length : 0}.`,
        );
    }

    const types = inputs.map((i) => i.type);
    const values = inputs.map((input, i) => normalizeArgValue(input.type, args[i]));

    const encoded = ethers.AbiCoder.defaultAbiCoder().encode(types, values);
    return encoded.startsWith("0x") ? encoded.slice(2) : encoded;
}

function parseJsonArg(value, nameForError) {
    try {
        return JSON.parse(value);
    } catch (e) {
        const msg = e && e.message ? String(e.message) : String(e);
        throw new Error(`Invalid JSON for ${nameForError}: ${msg}`);
    }
}

async function fetchJson(url, init = {}) {
    if (typeof fetch !== "function") {
        throw new Error("Global fetch() is not available. Please use Node.js >= 18.");
    }

    const controller = new AbortController();
    const timeoutMs = Number(process.env.PHAROS_HTTP_TIMEOUT_MS ?? "120000");
    const timer = setTimeout(() => controller.abort(new Error("Request timeout")), timeoutMs);

    try {
        const res = await fetch(url, { ...init, signal: controller.signal });
        const text = await res.text();

        let data;
        try {
            data = text ? JSON.parse(text) : null;
        } catch {
            data = text;
        }

        if (!res.ok) {
            const detail = typeof data === "string" ? data : JSON.stringify(data);
            throw new Error(`HTTP ${res.status} ${res.statusText}: ${detail}`);
        }

        return data;
    } finally {
        clearTimeout(timer);
    }
}

module.exports = {
    parseArgv,
    readJsonIfExists,
    writeJson,
    loadHardhatArtifact,
    findBuildInfoByContractName,
    encodeConstructorArgs,
    parseJsonArg,
    fetchJson,
};
