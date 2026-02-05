<template>
    <div>
      <h2>DEX Panel (Sepolia)</h2>
  
      <button @click="connectWallet" :disabled="connecting">
        {{ account ? "Connected" : (connecting ? "Connecting..." : "Connect Wallet") }}
      </button>
  
      <div v-if="account">
        <div>Account: {{ account }}</div>
        <div>chainId: {{ chainId }}</div>
        <button v-if="needSepolia" @click="switchToSepolia">
          Switch to Sepolia
        </button>
      </div>
  
      <div>Status: {{ status }}</div>
      <div>{{ dexStatus }}</div>
  
      <hr />
  
      <div>
        <div>Last Price (USDT / DOGE): {{ lastPriceDisplay }}</div>
      </div>
  
      <hr />
  
      <div>
        <h3>OrderBook (Top 5)</h3>
  
        <h4>Bids</h4>
        <div v-for="(r, i) in bids" :key="'b'+i">
          {{ r.price }} | {{ r.size }}
        </div>
        <div v-if="bids.length === 0">(empty)</div>
  
        <h4>Asks</h4>
        <div v-for="(r, i) in asks" :key="'a'+i">
          {{ r.price }} | {{ r.size }}
        </div>
        <div v-if="asks.length === 0">(empty)</div>
      </div>
  
      <hr />
  
      <div>
        <h3>Approve</h3>
        <button @click="approveUSDT" :disabled="!account || txBusy">Approve USDT</button>
        <button @click="approveDOGE" :disabled="!account || txBusy">Approve DOGE</button>
        <div>USDT allowance: {{ usdtAllowanceDisplay }}</div>
        <div>DOGE allowance: {{ dogeAllowanceDisplay }}</div>
      </div>
  
      <hr />
  
      <div>
        <h3>Limit Order</h3>
        <div>
          <label>
            Price (USDT/DOGE)
            <input v-model="limitPrice" type="number" step="0.000001" min="0" />
          </label>
        </div>
        <div>
          <label>
            Amount (DOGE)
            <input v-model="limitAmountBase" type="number" step="0.000001" min="0" />
          </label>
        </div>
        <button @click="limitBuy" :disabled="!account || txBusy">Limit Buy</button>
        <button @click="limitSell" :disabled="!account || txBusy">Limit Sell</button>
      </div>
  
      <hr />
  
      <div>
        <h3>Market Order</h3>
        <div>
          <label>
            Max USDT (market buy)
            <input v-model="marketMaxQuoteIn" type="number" step="0.01" min="0" />
          </label>
        </div>
        <button @click="marketBuy" :disabled="!account || txBusy">Market Buy</button>
  
        <div>
          <label>
            DOGE amount (market sell)
            <input v-model="marketSellAmountBase" type="number" step="0.000001" min="0" />
          </label>
        </div>
        <button @click="marketSell" :disabled="!account || txBusy">Market Sell</button>
      </div>
  
      <hr />
  
      <div>
        <h3>Cancel Order</h3>
        <label>
          Order ID
          <input v-model="cancelOrderId" type="number" min="1" step="1" />
        </label>
        <button @click="cancelOrder" :disabled="!account || txBusy">
          Cancel
        </button>
      </div>
    </div>
  </template>
  
  <script setup>
  import { ref, computed, onUnmounted } from "vue";
  import { ethers } from "ethers";
  
  /* ====== addresses ====== */
  const DOGE = "0xDB3b249a3e4D52364962e4b0f45BE999Fa94cDf1";
  const USDT = "0xd85314a65BFd6Bc4CCe1AaA82C6E86350E143bbC";
  const DEX  = "0x79F051e7D5C7b05ad73d5b1452ef18D96472aDCE";
  
  /* ====== ABIs ====== */
  const ERC20_ABI = [
    "function decimals() view returns (uint8)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 value) returns (bool)",
  ];
  
  const DEX_ABI = [
    "error InvalidAmount()",
    "error InvalidPrice()",
    "error TransferFailed()",
    "error InsufficientLiquidity()",
    "function marketBuy(uint256 maxQuoteIn)",
    "function marketSell(uint256 amountBase)",
    "function limitBuy(uint256 price, uint256 amountBase)",
    "function limitSell(uint256 price, uint256 amountBase)",
    "function cancelOrder(uint256 orderId)",
    "function getLastPrice() view returns (uint256)",
    "function getOrderBookDepth(uint256 topN) view returns (uint256[] bidPrices, uint256[] bidSizes, uint256[] askPrices, uint256[] askSizes)",
    "event Trade(uint256,address,address,uint8,uint256,uint256)",
  ];
  
  /* ====== wallet state ====== */
  const account = ref("");
  const chainId = ref(null);
  const status = ref("Not connected.");
  const connecting = ref(false);
  
  let provider = null;
  let signer = null;
  
  /* ====== contract state ====== */
  let dex = null;
  let usdt = null;
  let doge = null;
  
  /* ====== data ====== */
  const dexStatus = ref("");
  const txBusy = ref(false);
  
  const usdtDecimals = ref(6);
  const dogeDecimals = ref(18);
  
  const lastPriceRaw = ref(0n);
  const bids = ref([]);
  const asks = ref([]);
  
  const usdtAllowance = ref(0n);
  const dogeAllowance = ref(0n);
  
  /* ====== inputs ====== */
  const limitPrice = ref("0.10");
  const limitAmountBase = ref("100");
  const marketMaxQuoteIn = ref("10");
  const marketSellAmountBase = ref("100");
  const cancelOrderId = ref("");
  
  let pollTimer = null;
  
  /* ====== computed ====== */
  const needSepolia = computed(
    () => account.value && Number(chainId.value) !== 11155111
  );
  
  const lastPriceDisplay = computed(() =>
    ethers.formatUnits(lastPriceRaw.value || 0n, 18)
  );
  
  const usdtAllowanceDisplay = computed(() =>
    ethers.formatUnits(usdtAllowance.value || 0n, usdtDecimals.value)
  );
  const dogeAllowanceDisplay = computed(() =>
    ethers.formatUnits(dogeAllowance.value || 0n, dogeDecimals.value)
  );
  
  /* ====== helpers ====== */
  function toScaledPrice(p) {
    return ethers.parseUnits(String(p), 18);
  }
  function toBaseAmount(v) {
    return ethers.parseUnits(String(v), dogeDecimals.value);
  }
  function toQuoteAmount(v) {
    return ethers.parseUnits(String(v), usdtDecimals.value);
  }
  
  /* ====== connect ====== */
  async function connectWallet() {
    try {
      connecting.value = true;
      status.value = "Connecting wallet...";
  
      if (!window.ethereum) {
        throw new Error("MetaMask not found");
      }
  
      provider = new ethers.BrowserProvider(window.ethereum);
      await provider.send("eth_requestAccounts", []);
  
      signer = await provider.getSigner();
      account.value = await signer.getAddress();
  
      const net = await provider.getNetwork();
      chainId.value = Number(net.chainId);
  
      status.value =
        chainId.value === 11155111
          ? "Connected to Sepolia."
          : `Connected, but NOT Sepolia. chainId=${chainId.value}`;
  
      if (chainId.value !== 11155111) return;
  
      dex = new ethers.Contract(DEX, DEX_ABI, signer);
      usdt = new ethers.Contract(USDT, ERC20_ABI, signer);
      doge = new ethers.Contract(DOGE, ERC20_ABI, signer);
  
      usdtDecimals.value = Number(await usdt.decimals());
      dogeDecimals.value = Number(await doge.decimals());
  
      attachTradeListener();
      await refreshAll();
      startPolling();
  
      dexStatus.value = "DEX initialized.";
    } catch (e) {
      console.error(e);
      dexStatus.value = `Init error: ${e.message || e}`;
    } finally {
      connecting.value = false;
    }
  }
  
  async function switchToSepolia() {
    await window.ethereum.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: "0xaa36a7" }],
    });
  }
  
  /* ====== listeners ====== */
  function attachTradeListener() {
    try { dex.removeAllListeners("Trade"); } catch {}
    dex.on("Trade", async () => {
      try { await refreshAll(); } catch {}
    });
  }
  
  /* ====== refresh ====== */
  async function refreshAll() {
    await Promise.all([
      refreshPriceAndDepth(),
      refreshAllowances(),
    ]);
  }
  
  async function refreshPriceAndDepth() {
    lastPriceRaw.value = await dex.getLastPrice();
  
    const [bp, bs, ap, asz] = await dex.getOrderBookDepth(5);
  
    bids.value = bp
      .map((p, i) => ({ p, s: bs[i] }))
      .filter(x => x.p && x.s)
      .map(x => ({
        price: ethers.formatUnits(x.p, 18),
        size: ethers.formatUnits(x.s, dogeDecimals.value),
      }));
  
    asks.value = ap
      .map((p, i) => ({ p, s: asz[i] }))
      .filter(x => x.p && x.s)
      .map(x => ({
        price: ethers.formatUnits(x.p, 18),
        size: ethers.formatUnits(x.s, dogeDecimals.value),
      }));
  }
  
  async function refreshAllowances() {
    usdtAllowance.value = await usdt.allowance(account.value, DEX);
    dogeAllowance.value = await doge.allowance(account.value, DEX);
  }
  
  /* ====== polling ====== */
  function startPolling() {
    stopPolling();
    pollTimer = setInterval(async () => {
      if (!dex || txBusy.value) return;
      try { await refreshPriceAndDepth(); } catch {}
    }, 3000);
  }
  
  function stopPolling() {
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = null;
  }
  
  /* ====== approve ====== */
  async function approveUSDT() {
    await approveToken(usdt, usdtDecimals.value, "USDT");
  }
  async function approveDOGE() {
    await approveToken(doge, dogeDecimals.value, "DOGE");
  }
  
  async function approveToken(token, dec, label) {
    try {
      txBusy.value = true;
      dexStatus.value = `Approving ${label}...`;
      const big = ethers.parseUnits("1000000000", dec);
      const tx = await token.approve(DEX, big);
      await tx.wait();
      dexStatus.value = `✅ ${label} approved.`;
      await refreshAllowances();
    } catch (e) {
      dexStatus.value = `Approve error: ${e.message || e}`;
    } finally {
      txBusy.value = false;
    }
  }
  
  /* ====== trading ====== */
  async function sendTx(buildTx, label) {
    if (!account.value) return;
    if (needSepolia.value) return;
  
    try {
      txBusy.value = true;
      dexStatus.value = `${label}: sending tx...`;
      const tx = await buildTx();
      await tx.wait();
      dexStatus.value = `✅ ${label} confirmed.`;
      await refreshAll();
    } catch (e) {
      dexStatus.value = `${label} error: ${e.message || e}`;
    } finally {
      txBusy.value = false;
    }
  }
  
  function limitBuy() {
    return sendTx(
      () => dex.limitBuy(toScaledPrice(limitPrice.value), toBaseAmount(limitAmountBase.value)),
      "Limit Buy"
    );
  }
  
  function limitSell() {
    return sendTx(
      () => dex.limitSell(toScaledPrice(limitPrice.value), toBaseAmount(limitAmountBase.value)),
      "Limit Sell"
    );
  }
  
  function marketBuy() {
    return sendTx(
      () => dex.marketBuy(toQuoteAmount(marketMaxQuoteIn.value)),
      "Market Buy"
    );
  }
  
  function marketSell() {
    return sendTx(
      () => dex.marketSell(toBaseAmount(marketSellAmountBase.value)),
      "Market Sell"
    );
  }
  
  function cancelOrder() {
    const id = BigInt(cancelOrderId.value || "0");
    if (id <= 0n) return;
    return sendTx(() => dex.cancelOrder(id), "Cancel Order");
  }
  
  /* ====== cleanup ====== */
  onUnmounted(() => {
    stopPolling();
    try { dex?.removeAllListeners?.("Trade"); } catch {}
  });
  </script>
  