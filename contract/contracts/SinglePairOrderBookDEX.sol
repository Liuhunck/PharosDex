// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SinglePairOrderBookDEX { 
    IERC20 public immutable baseToken;  // DOGE 被交易的“标的币”  base（标的币）
    IERC20 public immutable quoteToken; // USDT 计价币，价格以它计  quote（计价币）
    // public：自动生成 getter：baseToken() / quoteToken()，前端可直接读
    // immutable：只在构造函数里赋值一次，之后不能改（更安全 + 更省 gas）

    uint256 public constant PRICE_SCALE = 1e18;
    // price 表示 1 个 base 值多少 quote，并乘上 1e18

    enum Side { BUY, SELL }
    // 买卖方向枚举

    struct Order {
        uint256 id;
        address trader;
        Side side;
        uint256 price;      // scaled by 1e18
        uint256 amountBase; // total base amount
        uint256 filledBase; // filled base amount
        uint256 timestamp;
        bool active;
    }

    uint256 public nextOrderId = 1;
    uint256 public lastTradePrice; // scaled by 1e18

    mapping(uint256 => Order) public orders;

    // active order id arrays (sorted):
    // bids: high price -> low price
    // asks: low price -> high price
    uint256[] public bidIds;
    uint256[] public askIds;

    event LimitOrderPlaced(uint256 indexed orderId, address indexed trader, Side side, uint256 price, uint256 amountBase);
    event OrderCancelled(uint256 indexed orderId, address indexed trader);
    event Trade(uint256 indexed makerOrderId, address indexed maker, address indexed taker, Side takerSide, uint256 price, uint256 amountBase);
    // 要做深度图 / K 线，Trade 事件是最关键的数据来源之一

    error InvalidAmount();
    error InvalidPrice();
    error NotOwner();
    error NotActive();
    error InsufficientLiquidity();
    error TransferFailed();

    constructor(address _base, address _quote) {
        baseToken = IERC20(_base);
        quoteToken = IERC20(_quote);
    }

    // -------------------------
    // 7 external interfaces
    // -------------------------

    // 1) 市价买：用 quoteToken 最多花 maxQuoteIn 去买 baseToken
    function marketBuy(uint256 maxQuoteIn) external {
        if (maxQuoteIn == 0) revert InvalidAmount();

        // 把 quote 先拉进来（未用完部分会退回）
        _safeTransferFrom(address(quoteToken), msg.sender, address(this), maxQuoteIn);

        uint256 remainingQuote = maxQuoteIn;

        // 吃 ask（从最便宜开始）
        uint256 i = 0;
        while (i < askIds.length && remainingQuote > 0) {
            uint256 oid = askIds[i];
            Order storage ask = orders[oid];
            if (!ask.active) { i++; continue; }

            uint256 remainingBaseInOrder = ask.amountBase - ask.filledBase;
            if (remainingBaseInOrder == 0) { _deactivateAndRemoveAskAt(i); continue; }

            // 在该价位，remainingQuote 能买到的 base = remainingQuote * SCALE / price
            uint256 buyableBase = (remainingQuote * PRICE_SCALE) / ask.price;
            if (buyableBase == 0) break;

            uint256 tradeBase = buyableBase < remainingBaseInOrder ? buyableBase : remainingBaseInOrder;
            uint256 tradeQuote = (tradeBase * ask.price) / PRICE_SCALE;

            // 结算：taker=msg.sender 买入 base，maker=ask.trader 卖出 base
            ask.filledBase += tradeBase;
            remainingQuote -= tradeQuote;

            // 内含了调用参数 address(this) ，因为是当前合约调用的
            _safeTransfer(address(baseToken), msg.sender, tradeBase);
            _safeTransfer(address(quoteToken), ask.trader, tradeQuote);

            lastTradePrice = ask.price;

            emit Trade(ask.id, ask.trader, msg.sender, Side.BUY, ask.price, tradeBase);

            if (ask.filledBase == ask.amountBase) {
                _deactivateAndRemoveAskAt(i);
            } else {
                i++;
            }
        }

        // 退回没花完的 quote
        if (remainingQuote > 0) {
            _safeTransfer(address(quoteToken), msg.sender, remainingQuote);
        }

        // 如果你希望“必须全成交”可以打开下面这行
        // if (remainingQuote > 0) revert InsufficientLiquidity();
    }

    // 2) 市价卖：卖 amountBase 个 baseToken，换 quoteToken
    function marketSell(uint256 amountBase) external {
        if (amountBase == 0) revert InvalidAmount();

        // 先把 base 拉进来（未卖完部分会退回）
        _safeTransferFrom(address(baseToken), msg.sender, address(this), amountBase);

        uint256 remainingBase = amountBase;

        // 吃 bid（从最高价开始）
        uint256 i = 0;
        while (i < bidIds.length && remainingBase > 0) {
            uint256 oid = bidIds[i];
            Order storage bid = orders[oid];
            if (!bid.active) { i++; continue; }

            uint256 remainingBaseInOrder = bid.amountBase - bid.filledBase;
            if (remainingBaseInOrder == 0) { _deactivateAndRemoveBidAt(i); continue; }

            uint256 tradeBase = remainingBase < remainingBaseInOrder ? remainingBase : remainingBaseInOrder;
            uint256 tradeQuote = (tradeBase * bid.price) / PRICE_SCALE;

            // maker=bid.trader 买入 base，taker=msg.sender 卖出 base
            bid.filledBase += tradeBase;
            remainingBase -= tradeBase;

            // bid 里锁的是 quote；卖出者拿 quote；买入者拿 base
            _safeTransfer(address(quoteToken), msg.sender, tradeQuote);
            _safeTransfer(address(baseToken), bid.trader, tradeBase);

            lastTradePrice = bid.price;

            emit Trade(bid.id, bid.trader, msg.sender, Side.SELL, bid.price, tradeBase);

            if (bid.filledBase == bid.amountBase) {
                _deactivateAndRemoveBidAt(i);
            } else {
                i++;
            }
        }

        // 退回没卖完的 base
        if (remainingBase > 0) {
            _safeTransfer(address(baseToken), msg.sender, remainingBase);
        }

        // 如果你希望“必须全成交”可以打开下面这行
        // if (remainingBase > 0) revert InsufficientLiquidity();
    }

    // 3) 限价买：挂单买 amountBase，价格 price
    // “我想以 price（USDT/DOGE）的价格，买 amountBase 个 DOGE”
    function limitBuy(uint256 price, uint256 amountBase) external returns (uint256 orderId) {
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();

        // 锁定 quote = amountBase * price / SCALE
        uint256 quoteToLock = (amountBase * price) / PRICE_SCALE;
        if (quoteToLock == 0) revert InvalidAmount();

        _safeTransferFrom(address(quoteToken), msg.sender, address(this), quoteToLock);

        orderId = _createOrder(Side.BUY, price, amountBase);
        _insertBid(orderId);

        emit LimitOrderPlaced(orderId, msg.sender, Side.BUY, price, amountBase);

        // 可选：挂单后立刻撮合（像交易所“post-only”不是这样；这里默认允许立即撮合）
        _tryMatch();
    }

    // 4) 限价卖：挂单卖 amountBase，价格 price
    function limitSell(uint256 price, uint256 amountBase) external returns (uint256 orderId) {
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();

        // 锁定 base
        _safeTransferFrom(address(baseToken), msg.sender, address(this), amountBase);

        orderId = _createOrder(Side.SELL, price, amountBase);
        _insertAsk(orderId);

        emit LimitOrderPlaced(orderId, msg.sender, Side.SELL, price, amountBase);

        _tryMatch();
    }

    // 5) 撤单：退回未成交部分（买单退 quote，卖单退 base）
    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (!o.active) revert NotActive();
        if (o.trader != msg.sender) revert NotOwner();

        o.active = false;

        uint256 remainingBase = o.amountBase - o.filledBase;
        if (remainingBase > 0) {
            if (o.side == Side.BUY) {
                uint256 refundQuote = (remainingBase * o.price) / PRICE_SCALE;
                if (refundQuote > 0) _safeTransfer(address(quoteToken), msg.sender, refundQuote);
            } else {
                _safeTransfer(address(baseToken), msg.sender, remainingBase);
            }
        }

        // 从数组里移除（O(n)）
        if (o.side == Side.BUY) {
            _removeIdFromArray(bidIds, orderId);
        } else {
            _removeIdFromArray(askIds, orderId);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // 6) 获取当前成交价
    function getLastPrice() external view returns (uint256) {
        return lastTradePrice;
    }

    // 7) 获取订单簿深度：返回 topN 档的聚合深度（价格、剩余量）
    // 返回值：bidPrices, bidSizes, askPrices, askSizes
    function getOrderBookDepth(uint256 topN)
        external
        view
        returns (uint256[] memory, uint256[] memory, uint256[] memory, uint256[] memory)
    {
        if (topN == 0) topN = 10;

        (uint256[] memory bp, uint256[] memory bs) = _aggregateDepth(bidIds, topN);
        (uint256[] memory ap, uint256[] memory asz) = _aggregateDepth(askIds, topN);
        return (bp, bs, ap, asz);
    }

    // -------------------------
    // Internal: order creation / matching
    // -------------------------

    function _createOrder(Side side, uint256 price, uint256 amountBase) internal returns (uint256 id) {
        id = nextOrderId++;
        orders[id] = Order({
            id: id,
            trader: msg.sender,
            side: side,
            price: price,
            amountBase: amountBase,
            filledBase: 0,
            timestamp: block.timestamp,
            active: true
        });
    }

    // 简化撮合：只要 bestBid >= bestAsk 就持续撮合
    function _tryMatch() internal {
        while (bidIds.length > 0 && askIds.length > 0) {
            Order storage bestBid = orders[bidIds[0]];
            Order storage bestAsk = orders[askIds[0]];

            if (!bestBid.active) { _deactivateAndRemoveBidAt(0); continue; }
            if (!bestAsk.active) { _deactivateAndRemoveAskAt(0); continue; }

            if (bestBid.price < bestAsk.price) break;

            uint256 bidRemain = bestBid.amountBase - bestBid.filledBase;
            uint256 askRemain = bestAsk.amountBase - bestAsk.filledBase;

            if (bidRemain == 0) { _deactivateAndRemoveBidAt(0); continue; }
            if (askRemain == 0) { _deactivateAndRemoveAskAt(0); continue; }

            uint256 tradeBase = bidRemain < askRemain ? bidRemain : askRemain;

            // 价格选择：常见做法是用 maker 价（这里让 ask 作为 maker 时用 ask 价；bid 作为 maker 时用 bid 价）
            // 为了 demo 简洁：用 bestAsk 价（更像“taker 吃 ask”）
            uint256 tradePrice = bestAsk.price;
            uint256 tradeQuote = (tradeBase * tradePrice) / PRICE_SCALE;
            // 这里选的是 bestAsk 价（也就是“吃卖盘的价格”）。

            // 资金结算：
            // - 买单锁 quote，卖单锁 base
            // - 买家得到 base，卖家得到 quote
            bestBid.filledBase += tradeBase;
            bestAsk.filledBase += tradeBase;

            _safeTransfer(address(baseToken), bestBid.trader, tradeBase);
            _safeTransfer(address(quoteToken), bestAsk.trader, tradeQuote);

            // 买单可能因为 tradePrice < bid.price 产生“锁多了”的quote，需要在完全成交/撤单时退
            // 这里：当买单完全成交时，退回多锁的部分（差价）
            if (bestBid.filledBase == bestBid.amountBase) {
                uint256 lockedAtBid = (bestBid.amountBase * bestBid.price) / PRICE_SCALE;
                uint256 spentAtAsk = (bestBid.amountBase * tradePrice) / PRICE_SCALE;
                if (lockedAtBid > spentAtAsk) {
                    _safeTransfer(address(quoteToken), bestBid.trader, lockedAtBid - spentAtAsk);
                }
            }

            lastTradePrice = tradePrice;

            emit Trade(bestAsk.id, bestAsk.trader, bestBid.trader, Side.BUY, tradePrice, tradeBase);

            if (bestBid.filledBase == bestBid.amountBase) _deactivateAndRemoveBidAt(0);
            if (bestAsk.filledBase == bestAsk.amountBase) _deactivateAndRemoveAskAt(0);
        }
    }

    // -------------------------
    // Order book insertion (O(n))
    // -------------------------

    function _insertBid(uint256 orderId) internal {
        Order storage o = orders[orderId];
        uint256 n = bidIds.length;
        bidIds.push(orderId);

        // 插入排序：price desc, timestamp asc
        uint256 i = n;
        while (i > 0) {
            Order storage prev = orders[bidIds[i - 1]];
            bool shouldSwap = (o.price > prev.price) || (o.price == prev.price && o.timestamp < prev.timestamp);
            if (!shouldSwap) break;
            bidIds[i] = bidIds[i - 1];
            i--;
        }
        bidIds[i] = orderId;
    }

    function _insertAsk(uint256 orderId) internal {
        Order storage o = orders[orderId];
        uint256 n = askIds.length;
        askIds.push(orderId);

        // 插入排序：price asc, timestamp asc
        uint256 i = n;
        while (i > 0) {
            Order storage prev = orders[askIds[i - 1]];
            bool shouldSwap = (o.price < prev.price) || (o.price == prev.price && o.timestamp < prev.timestamp);
            if (!shouldSwap) break;
            askIds[i] = askIds[i - 1];
            i--;
        }
        askIds[i] = orderId;
    }

    function _deactivateAndRemoveBidAt(uint256 idx) internal {
        uint256 oid = bidIds[idx];
        orders[oid].active = false;
        // _removeAt(bidIds, idx);
        // _removeIdFromArray(bidIds, idx);
        _removeIdFromArray(bidIds, oid); // ✅
    }

    // 把卖单（ask）在订单簿中“标记为失效（inactive）”，并从卖单数组中移除。
    function _deactivateAndRemoveAskAt(uint256 idx) internal {
        uint256 oid = askIds[idx];
        orders[oid].active = false;
        // _removeAt(askIds, idx);
        // _removeIdFromArray(askIds, idx);
        _removeIdFromArray(askIds, oid); // ✅
    }

    function _removeAt(uint256[] storage arr, uint256 idx) internal {
        uint256 last = arr.length - 1;
        if (idx != last) arr[idx] = arr[last];
        arr.pop();

        // 注意：这里会破坏排序；为了 demo 简洁，我们只在 idx=0 的时候用，
        // 但 swap-pop 会打乱顺序，所以我们改用 O(n) 左移保持顺序：
        // 由于上面写了 swap-pop，这里做一个“保序删除”更正确
        // ——为避免重复 pop，我们直接用保序版本替换上面的 swap-pop。

        // 你要的是正确排序，所以用下面这个保序版本替换：
    }

    function _removeIdFromArray(uint256[] storage arr, uint256 id) internal {
        uint256 n = arr.length;
        for (uint256 i = 0; i < n; i++) {
            if (arr[i] == id) {
                for (uint256 j = i; j + 1 < n; j++) {
                    arr[j] = arr[j + 1];
                }
                arr.pop();
                return;
            }
        }
    }

    // 深度聚合：把相同价位的 remainingBase 累加，取 topN 档
    function _aggregateDepth(uint256[] storage ids, uint256 topN)
        internal
        view
        returns (uint256[] memory prices, uint256[] memory sizes)
    {
        prices = new uint256[](topN);
        sizes  = new uint256[](topN);

        uint256 level = 0;
        uint256 i = 0;

        while (i < ids.length && level < topN) {
            Order storage o = orders[ids[i]];
            if (!o.active) { i++; continue; }

            uint256 rem = o.amountBase - o.filledBase;
            if (rem == 0) { i++; continue; }

            uint256 p = o.price;
            uint256 sum = 0;

            // 聚合相同价位
            uint256 k = i;
            while (k < ids.length) {
                Order storage ok = orders[ids[k]];
                if (!ok.active) { k++; continue; }
                if (ok.price != p) break;
                uint256 remk = ok.amountBase - ok.filledBase;
                if (remk > 0) sum += remk;
                k++;
            }

            prices[level] = p;
            sizes[level]  = sum;
            level++;

            i = k;
        }

        // 如果不足 topN，尾部默认 0
    }

    // -------------------------
    // Safe ERC20 transfers
    // -------------------------

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
    // revert 的意思是：立刻终止当前交易，并把本次执行中对链上状态的所有修改全部撤销。

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
    // transferFrom 用来“从用户那里把钱拉进合约”
    // transfer 用来“把合约自己托管的钱打给别人”
    // msg.sender 是“当前这一步函数调用的直接发起者地址”
}
