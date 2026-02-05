import { ref } from "vue";
import { ethers } from "ethers";

export function useWeb3() {
  const account = ref("");
  const chainId = ref(null);
  const status = ref("Not connected.");
  const connecting = ref(false);

  const provider = ref(null);
  const signer = ref(null);

  function getEthereum() {
    const eth = window.ethereum;
    if (!eth) throw new Error("MetaMask not found. Please install MetaMask.");
    return eth;
  }

  async function connect() {
    try {
      connecting.value = true;
      status.value = "Connecting wallet...";

      const eth = getEthereum();
      const p = new ethers.BrowserProvider(eth);

      await p.send("eth_requestAccounts", []);
      const s = await p.getSigner();

      provider.value = p;
      signer.value = s;

      account.value = await s.getAddress();
      const net = await p.getNetwork();
      chainId.value = Number(net.chainId);

      status.value = chainId.value === 11155111
        ? "Connected to Sepolia."
        : `Connected, but NOT Sepolia. chainId=${chainId.value}.`;
    } catch (e) {
      console.error(e);
      status.value = `Connect error: ${e.message || e}`;
      throw e;
    } finally {
      connecting.value = false;
    }
  }

  async function switchToSepolia() {
    const eth = getEthereum();
    await eth.request({
      method: "wallet_switchEthereumChain",
      params: [{ chainId: "0xaa36a7" }], // 11155111
    });
  }

  function bindWalletEvents(onAccountsChanged, onChainChanged) {
    const eth = window.ethereum;
    if (!eth?.on) return;

    eth.on("accountsChanged", (accs) => {
      account.value = accs?.[0] || "";
      status.value = account.value ? "Account changed." : "Disconnected.";
      onAccountsChanged?.(accs);
    });

    eth.on("chainChanged", (cidHex) => {
      // 最稳：提示刷新（ethers v6 在 chainChanged 后重建 provider/signer 最干净）
      status.value = "Network changed. Please refresh the page.";
      onChainChanged?.(cidHex);
    });
  }

  return {
    account,
    chainId,
    status,
    connecting,
    provider,
    signer,
    connect,
    switchToSepolia,
    bindWalletEvents,
  };
}
