const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("MemeHubTokenModule", (m) => {
    const name = m.getParameter("name", "MemeHub");
    const symbol = m.getParameter("symbol", "MEH");

    // 1,000,000 tokens (18 decimals)
    const initialSupply = m.getParameter("initialSupply", 1_000_000n * 10n ** 18n);

    const token = m.contract("MemeHubToken", [name, symbol, initialSupply]);

    return { token };
});
