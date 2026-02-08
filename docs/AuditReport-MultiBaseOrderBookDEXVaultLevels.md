# 合约审计报告：MultiBaseOrderBookDEXVaultLevels

审计对象：MultiBaseOrderBookDEXVaultLevels（多 Base、单 Quote 的链上订单簿撮合，内部余额托管）

-   代码范围：[contracts/MultiBaseOrderBookDEXVaultLevels.sol](../contracts/MultiBaseOrderBookDEXVaultLevels.sol)
-   审计日期：2026-02-09
-   审计类型：快速人工智能审计（AI-assisted manual review，静态代码审阅 + 基于现有单测/覆盖率的可信度评估）
-   审计工具/模型：GPT-5.2

> 免责声明：本报告由 GPT-5.2 辅助完成，属于快速审阅结论，不构成“无风险”保证；未执行形式化验证、未做模糊测试/符号执行、未覆盖真实主网流动性与极端 gas 场景。建议上线前结合 Slither/Echidna/Foundry invariant、以及真实代币（含异常 ERC20 行为）进行更深入测试。

---

## 1. 执行摘要（偏正向结论）

整体实现质量较好，关键亮点集中在：

-   交易撮合不依赖外部 ERC20 转账，撮合全程使用“内部余额”记账，显著降低了重入与代币兼容性导致的复杂风险面。
-   订单簿使用“价位（PriceLevel）+ FIFO 订单链表”结构，并维护 bestBid/bestAsk 指针，使得深度查询与撮合推进路径更清晰、更可控。
-   算术处理使用 OpenZeppelin `Math.mulDiv` 避免中间乘法溢出，且自定义错误（custom error）使 revert 成本更低、语义更清晰。
-   对 BUY 单实现了 `lockedQuote` 锁仓，并在完全成交时退回“价差改进/舍入”带来的剩余锁仓，资金行为符合常见订单簿撮合预期。

在未发现“直接盗币”的显著漏洞前提下，本报告仍识别到 1 个较高影响的 DoS/可用性问题（见 High-01），以及若干中低风险建议。

---

## 2. 范围与威胁模型

### 2.1 范围

-   仅覆盖合约 [contracts/MultiBaseOrderBookDEXVaultLevels.sol](../contracts/MultiBaseOrderBookDEXVaultLevels.sol)
-   不包含前端、部署脚本、以及其它合约的系统级交互审计

### 2.2 默认威胁模型假设

-   攻击者可自由存入/挂单/撤单/吃单（在合约规则允许范围内）
-   Base/Quote 代币可能存在非标准 ERC20 行为（返回值、回调、手续费、黑名单、可暂停等）
-   订单簿规模可能增长到较大（潜在 gas 压力与 DoS 风险）

---

## 3. 现有测试与覆盖率证据（直接复用结果）

以下数据来自本仓库在 2026-02-09 执行的输出快照：

-   单元测试：`31 passing`
-   覆盖率（solidity-coverage）：`MultiBaseOrderBookDEXVaultLevels.sol`
    -   `% Stmts: 84.15`
    -   `% Branch: 65.63`
    -   `% Funcs: 97.22`
    -   `% Lines: 82.97`

说明：覆盖率是“可信度信号”而非安全保证；Branch 覆盖率偏低通常意味着仍有分支路径（如异常路径/循环边界）未被触达。

---

## 4. 设计与实现亮点（Good Practices）

1. **撮合期间不触碰外部代币转账**

-   `limitBuyFor/limitSellFor/marketBuyFor/marketSellFor/_matchOnce` 都基于 `quoteBalance/baseBalance` 内部账本变更。
-   外部 ERC20 交互集中在 `deposit*/withdraw*`，风险集中、可审计性更好。

2. **清晰的资金流与锁仓模型**

-   BUY：下单时锁 `lockedQuote`，成交时按成交价（ask 价）扣减，完全成交后退回剩余锁仓。
-   SELL：下单时扣减 base 内部余额，撤单/未成交部分退回。

3. **价位链表结构与 best 指针**

-   `bestBidPrice` / `bestAskPrice` 作为入口，配合 `_ensureBidLevel/_ensureAskLevel` 的有序链表插入，使得撮合推进与深度查询可预测。

4. **算术安全与 gas 友好**

-   使用 `Math.mulDiv` 降低溢出风险。
-   使用 custom error，降低 revert gas，提升可读性。

5. **对非标准 ERC20 兼容更友好**

-   `_safeTransfer/_safeTransferFrom` 使用 low-level call，并兼容“无返回值”的 ERC20。

---

## 5. 风险与问题清单

严重性分级：Critical / High / Medium / Low / Info

### High-01：Dust/零对价成交导致撮合卡死（可用性 DoS）

**描述**

-   `_matchOnce` 中若 `tradeQuote = _quoteForBase(...)` 计算结果为 `0`，函数会 `return false`，从而使 `_tryMatch` 停止撮合。
-   攻击者可以用极小 `amountBase` + 极低 `price`（尤其 SELL 单）制造 `tradeQuote == 0` 的“尘埃订单”。
-   一旦该尘埃订单处于最优 ask（或在 bestBid/bestAsk 交叉时参与撮合），就可能导致该 base 市场在合约层面持续无法继续撮合/吃单（直到攻击者自行撤单）。

**影响**

-   该 base 的订单簿撮合可能被锁死，属于高影响可用性/DoS 风险。

**触发条件（示例）**

-   Base 18 decimals、Quote 6 decimals 时，攻击者挂一个 `amountBase = 1 wei` 的 SELL 单，`price` 极低，使得 `_quoteForBase(base, 1, price) == 0`。
-   只要它处于 bestAsk（或与某个 bid 交叉），`_matchOnce` 可能因 `tradeQuote==0` 无法推进。

**修复建议**

-   在 `limitSellFor` 增加最小名义金额约束，与 BUY 的 `quoteToLock != 0` 对齐：
    -   `uint256 q = _quoteForBase(base, amountBase, price); require(q > 0, InvalidAmount());`
-   或在撮合时将 `tradeQuote==0` 视为不可撮合尘埃订单：
    -   直接移除该订单/价位（但要注意资金归属与行为一致性，避免悄然“吞单”）。

---

### Medium-01：不兼容 Fee-on-Transfer / Rebase 等特殊 ERC20

**描述**

-   `depositQuote/depositBaseFor` 以 `amount` 直接记账，但如果代币是“转账扣手续费/到帐少于 amount”，内部余额会被高估。

**影响**

-   可能导致内部余额与真实余额不一致，进而在提现时失败或造成账本失真。

**建议**

-   明确限制：仅支持标准 ERC20（无手续费、无 rebasing、无黑名单/冻结）。
-   或在 `deposit*` 使用余额差额记账（before/after balanceOf）。

---

### Medium-02：潜在的 gas/规模 DoS（长链表与历史数组）

**描述**

-   `marketBuyFor/marketSellFor` 以及 `_tryMatch` 在极端情况下会遍历大量订单与价位。
-   `getOpenOrdersOfFor` 会遍历 `traderOrderIds[trader][base]` 的全历史数组，历史过长会导致 view 调用变慢或在链上调用时 OOG。

**影响**

-   高负载时交易失败、撮合推进困难、以及 off-chain 查询延迟。

**建议**

-   明确这是“链上订单簿”的固有限制，并在产品层做：订单数量限制、最小订单名义、分页查询、或 off-chain indexer。

---

### Low-01：缺少紧急开关/恢复工具（运维能力）

**描述**

-   当前只有 `supportBaseToken` 管理功能；没有 pause、紧急提款、黑名单等机制。

**影响**

-   出现异常代币/市场攻击时，缺乏快速缓解手段。

**建议**

-   若面向生产，可考虑 `Pausable`（仅暂停交易，不影响提现）或“仅允许提现”的应急模式。

---

### Info-01：`decimals()` 依赖与支持列表不可回滚

**描述**

-   `supportBaseToken` 依赖 `IERC20Metadata(base).decimals()`；某些代币可能不实现或会 revert。
-   支持列表只增不减。

**建议**

-   在运营层面做好白名单准入测试；必要时增加“移除 base”或“禁用 base 交易”的机制。

---

## 6. 建议的补充测试（提升 Branch 覆盖）

围绕 High-01/Medium-02，建议新增：

-   尘埃订单（tradeQuote==0）行为：验证是否可阻断撮合，并在修复后验证无法挂出或会被清理。
-   大量价位/大量订单的市场单：在 gas 限制下的可执行性测试（至少做规模上限的回归）。
-   Fee-on-transfer 模拟代币（转账扣 1%）的 deposit/withdraw 账本一致性测试（若决定支持该类代币）。

---

## 7. 总结

`MultiBaseOrderBookDEXVaultLevels` 在架构上体现了较强的工程化意识：内部余额隔离外部代币风险、price level + FIFO 链表降低数组操作成本、以及对锁仓与退款的细节处理。

需要优先关注的是 **High-01（尘埃订单导致撮合卡死）**：它不一定带来直接资金损失，但可能以很低成本影响市场可用性，属于上线前应优先修复/加约束的一类问题。
