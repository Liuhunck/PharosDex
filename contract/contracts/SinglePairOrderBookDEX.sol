// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract SinglePairOrderBookDEX {
    IERC20 public immutable baseToken;  // DOGE
    IERC20 public immutable quoteToken; // USDT

    // decimals cache (immutable => 更省 gas)
    uint8 public immutable baseDecimals;
    uint8 public immutable quoteDecimals;

    uint256 public constant PRICE_SCALE = 1e18; // price = (quote per 1 base) * 1e18

    enum Side { BUY, SELL }

    struct Order {
        uint256 id;
        address trader;
        Side side;
        uint256 price;      // scaled by 1e18
        uint256 amountBase; // total base amount (base smallest units)
        uint256 filledBase; // filled base amount (base smallest units)
        uint256 timestamp;
        bool active;
    }

    uint256 public nextOrderId = 1;
    uint256 public lastTradePrice; // scaled by 1e18

    mapping(uint256 => Order) public orders;

    uint256[] public bidIds; // high -> low
    uint256[] public askIds; // low  -> high

    event LimitOrderPlaced(uint256 indexed orderId, address indexed trader, Side side, uint256 price, uint256 amountBase);
    event OrderCancelled(uint256 indexed orderId, address indexed trader);
    event Trade(uint256 indexed makerOrderId, address indexed maker, address indexed taker, Side takerSide, uint256 price, uint256 amountBase);

    error InvalidAmount();
    error InvalidPrice();
    error NotOwner();
    error NotActive();
    error InsufficientLiquidity();
    error TransferFailed();

    constructor(address _base, address _quote) {
        baseToken = IERC20(_base);
        quoteToken = IERC20(_quote);

        // Route B: read decimals from token contracts
        baseDecimals = IERC20Metadata(_base).decimals();
        quoteDecimals = IERC20Metadata(_quote).decimals();
    }

    // -------------------------
    // Decimals-aware conversion helpers
    // -------------------------

    function _pow10(uint8 d) internal pure returns (uint256) {
        // 10**d, d<=18 in most ERC20; even if higher, may overflow - but typical tokens are safe.
        return 10 ** uint256(d);
    }

    /// @dev Given base amount in base smallest units and price (1e18),
    ///      return required quote amount in quote smallest units.
    ///      quote = base(human) * price(human quote/base)
    function _quoteForBase(uint256 baseAmount, uint256 price) internal view returns (uint256) {
        // baseHuman = baseAmount / 10^baseDecimals
        // quoteHuman = baseHuman * price / 1e18
        // quoteSmallest = quoteHuman * 10^quoteDecimals
        // => quoteSmallest = baseAmount * price * 10^quoteDecimals / (1e18 * 10^baseDecimals)
        return (baseAmount * price * _pow10(quoteDecimals)) / (PRICE_SCALE * _pow10(baseDecimals));
    }

    /// @dev Given quote amount in quote smallest units and price (1e18),
    ///      return how much base in base smallest units can be bought.
    function _baseForQuote(uint256 quoteAmount, uint256 price) internal view returns (uint256) {
        // quoteHuman = quoteAmount / 10^quoteDecimals
        // baseHuman  = quoteHuman / (price/1e18) = quoteHuman * 1e18 / price
        // baseSmallest = baseHuman * 10^baseDecimals
        // => baseSmallest = quoteAmount * 1e18 * 10^baseDecimals / (price * 10^quoteDecimals)
        return (quoteAmount * PRICE_SCALE * _pow10(baseDecimals)) / (price * _pow10(quoteDecimals));
    }

    // -------------------------
    // 7 external interfaces
    // -------------------------

    // 1) 市价买：最多花 maxQuoteIn(quote 最小单位) 去买 base
    function marketBuy(uint256 maxQuoteIn) external {
        if (maxQuoteIn == 0) revert InvalidAmount();

        _safeTransferFrom(address(quoteToken), msg.sender, address(this), maxQuoteIn);

        uint256 remainingQuote = maxQuoteIn;

        uint256 i = 0;
        while (i < askIds.length && remainingQuote > 0) {
            uint256 oid = askIds[i];
            Order storage ask = orders[oid];
            if (!ask.active) { i++; continue; }

            uint256 remainingBaseInOrder = ask.amountBase - ask.filledBase;
            if (remainingBaseInOrder == 0) { _deactivateAndRemoveAskAt(i); continue; }

            // decimals-aware: remainingQuote 能买到多少 base
            uint256 buyableBase = _baseForQuote(remainingQuote, ask.price);
            if (buyableBase == 0) break;

            uint256 tradeBase = buyableBase < remainingBaseInOrder ? buyableBase : remainingBaseInOrder;
            uint256 tradeQuote = _quoteForBase(tradeBase, ask.price);

            ask.filledBase += tradeBase;
            remainingQuote -= tradeQuote;

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

        if (remainingQuote > 0) {
            _safeTransfer(address(quoteToken), msg.sender, remainingQuote);
        }
    }

    // 2) 市价卖：卖 amountBase(base 最小单位)，换 quote
    function marketSell(uint256 amountBase) external {
        if (amountBase == 0) revert InvalidAmount();

        _safeTransferFrom(address(baseToken), msg.sender, address(this), amountBase);

        uint256 remainingBase = amountBase;

        uint256 i = 0;
        while (i < bidIds.length && remainingBase > 0) {
            uint256 oid = bidIds[i];
            Order storage bid = orders[oid];
            if (!bid.active) { i++; continue; }

            uint256 remainingBaseInOrder = bid.amountBase - bid.filledBase;
            if (remainingBaseInOrder == 0) { _deactivateAndRemoveBidAt(i); continue; }

            uint256 tradeBase = remainingBase < remainingBaseInOrder ? remainingBase : remainingBaseInOrder;
            uint256 tradeQuote = _quoteForBase(tradeBase, bid.price);

            bid.filledBase += tradeBase;
            remainingBase -= tradeBase;

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

        if (remainingBase > 0) {
            _safeTransfer(address(baseToken), msg.sender, remainingBase);
        }
    }

    // 3) 限价买：挂买 amountBase(base最小单位)，价格 price(1e18 标度)
    function limitBuy(uint256 price, uint256 amountBase) external returns (uint256 orderId) {
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();

        // decimals-aware lock
        uint256 quoteToLock = _quoteForBase(amountBase, price);
        if (quoteToLock == 0) revert InvalidAmount();

        _safeTransferFrom(address(quoteToken), msg.sender, address(this), quoteToLock);

        orderId = _createOrder(Side.BUY, price, amountBase);
        _insertBid(orderId);

        emit LimitOrderPlaced(orderId, msg.sender, Side.BUY, price, amountBase);

        _tryMatch();
    }

    // 4) 限价卖：锁 base（不涉及 quote decimals）
    function limitSell(uint256 price, uint256 amountBase) external returns (uint256 orderId) {
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();

        _safeTransferFrom(address(baseToken), msg.sender, address(this), amountBase);

        orderId = _createOrder(Side.SELL, price, amountBase);
        _insertAsk(orderId);

        emit LimitOrderPlaced(orderId, msg.sender, Side.SELL, price, amountBase);

        _tryMatch();
    }

    // 5) 撤单：退回未成交部分
    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (!o.active) revert NotActive();
        if (o.trader != msg.sender) revert NotOwner();

        o.active = false;

        uint256 remainingBase = o.amountBase - o.filledBase;
        if (remainingBase > 0) {
            if (o.side == Side.BUY) {
                uint256 refundQuote = _quoteForBase(remainingBase, o.price);
                if (refundQuote > 0) _safeTransfer(address(quoteToken), msg.sender, refundQuote);
            } else {
                _safeTransfer(address(baseToken), msg.sender, remainingBase);
            }
        }

        if (o.side == Side.BUY) {
            _removeIdFromArray(bidIds, orderId);
        } else {
            _removeIdFromArray(askIds, orderId);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    function getLastPrice() external view returns (uint256) {
        return lastTradePrice;
    }

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

            // demo: use bestAsk price
            uint256 tradePrice = bestAsk.price;
            uint256 tradeQuote = _quoteForBase(tradeBase, tradePrice);

            bestBid.filledBase += tradeBase;
            bestAsk.filledBase += tradeBase;

            _safeTransfer(address(baseToken), bestBid.trader, tradeBase);
            _safeTransfer(address(quoteToken), bestAsk.trader, tradeQuote);

            // refund difference for fully filled bid (locked at bid.price but spent at tradePrice)
            if (bestBid.filledBase == bestBid.amountBase) {
                uint256 lockedAtBid = _quoteForBase(bestBid.amountBase, bestBid.price);
                uint256 spentAtAsk = _quoteForBase(bestBid.amountBase, tradePrice);
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
        _removeIdFromArray(bidIds, oid);
    }

    function _deactivateAndRemoveAskAt(uint256 idx) internal {
        uint256 oid = askIds[idx];
        orders[oid].active = false;
        _removeIdFromArray(askIds, oid);
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
    }

    // -------------------------
    // Safe ERC20 transfers
    // -------------------------

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
