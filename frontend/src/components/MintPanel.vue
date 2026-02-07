<template>
  <div style="max-width: 520px; margin: 24px auto; font-family: sans-serif;">
    <h2>MockERC20 Mint (Sepolia)</h2>

    <button @click="connect" :disabled="connecting || !!account">
      {{ account ? "Connected" : (connecting ? "Connecting..." : "Connect Wallet") }}
    </button>

    <p v-if="account" style="margin-top: 10px;">
      <b>Account:</b> {{ account }}
    </p>

    <hr />

    <label>
      Mint Amount:
      <input v-model="amountInput" type="number" min="0" step="1" style="margin-left: 8px; width: 160px;" />
    </label>

    <div style="margin-top: 14px; display: flex; gap: 10px;">
      <button @click="mintDOGE" :disabled="!account || minting">
        {{ minting ? "Minting..." : "Mint DOGE" }}
      </button>
      <button @click="mintUSDT" :disabled="!account || minting">
        {{ minting ? "Minting..." : "Mint USDT" }}
      </button>
    </div>

    <p style="margin-top: 14px; white-space: pre-wrap;">
      <b>Status:</b> {{ status }}
    </p>
  </div>
</template>

<script setup>
import { ref } from "vue";
import { ethers } from "ethers";

// // ====== 你的合约地址（Sepolia）======
// const DOGE_ADDRESS = "0xDB3b249a3e4D52364962e4b0f45BE999Fa94cDf1";
// const USDT_ADDRESS = "0xd85314a65BFd6Bc4CCe1AaA82C6E86350E143bbC";

// ====== 你的合约地址（Pharos）======
const DOGE_ADDRESS = "0xd18d98fdFaBE86a7AD0114a9985F75f9FD6992DE";
const USDT_ADDRESS = "0x4a3FEA9668eE4a2802EaBf4808dFCdEBc474439e";

// 只需要 mint + decimals（你合约里有）
const ABI = [
  "function mint(address to, uint256 amount)",
  "function decimals() view returns (uint8)",
];

// ====== 状态 ======
const account = ref("");
const status = ref("Not connected.");
const amountInput = ref("1000");

const connecting = ref(false);
const minting = ref(false);

let provider; // BrowserProvider
let signer;   // Signer

function getEthereum() {
  const eth = window.ethereum;
  if (!eth) {
    throw new Error("MetaMask not found. Please install MetaMask.");
  }
  return eth;
}

async function connect() {
  try {
    connecting.value = true;
    status.value = "Connecting wallet...";

    const eth = getEthereum();
    provider = new ethers.BrowserProvider(eth);

    // 请求连接
    await provider.send("eth_requestAccounts", []);
    signer = await provider.getSigner();

    account.value = await signer.getAddress();

    // 可选：检查网络是否 Sepolia（chainId = 11155111）
    const net = await provider.getNetwork();
    if (Number(net.chainId) !== 688689 ) {
      status.value = `Connected, but NOT Sepolia. Current chainId=${net.chainId}. Please switch to Sepolia.`;
    } else {
      status.value = "Connected to Sepolia.";
    }
  } catch (e) {
    console.error(e);
    status.value = `Connect error: ${e.message || e}`;
  } finally {
    connecting.value = false;
  }
}

async function mintToken(tokenAddress) {
  if (!signer || !account.value) {
    status.value = "Please connect wallet first.";
    return;
  }

  const amt = amountInput.value;
  if (!amt || Number(amt) <= 0) {
    status.value = "Amount must be > 0.";
    return;
  }

  try {
    minting.value = true;
    status.value = "Preparing mint...";

    const token = new ethers.Contract(tokenAddress, ABI, signer);
    const decimals = await token.decimals();

    const amount = ethers.parseUnits(String(amt), decimals);

    status.value = "Sending transaction...";
    const tx = await token.mint(account.value, amount);

    status.value = `Tx sent: ${tx.hash}\nWaiting for confirmation...`;
    await tx.wait();

    status.value = `✅ Mint success!\nTx: ${tx.hash}`;
  } catch (e) {
    console.error(e);
    status.value = `Mint error: ${e.shortMessage || e.message || e}`;
  } finally {
    minting.value = false;
  }
}

function mintDOGE() {
  return mintToken(DOGE_ADDRESS);
}
function mintUSDT() {
  return mintToken(USDT_ADDRESS);
}
</script>
