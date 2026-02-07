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
      <div>USDT balance: {{ usdtBalanceDisplay }}</div>
      <div>DOGE balance: {{ dogeBalanceDisplay }}</div>
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

      <div style="margin-top: 10px;">
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

    <hr />

    <div>
      <h3>My Open Orders</h3>
      <button @click="refreshMyOrders" :disabled="!account || txBusy">
        Refresh My Orders
      </button>

      <div v-if="myOrders.length === 0" style="margin-top: 8px;">(empty)</div>

      <div
        v-for="o in myOrders"
        :key="String(o.id)"
        style="margin-top: 12px; padding: 10px; border: 1px solid #ddd; border-radius: 8px;"
      >
        <div>
          <b>#{{ String(o.id) }}</b>
          | {{ o.sideLabel }}
          | price: {{ o.priceDisplay }} USDT/DOGE
        </div>
        <div style="margin-top: 4px;">
          remaining: {{ o.remainingDisplay }} DOGE
          | filled: {{ o.filledDisplay }} DOGE
          | total: {{ o.amountDisplay }} DOGE
          | active: {{ o.active }}
        </div>

        <button
          @click="cancelOrderById(o.id)"
          :disabled="!account || txBusy"
          style="margin-top: 8px;"
        >
          Cancel #{{ String(o.id) }}
        </button>
      </div>
    </div>
  </div>
</template>

<script setup>
import { ref, computed, onUnmounted } from "vue";
import { ethers } from "ethers";

/* ====== addresses (replace with yours) ====== */
// const DOGE = "0xDB3b249a3e4D52364962e4b0f45BE999Fa94cDf1";
// const USDT = "0xd85314a65BFd6Bc4CCe1AaA82C6E86350E143bbC";
// const DEX = "0x98311e042f2E8d09dFe7D4629E349f85c6ACd22E";

/* ====== addresses (replace with yours) ====== */
const DOGE = "0xd18d98fdFaBE86a7AD0114a9985F75f9FD6992DE";
const USDT = "0x4a3FEA9668eE4a2802EaBf4808dFCdEBc474439e";
// const DEX  = "0xEd6b84B9FC05370C9E88C706DeA0eC37948fBC1C";
const DEX  = "0x887D9Af1241a176107d31Bb3C69787DFff6dbaD8";

/* ====== ABIs ====== */
const ERC20_ABI = [
  "function decimals() view returns (uint8)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 value) returns (bool)",
];

const DEX_ABI = [
  // Errors
  "error InvalidAmount()",
  "error InvalidPrice()",
  "error TransferFailed()",
  "error InsufficientBalance()",
  "error NotActive()",
  "error NotOwner()",
  "error UnsupportedBaseToken()",

  // Multi-base functions (需要 base 参数)
  "function marketBuyFor(address base, uint256 maxQuoteIn)",
  "function marketSellFor(address base, uint256 amountBase)",
  "function limitBuyFor(address base, uint256 price, uint256 amountBase) returns (uint256 orderId)",
  "function limitSellFor(address base, uint256 price, uint256 amountBase) returns (uint256 orderId)",
  "function cancelOrder(uint256 orderId)",

  // Deposit/Withdraw functions
  "function depositBaseFor(address base, uint256 amount)",
  "function withdrawBaseFor(address base, uint256 amount)",
  "function depositQuote(uint256 amount)",
  "function withdrawQuote(uint256 amount)",

  // View functions
  "function getLastPriceFor(address base) view returns (uint256)",
  "function getOrderBookDepthFor(address base, uint256 topN) view returns (uint256[] bidPrices, uint256[] bidSizes, uint256[] askPrices, uint256[] askSizes)",
  
  // Order view functions (multi-base version)
  "function getMyOpenOrdersFor(address base) view returns (tuple(uint256 id, address baseToken, uint8 side, uint256 price, uint256 amountBase, uint256 filledBase, uint256 remainingBase, uint256 timestamp, bool active)[])",
  "function getOpenOrdersOfFor(address trader, address base) view returns (tuple(uint256 id, address baseToken, uint8 side, uint256 price, uint256 amountBase, uint256 filledBase, uint256 remainingBase, uint256 timestamp, bool active)[])",
  
  // Support management
  "function supportBaseToken(address base)",
  "function getSupportedBases() view returns (address[])",
  "function supportedBasesLength() view returns (uint256)",
  "function supportedBaseAt(uint256 index) view returns (address)",

  // Balance views
  "function quoteBalance(address) view returns (uint256)",
  "function baseBalance(address, address) view returns (uint256)",
  
  // Immutables
  "function quoteToken() view returns (address)",
  "function quoteDecimals() view returns (uint8)",
  "function PRICE_SCALE() view returns (uint256)",

  // Owner functions
  "function owner() view returns (address)",
  "function transferOwnership(address newOwner)",
  "function renounceOwnership()",

  // Events
  "event Trade(uint256 indexed makerOrderId, address indexed maker, address indexed taker, uint8 takerSide, uint256 price, uint256 amountBase)",
  "event LimitOrderPlaced(uint256 indexed orderId, address indexed trader, uint8 side, uint256 price, uint256 amountBase)",
  "event OrderCancelled(uint256 indexed orderId, address indexed trader)",
  "event Deposited(address indexed trader, address indexed token, uint256 amount)",
  "event Withdrawn(address indexed trader, address indexed token, uint256 amount)",
  "event BaseTokenSupported(address indexed baseToken, uint8 decimals)"
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
const usdtBalance = ref(0n);
const dogeBalance = ref(0n);

// ✅ my open orders
const myOrders = ref([]);

/* ====== inputs ====== */
const limitPrice = ref("0.10");
const limitAmountBase = ref("100");
const marketMaxQuoteIn = ref("10");
const marketSellAmountBase = ref("100");
const cancelOrderId = ref("");

let pollTimer = null;

/* ====== computed ====== */
const needSepolia = computed(() => account.value && Number(chainId.value) !== 688689);

const lastPriceDisplay = computed(() => ethers.formatUnits(lastPriceRaw.value || 0n, 18));

const usdtAllowanceDisplay = computed(() => ethers.formatUnits(usdtAllowance.value || 0n, usdtDecimals.value));
const dogeAllowanceDisplay = computed(() => ethers.formatUnits(dogeAllowance.value || 0n, dogeDecimals.value));
const usdtBalanceDisplay = computed(() => ethers.formatUnits(usdtBalance.value || 0n, usdtDecimals.value));
const dogeBalanceDisplay = computed(() => ethers.formatUnits(dogeBalance.value || 0n, dogeDecimals.value));

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

    if (!window.ethereum) throw new Error("MetaMask not found");

    provider = new ethers.BrowserProvider(window.ethereum);
    await provider.send("eth_requestAccounts", []);

    signer = await provider.getSigner();
    account.value = await signer.getAddress();

    const net = await provider.getNetwork();
    chainId.value = Number(net.chainId);

    status.value =
      chainId.value === 688689
        ? "Connected to Sepolia."
        : `Connected, but NOT Sepolia. chainId=${chainId.value}`;

    if (chainId.value !== 688689) return;

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
    params: [{ chainId: "0xaa36a7" }], // 688689
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
    refreshMyOrders(), // ✅
  ]);
}

async function refreshPriceAndDepth() {
  lastPriceRaw.value = await dex.getLastPriceFor(DOGE);

  const [bp, bs, ap, asz] = await dex.getOrderBookDepthFor(DOGE, 5);

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
  usdtBalance.value = await dex.quoteBalance(account.value);
  dogeBalance.value = await dex.baseBalance(account.value, DOGE);
}

// ✅ new
async function refreshMyOrders() {
  if (!dex || !account.value) {
    myOrders.value = [];
    return;
  }

  const raw = await dex.getMyOpenOrdersFor(DOGE); // OrderView[]

  myOrders.value = raw.map((o) => {
    const sideNum = Number(o.side); // BUY=0, SELL=1
    return {
      id: o.id,
      baseToken: o.baseToken,
      side: o.side,
      price: o.price,
      amountBase: o.amountBase,
      filledBase: o.filledBase,
      remainingBase: o.remainingBase,
      timestamp: o.timestamp,
      active: o.active,

      sideLabel: sideNum === 0 ? "BUY" : "SELL",
      priceDisplay: ethers.formatUnits(o.price, 18),
      amountDisplay: ethers.formatUnits(o.amountBase, dogeDecimals.value),
      filledDisplay: ethers.formatUnits(o.filledBase, dogeDecimals.value),
      remainingDisplay: ethers.formatUnits(o.remainingBase, dogeDecimals.value),
    };
  });
}

/* ====== polling ====== */
function startPolling() {
  stopPolling();
  pollTimer = setInterval(async () => {
    if (!dex || txBusy.value) return;
    try {
      await refreshPriceAndDepth();
      await refreshMyOrders(); // ✅
    } catch {}
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
    () => dex.limitBuyFor(DOGE, toScaledPrice(limitPrice.value), toBaseAmount(limitAmountBase.value)),
    "Limit Buy"
  );
}

function limitSell() {
  return sendTx(
    () => dex.limitSellFor(DOGE, toScaledPrice(limitPrice.value), toBaseAmount(limitAmountBase.value)),
    "Limit Sell"
  );
}

function marketBuy() {
  return sendTx(
    () => dex.marketBuyFor(DOGE, toQuoteAmount(marketMaxQuoteIn.value)),
    "Market Buy"
  );
}

function marketSell() {
  return sendTx(
    () => dex.marketSellFor(DOGE, toBaseAmount(marketSellAmountBase.value)),
    "Market Sell"
  );
}

function cancelOrder() {
  const id = BigInt(cancelOrderId.value || "0");
  if (id <= 0n) return;
  return sendTx(() => dex.cancelOrder(id), "Cancel Order");
}

// ✅ one-click cancel from list
function cancelOrderById(orderId) {
  return sendTx(() => dex.cancelOrder(orderId), `Cancel Order #${String(orderId)}`);
}

/* ====== cleanup ====== */
onUnmounted(() => {
  stopPolling();
  try { dex?.removeAllListeners?.("Trade"); } catch {}
});
</script>
