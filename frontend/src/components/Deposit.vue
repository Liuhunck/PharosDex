<template>
    <div>
      <h2>DEX Balance Manager</h2>
  
      <button @click="connect" :disabled="connecting || !!account">
        {{ account ? "Connected" : (connecting ? "Connecting..." : "Connect Wallet") }}
      </button>
  
      <div v-if="account">
        <div><b>Account:</b> {{ account }}</div>
        <div><b>chainId:</b> {{ chainId }}</div>
        <div><b>DEX:</b> {{ DEX_ADDRESS }}</div>
        <div><b>Quote:</b> {{ quoteAddr || "(unknown)" }}</div>
        <div><b>Status:</b> {{ status }}</div>
      </div>
  
      <hr />
  
      <div>
        <h3>Supported Bases</h3>
        <button @click="fetchSupportedBases" :disabled="!ready || busy">
          {{ busy ? "Working..." : "getSupportedBases()" }}
        </button>
  
        <div>{{ msg }}</div>
  
        <div v-if="bases.length === 0">(empty)</div>
        <div v-for="(addr, i) in bases" :key="addr + ':' + i">
          {{ i + 1 }}. {{ addr }}
        </div>
      </div>
  
      <hr />
  
      <div>
        <h3>Deposit / Withdraw BASE</h3>
  
        <div>
          <label>
            Base token address:
            <input v-model="baseAddrInput" type="text" placeholder="0x..." />
          </label>
        </div>
  
        <div>
          <label>
            Amount (human units):
            <input v-model="baseAmountInput" type="text" placeholder="e.g. 1000 or 1.5" />
          </label>
        </div>
  
        <button @click="depositBase" :disabled="!ready || busy">
          depositBaseFor(base, amount)
        </button>
        <button @click="withdrawBase" :disabled="!ready || busy">
          withdrawBaseFor(base, amount)
        </button>
  
        <div>{{ baseMsg }}</div>
      </div>
  
      <hr />
  
      <div>
        <h3>Deposit / Withdraw QUOTE</h3>
  
        <div>
          <label>
            Amount (human units):
            <input v-model="quoteAmountInput" type="text" placeholder="e.g. 1000 or 1.5" />
          </label>
        </div>
  
        <button @click="depositQuote" :disabled="!ready || busy">
          depositQuote(amount)
        </button>
        <button @click="withdrawQuote" :disabled="!ready || busy">
          withdrawQuote(amount)
        </button>
  
        <div>{{ quoteMsg }}</div>

</div>

        
  
      <hr />
      <div>
        <button @click="refreshBaseInternalBalance" :disabled="!ready || busy">
        query baseBalance(trader, base)
        </button>
        <div v-if="ready">Internal Base Balance: {{ baseBalHuman }}</div>

        <button @click="refreshQuoteInternalBalance" :disabled="!ready || busy">
        query quoteBalance(trader)
        </button>
        <div v-if="ready">Internal Quote Balance: {{ quoteBalHuman }}</div>
    </div>
    </div>
  </template>
  
  <script setup>
  import { ref, computed } from "vue";
  import { ethers } from "ethers";
  
  /* ====== constants ====== */
  const DEX_ADDRESS = "0x887D9Af1241a176107d31Bb3C69787DFff6dbaD8";
  
  /**
   * 你描述的函数 + 读取辅助（quoteToken、getSupportedBases）
   * 如果你的合约里某个函数是 external/public 但名字不同，改这里的签名字符串即可。
   */
  const DEX_ABI = [
    "function quoteToken() view returns (address)",
    "function getSupportedBases() view returns (address[] memory)",
  
    "function depositBaseFor(address base, uint256 amount)",
    "function withdrawBaseFor(address base, uint256 amount)",
  
    "function depositQuote(uint256 amount)",
    "function withdrawQuote(uint256 amount)",
    
    // ✅ 新增：public mapping getter（自动生成的 view 函数）
    "function quoteBalance(address trader) view returns (uint256)",
    "function baseBalance(address trader, address base) view returns (uint256)",
  ];
  
  /* ====== ERC20 minimal ABI ====== */
  const ERC20_ABI = [
    "function decimals() view returns (uint8)",
    "function symbol() view returns (string)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)",
  ];
  
  /* ====== state ====== */
  const account = ref("");
  const chainId = ref(null);
  const status = ref("Not connected.");
  const msg = ref("");
  const connecting = ref(false);
  const busy = ref(false);
  
  const bases = ref([]);
  const quoteAddr = ref("");
  
  /* UI inputs */
  const baseAddrInput = ref("");
  const baseAmountInput = ref("1000");
  const baseMsg = ref("");
  
  const quoteAmountInput = ref("1000");
  const quoteMsg = ref("");
  
  /* ====== ethers objects ====== */
  let provider; // BrowserProvider
  let signer;   // Signer
  const dex = ref(null);

  // ====== internal balances (in wei) ======
  const quoteBalWei = ref(0n);
  const quoteBalHuman = ref("0");

  const baseBalWei = ref(0n);
  const baseBalHuman = ref("0");
  
  const ready = computed(() => !!dex.value && !!account.value);
  
  /* ====== helpers ====== */
  function getEthereum() {
    const eth = window.ethereum;
    if (!eth) throw new Error("MetaMask not found. Please install MetaMask.");
    return eth;
  }
  
  function isAddress(x) {
    try {
      return ethers.isAddress(String(x).trim());
    } catch {
      return false;
    }
  }
  
  function normalizeAmountInput(x) {
    const s = String(x ?? "").trim();
    if (!s) return null;
    // 允许整数/小数
    if (!/^\d+(\.\d+)?$/.test(s)) return null;
    return s;
  }
  
  async function getTokenDecimals(tokenAddr) {
    const c = new ethers.Contract(tokenAddr, ERC20_ABI, provider);
    const d = await c.decimals();
    return Number(d);
  }
  
  async function getTokenSymbol(tokenAddr) {
    try {
      const c = new ethers.Contract(tokenAddr, ERC20_ABI, provider);
      return await c.symbol();
    } catch {
      return "";
    }
  }
  
  /**
   * 确保 allowance >= amount，否则先 approve
   * 注意：这里 approve 用 exact amount（更安全），你也可以改成 MaxUint256 省得下次再批。
   */
  async function ensureAllowance(tokenAddr, spender, amountWei) {
    const token = new ethers.Contract(tokenAddr, ERC20_ABI, signer);
    const current = await token.allowance(account.value, spender);
    if (current >= amountWei) return { approved: false };
  
    const tx = await token.approve(spender, amountWei);
    await tx.wait();
    return { approved: true, txHash: tx.hash };
  }
  
  /* ====== connect wallet ====== */
  async function connect() {
    msg.value = "";
    try {
      connecting.value = true;
      status.value = "Connecting wallet...";
  
      const eth = getEthereum();
      provider = new ethers.BrowserProvider(eth);
  
      await provider.send("eth_requestAccounts", []);
      signer = await provider.getSigner();
  
      account.value = await signer.getAddress();
  
      const net = await provider.getNetwork();
      chainId.value = Number(net.chainId);
  
      dex.value = new ethers.Contract(DEX_ADDRESS, DEX_ABI, signer);
  
      // 读一下 quoteToken，后面 depositQuote 要用
      quoteAddr.value = await dex.value.quoteToken();
  
      // 可选：你之前示例里用 688689
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
  
  /* ====== view: getSupportedBases ====== */
  async function fetchSupportedBases() {
    msg.value = "";
    bases.value = [];
  
    if (!ready.value) {
      msg.value = "Please connect wallet first.";
      return;
    }
  
    try {
      busy.value = true;
      msg.value = "Calling getSupportedBases()...";
  
      const res = await dex.value.getSupportedBases();
      const list = Array.isArray(res) ? res.map((x) => String(x)) : [];
      bases.value = [...new Set(list)];
  
      msg.value = `✅ Loaded ${bases.value.length} base token(s).`;
    } catch (e) {
      console.error(e);
      msg.value = `❌ getSupportedBases failed: ${e.shortMessage || e.message || e}`;
    } finally {
      busy.value = false;
    }
  }
  
  /* ====== actions: base deposit/withdraw ====== */
  async function depositBase() {
    baseMsg.value = "";
    if (!ready.value) return (baseMsg.value = "Please connect wallet first.");
  
    const base = String(baseAddrInput.value || "").trim();
    if (!isAddress(base)) return (baseMsg.value = "Invalid base token address.");
  
    const amtHuman = normalizeAmountInput(baseAmountInput.value);
    if (!amtHuman) return (baseMsg.value = "Invalid amount format (use number like 1000 or 1.5).");
  
    try {
      busy.value = true;
      baseMsg.value = "Preparing depositBaseFor...";
  
      const decimals = await getTokenDecimals(base);
      const amountWei = ethers.parseUnits(amtHuman, decimals);
  
      if (amountWei === 0n) {
        baseMsg.value = "Amount must be > 0.";
        return;
      }
  
      // deposit 会 transferFrom，所以需要 allowance
      baseMsg.value = "Checking allowance / approving if needed...";
      await ensureAllowance(base, DEX_ADDRESS, amountWei);
  
      baseMsg.value = "Sending depositBaseFor tx...";
      const tx = await dex.value.depositBaseFor(base, amountWei);
  
      baseMsg.value = `Tx sent: ${tx.hash}\nWaiting confirmation...`;
      await tx.wait();
  
      const sym = await getTokenSymbol(base);
      baseMsg.value = `✅ Deposited ${amtHuman} ${sym || ""}\nTx: ${tx.hash}`;
    } catch (e) {
      console.error(e);
      baseMsg.value = `❌ depositBaseFor failed: ${e.shortMessage || e.message || e}`;
    } finally {
      busy.value = false;
    }
  }
  
  async function withdrawBase() {
    baseMsg.value = "";
    if (!ready.value) return (baseMsg.value = "Please connect wallet first.");
  
    const base = String(baseAddrInput.value || "").trim();
    if (!isAddress(base)) return (baseMsg.value = "Invalid base token address.");
  
    const amtHuman = normalizeAmountInput(baseAmountInput.value);
    if (!amtHuman) return (baseMsg.value = "Invalid amount format (use number like 1000 or 1.5).");
  
    try {
      busy.value = true;
      baseMsg.value = "Preparing withdrawBaseFor...";
  
      const decimals = await getTokenDecimals(base);
      const amountWei = ethers.parseUnits(amtHuman, decimals);
  
      if (amountWei === 0n) {
        baseMsg.value = "Amount must be > 0.";
        return;
      }
  
      baseMsg.value = "Sending withdrawBaseFor tx...";
      const tx = await dex.value.withdrawBaseFor(base, amountWei);
  
      baseMsg.value = `Tx sent: ${tx.hash}\nWaiting confirmation...`;
      await tx.wait();
  
      const sym = await getTokenSymbol(base);
      baseMsg.value = `✅ Withdrawn ${amtHuman} ${sym || ""}\nTx: ${tx.hash}`;
    } catch (e) {
      console.error(e);
      baseMsg.value = `❌ withdrawBaseFor failed: ${e.shortMessage || e.message || e}`;
    } finally {
      busy.value = false;
    }
  }
  
  /* ====== actions: quote deposit/withdraw ====== */
  async function depositQuote() {
    quoteMsg.value = "";
    if (!ready.value) return (quoteMsg.value = "Please connect wallet first.");
    if (!isAddress(quoteAddr.value)) return (quoteMsg.value = "quoteToken() address not loaded.");
  
    const amtHuman = normalizeAmountInput(quoteAmountInput.value);
    if (!amtHuman) return (quoteMsg.value = "Invalid amount format (use number like 1000 or 1.5).");
  
    try {
      busy.value = true;
      quoteMsg.value = "Preparing depositQuote...";
  
      const decimals = await getTokenDecimals(quoteAddr.value);
      const amountWei = ethers.parseUnits(amtHuman, decimals);
  
      if (amountWei === 0n) {
        quoteMsg.value = "Amount must be > 0.";
        return;
      }
  
      // depositQuote 也会 transferFrom(quote)
      quoteMsg.value = "Checking allowance / approving if needed...";
      await ensureAllowance(quoteAddr.value, DEX_ADDRESS, amountWei);
  
      quoteMsg.value = "Sending depositQuote tx...";
      const tx = await dex.value.depositQuote(amountWei);
  
      quoteMsg.value = `Tx sent: ${tx.hash}\nWaiting confirmation...`;
      await tx.wait();
  
      const sym = await getTokenSymbol(quoteAddr.value);
      quoteMsg.value = `✅ Deposited ${amtHuman} ${sym || "QUOTE"}\nTx: ${tx.hash}`;
    } catch (e) {
      console.error(e);
      quoteMsg.value = `❌ depositQuote failed: ${e.shortMessage || e.message || e}`;
    } finally {
      busy.value = false;
    }
  }
  
  async function withdrawQuote() {
    quoteMsg.value = "";
    if (!ready.value) return (quoteMsg.value = "Please connect wallet first.");
  
    const amtHuman = normalizeAmountInput(quoteAmountInput.value);
    if (!amtHuman) return (quoteMsg.value = "Invalid amount format (use number like 1000 or 1.5).");
  
    try {
      busy.value = true;
      quoteMsg.value = "Preparing withdrawQuote...";
  
      const decimals = await getTokenDecimals(quoteAddr.value);
      const amountWei = ethers.parseUnits(amtHuman, decimals);
  
      if (amountWei === 0n) {
        quoteMsg.value = "Amount must be > 0.";
        return;
      }
  
      quoteMsg.value = "Sending withdrawQuote tx...";
      const tx = await dex.value.withdrawQuote(amountWei);
  
      quoteMsg.value = `Tx sent: ${tx.hash}\nWaiting confirmation...`;
      await tx.wait();
  
      const sym = await getTokenSymbol(quoteAddr.value);
      quoteMsg.value = `✅ Withdrawn ${amtHuman} ${sym || "QUOTE"}\nTx: ${tx.hash}`;
    } catch (e) {
      console.error(e);
      quoteMsg.value = `❌ withdrawQuote failed: ${e.shortMessage || e.message || e}`;
    } finally {
      busy.value = false;
    }
}

async function refreshQuoteInternalBalance() {
  quoteMsg.value = "";
  if (!ready.value) {
    quoteMsg.value = "Please connect wallet first.";
    return;
  }
  if (!isAddress(quoteAddr.value)) {
    quoteMsg.value = "quoteToken() address not loaded.";
    return;
  }

  try {
    busy.value = true;
    quoteMsg.value = "Querying quoteBalance(trader)...";

    // 1) 读内部余额（wei）
    const wei = await dex.value.quoteBalance(account.value);
    quoteBalWei.value = BigInt(wei);

    // 2) 转成人类单位
    const decimals = await getTokenDecimals(quoteAddr.value);
    quoteBalHuman.value = ethers.formatUnits(quoteBalWei.value, decimals);

    const sym = await getTokenSymbol(quoteAddr.value);
    quoteMsg.value = `✅ Quote internal balance: ${quoteBalHuman.value} ${sym || "QUOTE"}`;
  } catch (e) {
    console.error(e);
    quoteMsg.value = `❌ query quoteBalance failed: ${e.shortMessage || e.message || e}`;
  } finally {
    busy.value = false;
  }
}

async function refreshBaseInternalBalance() {
  baseMsg.value = "";
  if (!ready.value) {
    baseMsg.value = "Please connect wallet first.";
    return;
  }

    //   const base = String(baseAddrInput.value || "").trim();

    // 默认为 Doge 币
    const base = "0xd18d98fdFaBE86a7AD0114a9985F75f9FD6992DE";
  if (!isAddress(base)) {
    baseMsg.value = "Invalid base token address (used for baseBalance query).";
    return;
  }

  try {
    busy.value = true;
    baseMsg.value = "Querying baseBalance(trader, base)...";

    // 1) 读内部余额（wei）
    const wei = await dex.value.baseBalance(account.value, base);
    baseBalWei.value = BigInt(wei);

    // 2) 转成人类单位
    const decimals = await getTokenDecimals(base);
    baseBalHuman.value = ethers.formatUnits(baseBalWei.value, decimals);

    const sym = await getTokenSymbol(base);
    baseMsg.value = `✅ Base internal balance: ${baseBalHuman.value} ${sym || ""}`;
  } catch (e) {
    console.error(e);
    baseMsg.value = `❌ query baseBalance failed: ${e.shortMessage || e.message || e}`;
  } finally {
    busy.value = false;
  }
}

// （可选）一键刷新：baseAddrInput 填了才会查 baseBalance
async function refreshAllBalances() {
  await refreshQuoteInternalBalance();
  const base = String(baseAddrInput.value || "").trim();
  if (isAddress(base)) {
    await refreshBaseInternalBalance();
  }
}

  </script>
  