const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("DeployDemo", (m) => {
  const usdt = m.contract(
    "MockERC20",
    ["Mock USDT", "USDT", 6],
    { id: "USDT_Mock" }
  );

  const doge = m.contract(
    "MockERC20",
    ["Mock DOGE", "DOGE", 18],
    { id: "DOGE_Mock" }
  );

  const dex = m.contract(
    "SinglePairOrderBookDEX",
    [doge, usdt],
    { id: "DEX_USDT_DOGE" }
  );

  return { usdt, doge, dex };
});
