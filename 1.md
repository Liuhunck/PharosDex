# MultiBaseOrderBookDEXVaultLevels 合约详解（逐函数）

> 目标读者：需要集成/审计/二次开发该合约的开发者。
>
> 合约文件：`contracts/MultiBaseOrderBookDEXVaultLevels.sol`
>
> 设计关键词：多 base 单 quote、金库/内部账本（deposit/withdraw）、按价格档位（price level）分桶、同价 FIFO、价格档位链表（bestBid/bestAsk 指针）、订单 ID 使用 hash（避免全局自增）。

## 1. 核心概念与单位

-   **quoteToken**：统一的计价币（例如 USDT）。所有价格、买入成本、卖出收入都以 quote 计。
-   **baseToken**：可支持多个（例如 BTC、ETH…），每个 base 都有独立的订单簿与 bestBid/bestAsk。
-   **PRICE_SCALE = 1e18**：价格缩放。
    -   价格 `price` 的含义是：`1 base` 需要多少 `quote`，再乘以 `1e18`。
    -   即：`price = (quote / base) * 1e18`。
-   **最小单位**：
    -   `amountBase / filledBase / remainingBase` 都是 base token 的最小单位（例如 ETH 的 wei）。
    -   `quoteBalance / lockedQuote / tradeQuote` 都是 quote token 的最小单位。

## 2. 资金模型（Vault / 内部账本）

合约不在每笔撮合时做 ERC20 transfer；用户先把 token **充值到合约**，合约维护内部余额：

-   `quoteBalance[trader]`：trader 的 quote 内部余额。
-   `baseBalance[trader][base]`：trader 的某个 base 内部余额。

撮合成交时只改内部账本；只有 `deposit*` / `withdraw*` 才会触发 ERC20 转账。

### 买单的 `lockedQuote`

-   BUY 限价单会提前把该单所需 quote 从 `quoteBalance` 扣掉，并记录在订单的 `lockedQuote` 中。
-   成交时逐步消耗 `lockedQuote`；如果最终未用完（价格改善或取整产生的 dust），在订单完全成交或取消时退回到 `quoteBalance`。

## 3. 订单簿结构（按价格分桶 + FIFO）

对每个 base、每个 side（BUY/SELL）分别维护：

-   **价格档位（PriceLevel）链表**：

    -   BUY：按价格从高到低排序，`bestBidPrice[base]` 指向最高买价。
    -   SELL：按价格从低到高排序，`bestAskPrice[base]` 指向最低卖价。
    -   每个 price level 通过 `prevPrice/nextPrice` 串起来。

-   **同一价格下的订单链表（FIFO）**：

    -   `PriceLevel.head/tail` 是订单 id 的双向链表首尾。
    -   `Order.prev/next` 用于连接同价位订单。
    -   新订单 append 到 tail，保证同价 FIFO。

-   **深度聚合**：
    -   `PriceLevel.totalRemainingBase` 维护该价位下所有“剩余 base 数量”的聚合值，用于快速 depth 查询。

## 4. 存储结构一览（便于对照文档）

-   `IERC20 public immutable quoteToken;`
-   `uint8 public immutable quoteDecimals;`
-   `mapping(address => bool) public isBaseSupported;`
-   `mapping(address => uint8) public baseDecimals;`
-   `address[] private supportedBases;`

-   `mapping(address => uint256) public quoteBalance;`
-   `mapping(address => mapping(address => uint256)) public baseBalance;`

-   `mapping(uint256 => Order) public orders;`
-   `mapping(address => mapping(address => uint64)) public userOrderNonce;`
-   `mapping(address => mapping(address => uint256[])) private traderOrderIds;`

-   `mapping(address => uint256) public bestBidPrice;`
-   `mapping(address => uint256) public bestAskPrice;`
-   `mapping(address => mapping(uint256 => PriceLevel)) private bidLevels;`
-   `mapping(address => mapping(uint256 => PriceLevel)) private askLevels;`

-   `mapping(address => uint256) public lastTradePriceForBase;`（按 base 记录最近成交价，单位 1e18）

## 5. 逐函数说明

下面按源码出现顺序说明每个函数“做什么、怎么做、改哪些状态、发哪些事件”。

---

### 5.1 构造函数

#### `constructor(address _quote) Ownable(msg.sender)`

-   **目的**：初始化 quote token 与其 decimals，并设置 owner。
-   **关键步骤**：
    1. `quoteToken = IERC20(_quote)`。
    2. `quoteDecimals = IERC20Metadata(_quote).decimals()`。
-   **状态变化**：设置 immutable 变量。
-   **事件**：无。

---

### 5.2 管理员：支持 base

#### `supportBaseToken(address base) external onlyOwner`

-   **目的**：由 owner 把一个 base token 加入支持列表。
-   **内部调用**：`_supportBaseToken(base)`。

#### `_supportBaseToken(address base) internal`

-   **目的**：实际执行支持 base 的逻辑。
-   **校验**：
    -   `base != address(0)`，否则 `UnsupportedBaseToken()`。
    -   若 `isBaseSupported[base]` 已为 true，直接 return（幂等）。
-   **关键步骤**：
    1. 读取 decimals：`uint8 d = IERC20Metadata(base).decimals()`。
    2. 写入缓存：`isBaseSupported[base] = true; baseDecimals[base] = d;`。
    3. 写入可枚举列表：`supportedBases.push(base)`。
    4. `emit BaseTokenSupported(base, d)`。
-   **状态变化**：支持列表与 decimals 缓存更新。

#### `_requireSupportedBase(address base) internal view`

-   **目的**：所有 base 相关函数入口都调用，确保 base 已被支持。
-   **行为**：若 `!isBaseSupported[base]` 则 revert `UnsupportedBaseToken()`。

---

### 5.3 支持 base 的枚举接口

#### `getSupportedBases() external view returns (address[] memory)`

-   **目的**：一次性返回当前支持的 base 列表（给前端/脚本）。
-   **注意**：返回数组可能较长，链上调用有 gas 成本，链下 call 没问题。

#### `supportedBasesLength() external view returns (uint256)`

-   **目的**：返回 `supportedBases.length`。
-   **用途**：前端分页/逐个读取。

#### `supportedBaseAt(uint256 index) external view returns (address)`

-   **目的**：返回 `supportedBases[index]`。
-   **行为**：越界会由 Solidity 自动 revert。

---

### 5.4 充值/提现吗（触发 ERC20 transfer 的边界函数）

#### `depositBaseFor(address base, uint256 amount) public`

-   **目的**：把某个 base 充值到内部账本。
-   **校验**：
    -   base 必须支持：`_requireSupportedBase(base)`。
    -   `amount != 0`，否则 `InvalidAmount()`。
-   **关键步骤**：
    1. `_safeTransferFrom(base, msg.sender, address(this), amount)`：把 base 从用户转入合约。
    2. `baseBalance[msg.sender][base] += amount`：内部记账。
    3. `emit Deposited(msg.sender, base, amount)`。

#### `withdrawBaseFor(address base, uint256 amount) public`

-   **目的**：从内部账本提走 base。
-   **校验**：
    -   base 支持、amount 非 0。
    -   `baseBalance[msg.sender][base] >= amount`，否则 `InsufficientBalance()`。
-   **关键步骤**：
    1. 先扣账：`baseBalance[msg.sender][base] -= amount`。
    2. `_safeTransfer(base, msg.sender, amount)`：从合约把 token 转给用户。
    3. `emit Withdrawn(...)`。

#### `depositQuote(uint256 amount) external`

-   **目的**：充值 quote。
-   **校验**：`amount != 0`。
-   **关键步骤**：
    1. `_safeTransferFrom(address(quoteToken), msg.sender, address(this), amount)`。
    2. `quoteBalance[msg.sender] += amount`。
    3. emit `Deposited(msg.sender, address(quoteToken), amount)`。

#### `withdrawQuote(uint256 amount) external`

-   **目的**：提现 quote。
-   **校验**：`amount != 0` 且 `quoteBalance[msg.sender] >= amount`。
-   **关键步骤**：
    1. `quoteBalance[msg.sender] -= amount`。
    2. `_safeTransfer(address(quoteToken), msg.sender, amount)`。
    3. emit `Withdrawn(...)`。

---

### 5.5 查询：我的挂单 / 指定地址挂单

#### `getMyOpenOrdersFor(address base) external view returns (OrderViewMulti[] memory)`

-   **目的**：便捷接口：查询调用者在某 base 的未完成挂单。
-   **内部调用**：`getOpenOrdersOfFor(msg.sender, base)`。

#### `getOpenOrdersOfFor(address trader, address base) public view returns (OrderViewMulti[] memory)`

-   **目的**：查询 `trader` 在某 base 的“仍 active 且未完全成交”的订单列表。
-   **关键实现方式**：
    -   该合约没有全局遍历订单簿，而是维护了 `traderOrderIds[trader][base]` 历史数组。
    -   查询时遍历这个数组，过滤出：`o.active && o.filledBase < o.amountBase`。
-   **步骤**：
    1. 校验 base supported。
    2. 第一次循环统计 count（用于分配返回数组）。
    3. 第二次循环组装 `OrderViewMulti`：计算 `remainingBase = amountBase - filledBase`。
-   **注意**：
    -   `traderOrderIds` 会累积历史订单，理论上会变大；这是“读取方便 vs 写入/存储增长”的取舍。

---

### 5.6 查询：最近成交价（按 base）

#### `getLastPriceFor(address base) external view returns (uint256)`

-   **目的**：返回 `lastTradePriceForBase[base]`（该 base 的最近一次成交价，单位 1e18）。
-   **注意**：不同 base 的成交价互不覆盖。

---

### 5.7 查询：盘口深度（按价位聚合）

#### `getOrderBookDepthFor(address base, uint256 topN) public view returns (uint256[] memory, uint256[] memory, uint256[] memory, uint256[] memory)`

-   **目的**：返回买卖两边各 topN 个价位的聚合深度：
    -   `bidPrices[]`, `bidSizes[]`, `askPrices[]`, `askSizes[]`
-   **行为**：
    -   `topN == 0` 时默认当作 10。
    -   depth 来自 `PriceLevel.totalRemainingBase`，不会逐单累加。
-   **内部调用**：
    -   `_depthFromLevelsBid(base, topN)`
    -   `_depthFromLevelsAsk(base, topN)`

#### `_depthFromLevelsBid(address base, uint256 topN) internal view returns (uint256[] memory prices, uint256[] memory sizes)`

-   **目的**：从 `bestBidPrice[base]` 开始沿着 `nextPrice`（更低价）遍历。
-   **关键点**：
    -   BUY 侧链表是 **从高到低**。
    -   `p = lvl.nextPrice` 指向下一档更低价。
-   **输出**：
    -   `prices[i] = p`
    -   `sizes[i] = lvl.totalRemainingBase`

#### `_depthFromLevelsAsk(address base, uint256 topN) internal view returns (uint256[] memory prices, uint256[] memory sizes)`

-   **目的**：从 `bestAskPrice[base]` 开始沿着 `nextPrice`（更高价）遍历。
-   **关键点**：
    -   SELL 侧链表是 **从低到高**。

---

### 5.8 交易：市价买

#### `marketBuyFor(address base, uint256 maxQuoteIn) external`

-   **目的**：用最多 `maxQuoteIn` 的 quote，沿卖盘从最优价开始吃单，买入尽可能多的 base。
-   **校验**：
    -   base supported。
    -   `maxQuoteIn != 0`。
    -   `quoteBalance[msg.sender] >= maxQuoteIn`。
-   **撮合逻辑（高层）**：
    1. `remainingQuote = maxQuoteIn`。
    2. 从 `price = bestAskPrice[base]` 开始。
    3. 在当前 `PriceLevel` 内，从 `lvl.head` 开始 FIFO 遍历订单。
    4. 对每个 ask 订单：
        - 跳过/清理无效订单（`!active` 或 `remainingBaseInOrder == 0`）：调用 `_removeOrderFromLevel`。
        - 计算在该价能买多少 base：`buyableBase = _baseForQuote(base, remainingQuote, ask.price)`。
            - 若为 0，说明剩余 quote 连 1 单位 base 都买不起，直接 return。
        - `tradeBase = min(buyableBase, remainingBaseInOrder)`。
        - `tradeQuote = _quoteForBase(base, tradeBase, ask.price)`。
    5. 记账结算：
        - `ask.filledBase += tradeBase`。
        - `remainingQuote -= tradeQuote`。
        - taker：`quoteBalance[msg.sender] -= tradeQuote; baseBalance[msg.sender][base] += tradeBase;`
        - maker：`quoteBalance[ask.trader] += tradeQuote;`
        - 档位聚合：`lvl.totalRemainingBase -= tradeBase`。
    6. 事件：`lastTradePriceForBase[base] = ask.price; emit Trade(ask.id, ask.trader, msg.sender, Side.BUY, ask.price, tradeBase)`。
    7. 若订单完全成交：`_removeOrderFromLevel(base, Side.SELL, price, oid)`。
    8. 当前档位吃完后，会通过 `bestAskPrice[base]` 重新读取最新最优卖价继续循环。

---

### 5.9 交易：市价卖

#### `marketSellFor(address base, uint256 amountBase) external`

-   **目的**：卖出 `amountBase` 的 base，沿买盘从最优价开始吃单，换取尽可能多的 quote。
-   **校验**：
    -   base supported。
    -   `amountBase != 0`。
    -   `baseBalance[msg.sender][base] >= amountBase`。
-   **撮合逻辑**：
    1. `remainingBase = amountBase`。
    2. `price = bestBidPrice[base]` 从最优买价开始。
    3. 在当前 bid level 内从 `lvl.head` FIFO 吃单。
    4. 对每个 bid 订单：
        - 清理无效订单（`!active` 或已满）：`_removeOrderFromLevel`。
        - `tradeBase = min(remainingBase, remainingBaseInOrder)`。
        - `tradeQuote = _quoteForBase(base, tradeBase, bid.price)`。
        - 检查 `bid.lockedQuote >= tradeQuote`（理论上必然满足；否则 revert）。
        - 更新 maker bid：`bid.filledBase += tradeBase; bid.lockedQuote -= tradeQuote`。
        - taker（卖方）结算：`baseBalance[msg.sender][base] -= tradeBase; quoteBalance[msg.sender] += tradeQuote`。
        - maker（买方）收 base：`baseBalance[bid.trader][base] += tradeBase`。
        - 档位聚合：`lvl.totalRemainingBase -= tradeBase`。
        - 更新 `lastTradePriceForBase[base]`，发 `Trade(bid.id, bid.trader, msg.sender, Side.SELL, bid.price, tradeBase)`。
    5. 若 bid 完全成交：把剩余 `bid.lockedQuote`（dust/改善）退回给 maker，然后移除订单。

---

### 5.10 交易：限价买

#### `limitBuyFor(address base, uint256 price, uint256 amountBase) external returns (uint256 orderId)`

-   **目的**：挂一个 BUY 限价单；先锁定该单所需 quote，然后插入买盘对应价位 FIFO 队列；最后尝试撮合。
-   **校验**：
    -   base supported。
    -   `price != 0`，否则 `InvalidPrice()`。
    -   `amountBase != 0`。
-   **锁仓 quote**：
    1. `quoteToLock = _quoteForBase(base, amountBase, price)`。
    2. `quoteToLock == 0` 视为无效（可能是精度导致），revert `InvalidAmount()`。
    3. 余额检查：`quoteBalance[msg.sender] >= quoteToLock`。
    4. 扣除内部余额：`quoteBalance[msg.sender] -= quoteToLock`。
-   **创建订单并入簿**：
    1. `orderId = _createOrder(base, Side.BUY, price, amountBase, quoteToLock)`。
    2. `_addOrderToLevel(base, Side.BUY, price, orderId)`：必要时创建 price level 并 append。
    3. emit `LimitOrderPlaced(...)`。
    4. `_tryMatch(base)`：如果此时买价 >= 最优卖价，会自动撮合。

---

### 5.11 交易：限价卖

#### `limitSellFor(address base, uint256 price, uint256 amountBase) external returns (uint256 orderId)`

-   **目的**：挂 SELL 限价单；先从内部余额扣除要卖出的 base 作为锁定，然后入簿，最后尝试撮合。
-   **校验**：
    -   base supported。
    -   `price != 0`。
    -   `amountBase != 0`。
    -   `baseBalance[msg.sender][base] >= amountBase`。
-   **锁仓 base**：`baseBalance[msg.sender][base] -= amountBase`。
-   **创建订单并入簿**：
    1. `orderId = _createOrder(base, Side.SELL, price, amountBase, 0)`（SELL 不需要 `lockedQuote`）。
    2. `_addOrderToLevel(base, Side.SELL, price, orderId)`。
    3. emit `LimitOrderPlaced(...)`。
    4. `_tryMatch(base)`。

---

### 5.12 取消订单

#### `cancelOrder(uint256 orderId) external`

-   **目的**：撤销自己还 active 的订单，并退回未成交部分锁定的资产。
-   **校验**：
    -   订单必须 `o.active == true`，否则 `NotActive()`。
    -   `o.trader == msg.sender`，否则 `NotOwner()`。
-   **关键步骤**：
    1. 先置 `o.active = false`。
    2. 计算剩余 base：`remainingBase = o.amountBase - o.filledBase`。
    3. 若 BUY：退回 `o.lockedQuote` 到 `quoteBalance`，并清零 `o.lockedQuote`。
    4. 若 SELL：把 `remainingBase` 退回到 `baseBalance[msg.sender][o.baseToken]`。
    5. `_removeOrderFromLevel(o.baseToken, o.side, o.price, orderId)`：从该价位 FIFO 链表移除。
    6. `emit OrderCancelled(orderId, msg.sender)`。

---

### 5.13 撮合主循环（按 base）

#### `_tryMatch(address base) internal`

-   **目的**：在某个 base 的买卖盘之间持续撮合，直到不再可撮合。
-   **停止条件**：
    -   任一侧为空：`bestBidPrice==0` 或 `bestAskPrice==0`。
    -   最优买价 < 最优卖价：`bidP < askP`。
    -   `_matchOnce` 返回 false（例如精度导致 tradeQuote 为 0）。
-   **循环结构**：每次读取最新的 `bestBidPrice`/`bestAskPrice` 并调用 `_matchOnce`。

#### `_matchOnce(address base, uint256 bidP, uint256 askP) internal returns (bool shouldContinue)`

-   **目的**：在给定的最优买价 `bidP` 与最优卖价 `askP` 上，撮合一笔（bid head vs ask head），并进行必要的清理。
-   **步骤**：
    1. 取两个 level 的 `head`：`bidId` 与 `askId`。若其中任何一个为 0，尝试 `_removePriceLevelIfEmpty` 并返回 true 继续。
    2. 读取订单 `bid` / `ask`，如果不 active 或已满，则从 level 移除并返回 true。
    3. 计算剩余：`bidRemain`、`askRemain`。
    4. `tradeBase = min(bidRemain, askRemain)`。
    5. **成交价**选用 `tradePrice = ask.price`（当前实现是“以卖单价格成交”）。
    6. `tradeQuote = _quoteForBase(base, tradeBase, tradePrice)`，若为 0 返回 false（避免无限循环）。
    7. 检查 `bid.lockedQuote >= tradeQuote`。
    8. 更新订单状态：
        - `bid.filledBase += tradeBase; bid.lockedQuote -= tradeQuote;`
        - `ask.filledBase += tradeBase;`
    9. 更新内部余额：
        - 买方（bid maker）收 base：`baseBalance[bid.trader][base] += tradeBase`。
        - 卖方（ask maker）收 quote：`quoteBalance[ask.trader] += tradeQuote`。
    10. 更新两边档位聚合：`totalRemainingBase -= tradeBase`。
    11. 更新 `lastTradePriceForBase[base]`，emit `Trade(ask.id, ask.trader, bid.trader, Side.BUY, tradePrice, tradeBase)`。
    12. 若 bid 满：退回剩余 `lockedQuote`（dust），并 `_removeOrderFromLevel`。
    13. 若 ask 满：`_removeOrderFromLevel`。
    14. 返回 true，表示可以继续尝试撮合下一笔。

---

### 5.14 价位与订单链表管理

#### `_addOrderToLevel(address base, Side side, uint256 price, uint256 orderId) internal`

-   **目的**：确保某价位 level 存在，并把订单 append 到该价位 FIFO 队列，更新聚合。
-   **BUY**：
    1. `_ensureBidLevel(base, price)`（必要时插入到买盘价位链表）。
    2. `PriceLevel storage lvl = bidLevels[base][price]`。
    3. `_appendOrderToLevel(lvl, orderId)`。
    4. `lvl.totalRemainingBase += (amountBase - filledBase)`。
    5. `lvl.orderCount += 1`。
-   **SELL**：同理，使用 `askLevels` + `_ensureAskLevel`。

#### `_appendOrderToLevel(PriceLevel storage lvl, uint256 orderId) internal`

-   **目的**：把订单追加到价位 FIFO 队尾。
-   **两种情况**：
    -   该价位无订单：`head = tail = orderId`。
    -   已有订单：
        -   `orders[lvl.tail].next = orderId`。
        -   `orders[orderId].prev = oldTail`。
        -   `lvl.tail = orderId`。

#### `_removeOrderFromLevel(address base, Side side, uint256 price, uint256 orderId) internal`

-   **目的**：把某订单从价位链表移除，并更新聚合、必要时删除空价位。
-   **关键步骤**：
    1. 获取对应 `PriceLevel`，若 `!lvl.exists` 直接 return。
    2. 读取订单 `o`。
    3. 聚合扣减：按该订单当前 `remainingBase = amountBase - filledBase` 从 `lvl.totalRemainingBase` 扣除（并做下溢保护）。
    4. `lvl.orderCount -= 1`（若 >0）。
    5. 从双向链表断开：根据 `o.prev/o.next` 修正前后节点与 `lvl.head/lvl.tail`。
    6. 清空 `o.prev/o.next`。
    7. **满单语义**：若 `o.filledBase >= o.amountBase`，将 `o.active = false`（确保“完全成交后不再 active”）。
    8. 调用 `_removePriceLevelIfEmpty(base, side, price)`。

#### `_removePriceLevelIfEmpty(address base, Side side, uint256 price) internal`

-   **目的**：如果某价位已经没有订单（`head==0` 且聚合/计数都为 0），把该价位从“价位链表”中移除，并维护 `bestBidPrice`/`bestAskPrice`。
-   **步骤**：
    1. 若 `!lvl.exists` return。
    2. 若该 level 仍非空（head、orderCount、totalRemainingBase 任一非 0）则 return。
    3. 根据 `prevPrice/nextPrice` 把该节点从价位链表摘除：
        - BUY：若 `prevP==0` 表示它是 best，则 `bestBidPrice = nextP`。
        - SELL：若 `prevP==0` 表示它是 best，则 `bestAskPrice = nextP`。
    4. 清掉 level 的 `prevPrice/nextPrice` 并设置 `exists=false`。

#### `_ensureBidLevel(address base, uint256 price) internal`

-   **目的**：确保买盘价位 `price` 的 PriceLevel 存在，并将其插入“从高到低”的价位链表。
-   **行为**：
    -   若 `lvl.exists` 直接 return。
    -   若当前没有 best：`bestBidPrice = price`。
    -   若 `price > best`：插到链表头，成为新 best。
    -   否则，从 `best` 向下遍历 `nextPrice`，找到插入点（保持降序）。

#### `_ensureAskLevel(address base, uint256 price) internal`

-   **目的**：确保卖盘价位 `price` 的 PriceLevel 存在，并将其插入“从低到高”的价位链表。
-   **逻辑**：与 `_ensureBidLevel` 对称，只是比较方向相反（升序）。

---

### 5.15 创建订单（hash id + nonce）

#### `_createOrder(address base, Side side, uint256 price, uint256 amountBase, uint256 lockedQuote) internal returns (uint256 id)`

-   **目的**：生成订单 id、写入 `orders[id]`、并把 id 追加到 `traderOrderIds[msg.sender][base]`。
-   **ID 生成**：
    1. `nonce = userOrderNonce[msg.sender][base]++`（每个 trader、每个 base 一条 nonce，避免全局自增争用）。
    2. `id = uint256(keccak256(abi.encodePacked(chainid, this, trader, base, nonce, side, price, amountBase)))`。
    3. 若 `id == 0` 或撞库（`orders[id].trader != 0`），则用二次 hash 加入 `timestamp` 等扰动再生成，保证尽量不冲突。
-   **写入订单**：
    -   `filledBase=0`，`active=true`，`timestamp=block.timestamp`。
    -   `lockedQuote` 只对 BUY 有意义。
-   **副作用**：把 id push 到 `traderOrderIds`，便于后续查询挂单。

---

### 5.16 精度/换算工具（base 与 quote 小数位不同）

#### `_pow10(uint8 d) internal pure returns (uint256)`

-   **目的**：返回 $10^d$。

#### `_quoteForBase(address base, uint256 baseAmount, uint256 price) internal view returns (uint256)`

-   **目的**：给定 base 数量与价格，计算需要/得到的 quote 数量（最小单位）。
-   **公式（近似地按整数除法取整向下）**：
    -   $quote = baseAmount \times price \times 10^{quoteDecimals} / (PRICE\_SCALE \times 10^{baseDecimals})$
-   **实现细节**：
    -   使用 `Math.mulDiv` 进行中间乘法，降低溢出风险与提升精度稳定性；最终除法 `numerator / denom` 仍是向下取整。

#### `_baseForQuote(address base, uint256 quoteAmount, uint256 price) internal view returns (uint256)`

-   **目的**：给定 quote 数量与价格，计算最多能换到多少 base（最小单位）。
-   **公式（向下取整）**：
    -   $base = quoteAmount \times PRICE\_SCALE \times 10^{baseDecimals} / (price \times 10^{quoteDecimals})$

---

### 5.17 安全 ERC20 转账封装

#### `_safeTransferFrom(address token, address from, address to, uint256 amount) internal`

-   **目的**：兼容“返回 bool”与“不返回值”的 ERC20。
-   **实现**：
    -   用低级 `token.call(transferFrom.selector, from, to, amount)`。
    -   条件：`ok == true` 且（若返回 data）`abi.decode(data,(bool)) == true`。
    -   否则 revert `TransferFailed()`。

#### `_safeTransfer(address token, address to, uint256 amount) internal`

-   **目的**：同上，封装 `transfer`。

## 6. 常见流程（帮助理解函数之间如何协作）

### 6.1 挂 BUY 限价单并自动撮合

1. 用户先 `depositQuote` 增加 `quoteBalance`。
2. 调用 `limitBuyFor`：
    - 计算 `quoteToLock` 并从 `quoteBalance` 扣除。
    - `_createOrder` 写入订单、`_addOrderToLevel` 插入买盘。
    - `_tryMatch` 检查是否跨价，若跨价则调用 `_matchOnce` 循环成交。
3. 成交后：
    - 买方（bid maker）增加 `baseBalance`；卖方（ask maker）增加 `quoteBalance`。
    - BUY 订单的 `lockedQuote` 会被逐步消耗，满单后退回剩余。

### 6.2 市价买（用 quote 预算吃卖盘）

1. 用户先 `depositQuote`。
2. 调用 `marketBuyFor(base, maxQuoteIn)`：
    - 从 bestAsk 开始逐价逐单吃。
    - 每次成交只改内部账本。
    - 碰到买不起 1 单位 base 时直接 return。

### 6.3 撤单

-   调用 `cancelOrder(orderId)`：
    -   BUY：退 `lockedQuote`。
    -   SELL：退未成交 base。
    -   从价位 FIFO 链表摘除，并在价位为空时从价位链表删除。

## 7. 行为/语义注意点（集成时常见坑）

-   **完全成交订单的 active**：订单满单后会在 `_removeOrderFromLevel` 里被置 `active=false`，也就是说“成交完成”与“撤单”都会导致 `active=false`。
-   **trade price 选择**：撮合函数 `_matchOnce` 目前用 `tradePrice = ask.price`（以卖价成交）。
-   **`lastTradePriceForBase` 按 base 细分**：每个 base 的最新价互不干扰。
-   **整数除法向下取整**：换算函数最终都有向下取整，可能产生 dust；BUY 的 `lockedQuote` 退款逻辑用于处理这一类剩余。

## 8. 测试覆盖（参考）

测试文件：`test/MultiBaseOrderBookDEXVaultLevels.js`

覆盖点通常包括：

-   base 支持列表枚举
-   deposit/withdraw 账本正确性
-   同价 FIFO
-   cancel 的退款（BUY 退 lockedQuote、SELL 退剩余 base）
-   depth 聚合与不同 base 的隔离

---

如果你希望我再补一份“按事件维度/按状态变量维度”的说明（例如每个事件在哪些路径会触发、每个 mapping 在哪些函数被读写），我也可以继续补一份更偏审计/集成视角的文档。
