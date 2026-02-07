<template>
  <div>
    <h2>DEX Supported Bases Viewer</h2>

    <button @click="connect" :disabled="connecting || !!account">
      {{ account ? "Connected" : (connecting ? "Connecting..." : "Connect Wallet") }}
    </button>

    <div v-if="account">
      <div><b>Account:</b> {{ account }}</div>
      <div><b>chainId:</b> {{ chainId }}</div>
      <div><b>DEX:</b> {{ DEX_ADDRESS }}</div>
      <div><b>Status:</b> {{ status }}</div>
    </div>

    <hr />

    <div>
      <h3>getSupportedBases()</h3>

      <button @click="fetchSupportedBases" :disabled="!account || loading">
        {{ loading ? "Loading..." : "Fetch Supported Bases" }}
      </button>

      <div>{{ msg }}</div>

      <div v-if="bases.length === 0">(empty)</div>

      <div v-for="(addr, i) in bases" :key="addr + ':' + i">
        {{ i + 1 }}. {{ addr }}
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from "vue";
import { ethers } from "ethers";

/* ====== constants ====== */
const DEX_ADDRESS = "0x887D9Af1241a176107d31Bb3C69787DFff6dbaD8";

const DEX_ABI = [
  "function getSupportedBases() view returns (address[] memory)",
];

/* ====== state ====== */
const account = ref("");
const chainId = ref(null);
const status = ref("Not connected.");
const msg = ref("");
const connecting = ref(false);
const loading = ref(false);
const bases = ref([]);

/* ====== ethers objects ====== */
let provider; // BrowserProvider（普通变量即可）
let signer;   // Signer（普通变量即可）
const dex = ref(null); // 关键：dex 用 ref，保证 ready/后续调用稳定

const ready = computed(() => !!dex.value && !!account.value);

function getEthereum() {
  const eth = window.ethereum;
  if (!eth) {
    throw new Error("MetaMask not found. Please install MetaMask.");
  }
  return eth;
}

/* ====== connect wallet (改成你给的那种风格) ====== */
async function connect() {
  msg.value = "";
  try {
    connecting.value = true;
    status.value = "Connecting wallet...";

    const eth = getEthereum();
    provider = new ethers.BrowserProvider(eth);

    // 请求连接
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();
    account.value = await signer.getAddress();

    const net = await provider.getNetwork();
    chainId.value = Number(net.chainId);

    // 初始化合约实例（用 signer，这样后续如果你要加写操作也方便）
    dex.value = new ethers.Contract(DEX_ADDRESS, DEX_ABI, signer);

    // 可选：检查是否是你期望的链（你示例里用 688689）
    if (Number(net.chainId) !== 688689) {
      status.value = `Connected, but chainId=${net.chainId}. Please switch to 688689.`;
    } else {
      status.value = "Connected.";
    }
  } catch (e) {
    console.error(e);
    status.value = `Connect error: ${e.message || e}`;
  } finally {
    connecting.value = false;
  }
}

/* ====== view call: getSupportedBases ====== */
async function fetchSupportedBases() {
  msg.value = "";
  bases.value = [];

  if (!ready.value) {
    msg.value = "Please connect wallet first.";
    return;
  }

  try {
    loading.value = true;
    msg.value = "Calling getSupportedBases()...";

    const res = await dex.value.getSupportedBases(); // address[]
    const list = Array.isArray(res) ? res.map((x) => String(x)) : [];
    const uniq = [...new Set(list)];

    bases.value = uniq;
    msg.value = `✅ Loaded ${uniq.length} base token(s).`;
  } catch (e) {
    console.error(e);
    msg.value = `❌ getSupportedBases failed: ${e.shortMessage || e.message || e}`;
  } finally {
    loading.value = false;
  }
}
</script>
