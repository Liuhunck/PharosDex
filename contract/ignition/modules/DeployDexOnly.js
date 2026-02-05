const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("DeployDexOnly", (m) => {
  // 传入你之前已经部署好的 token 地址（Sepolia）
  const usdtAddr = m.getParameter("usdtAddr");
  const dogeAddr = m.getParameter("dogeAddr");

  // 只部署新的 DEX；id 改成新名字避免和旧 future 冲突
  const dex = m.contract(
    "SinglePairOrderBookDEX",
    [dogeAddr, usdtAddr],
    { id: "DEX_USDT_DOGE_V3" }
  );

  return { dex };
});
