# MultiBaseOrderBookDEXVaultLevels 合约：测试与覆盖率

本文档仅针对合约 `MultiBaseOrderBookDEXVaultLevels` 的单元测试与覆盖率：如何运行、如何读覆盖率报告、以及当前覆盖率结果快照。

## 1. 相关文件

-   合约：`contracts/MultiBaseOrderBookDEXVaultLevels.sol`
-   测试：`test/MultiBaseOrderBookDEXVaultLevels.js`
-   覆盖率 HTML：`coverage/index.html`

## 2. 快速运行

在仓库根目录执行：

-   运行该合约测试：`npx hardhat test test/MultiBaseOrderBookDEXVaultLevels.js`
-   运行全部测试：`npm test`
-   生成覆盖率（包含该合约条目）：`npm run coverage`

按用例名称筛选：

-   `npx hardhat test test/MultiBaseOrderBookDEXVaultLevels.js --grep "price improvement"`

## 3. 覆盖率结果快照（可直接引用）

以下数据来自最近一次在本仓库执行 `npm test` 与 `npm run coverage` 的输出（日期：2026-02-09）：

-   单元测试：`31 passing`
-   `MultiBaseOrderBookDEXVaultLevels.sol` 覆盖率：
    -   `% Stmts: 84.15`
    -   `% Branch: 65.63`
    -   `% Funcs: 97.22`
    -   `% Lines: 82.97`

说明：覆盖率命令会统计所有被编译的合约，所以你可能会看到其他合约条目为 `0%`；这不影响你评估 `MultiBaseOrderBookDEXVaultLevels.sol`。

## 4. 该合约测试覆盖范围（按功能模块）

测试围绕该合约的对外接口与关键行为展开，主要包含：

### 4.1 Base 支持与枚举

-   `supportBaseToken` 后的枚举接口：`getSupportedBases` / `supportedBasesLength` / `supportedBaseAt`
-   不支持的 base 调用 view / 交易 / 资产接口时，触发 `UnsupportedBaseToken`

### 4.2 资金管理（内部余额）

-   `depositQuote` / `withdrawQuote`
-   `depositBaseFor` / `withdrawBaseFor`
-   `InvalidAmount` / `InsufficientBalance` 等错误分支

### 4.3 限价单、撤单与撮合

-   `limitSellFor` + `limitBuyFor` 交叉撮合：成交价使用 ask 价（maker ask）
-   同价位 FIFO：同一 price level 内，早挂单优先被吃
-   `cancelOrder`：
    -   BUY 单退回剩余 `lockedQuote`
    -   SELL 单退回未成交 base
    -   非 owner 撤单触发 `NotOwner`
    -   已 inactive 再撤触发 `NotActive`

### 4.4 Market 单

-   `marketBuyFor(base, maxQuoteIn)`：在无法买到最小 base 单位时不应消耗 quote
-   `marketSellFor(base, amountBase)`：余额不足触发 `InsufficientBalance`

### 4.5 OrderBook 深度与 price level 维护

-   `getOrderBookDepthFor(base, topN)`：
    -   同价位聚合 size
    -   不同 base 的 orderbook 隔离
    -   `topN=0` 时默认 `topN=10`
-   price level 有序链表：
    -   bid 按价格从高到低
    -   ask 按价格从低到高
    -   撤单后 best price 能正确更新（且测试避免撮合干扰）

### 4.6 不同 base decimals 的换算

-   baseDecimals=8（例如 WBTC）下，quote/base 换算与成交结算正常

### 4.7 Open orders 视图

-   `getOpenOrdersOfFor` / `getMyOpenOrdersFor`：已成交/已取消订单不应出现在 open 列表中

## 5. 如何阅读覆盖率报告（定位未覆盖代码）

1. 运行：`npm run coverage`

2. 打开 HTML：`coverage/index.html`

3. 在列表中找到 `MultiBaseOrderBookDEXVaultLevels.sol`，点击进入后：

-   红色/黄色高亮区域就是未覆盖或分支未覆盖的位置
-   分支覆盖（Branch）通常比行覆盖更难拉满，常见原因是：`if/else` 其中一侧没跑到、`while` 循环没覆盖到退出/空列表分支等

## 6. 常用断言写法

本仓库使用 Hardhat Chai Matchers：

-   revert（自定义错误）：`await expect(tx).to.be.revertedWithCustomError(contract, "ErrorName")`

示例：

-   `await expect(dex.marketBuyFor(base, 0)).to.be.revertedWithCustomError(dex, "InvalidAmount")`
