# Sample Hardhat Project

This project demonstrates a basic Hardhat use case. It comes with a sample contract, a test for that contract, and a Hardhat Ignition module that deploys that contract.

Try running some of the following tasks:

```shell
npx hardhat help
npx hardhat test
REPORT_GAS=true npx hardhat test
npx hardhat node
npx hardhat ignition deploy ./ignition/modules/Lock.js
```

## PharosSpotMarket (现货撮合引擎)

本仓库新增了一个单交易对的链上现货撮合合约：`PharosSpotMarket`（订单簿 + 资金托管 vault）。

### 支持功能

-   充值/提取：`deposit(token, amount)` / `withdraw(token, amount)`
-   下单：
    -   限价单：`placeLimitOrder(side, priceE18, amountBase, hintPrice, maxHops, postOnly, maxMatches)`
    -   市价单：`placeMarketOrder(side, amountBase, maxQuoteIn, minQuoteOut, maxMatches)`
-   撤单：`cancelOrder(orderId)`
-   订单簿深度：`getDepth(levels)`（返回 bid/ask 各 `levels` 档的价格与聚合数量）
-   最新成交价：`lastTradePriceE18()`

### 并行友好设计（适配高并行链）

-   **每个交易对一个合约实例**：把状态热点拆散到不同 market 合约，天然提升跨交易对并行度。
-   **撮合工作量可控**：`maxMatches` 将单笔交易的撮合次数上限化，避免超大循环导致长执行与调度拥塞。
-   **可选 hint + traversal 限制**：`hintPrice` + `maxHops` 允许前端/撮合器提供插入位置提示，减少遍历与共享状态读写。

运行测试：

```shell
npx hardhat test
```
