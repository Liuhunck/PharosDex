// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Single-pair orderbook DEX with internal balances (deposit/withdraw)
///         Designed to reduce ERC20 transfer calls during trading and improve parallelism.
contract SinglePairOrderBookDEXVault {
    using Math for uint256;

    IERC20 public immutable baseToken; // e.g., DOGE
    IERC20 public immutable quoteToken; // e.g., USDT

    uint8 public immutable baseDecimals;
    uint8 public immutable quoteDecimals;

    uint256 public constant PRICE_SCALE = 1e18; // price = (quote per 1 base) * 1e18

    enum Side {
        BUY,
        SELL
    }

    struct Order {
        uint256 id; // hash-based id
        address trader;
        Side side;
        uint256 price; // scaled by 1e18
        uint256 amountBase; // total base amount (base smallest units)
        uint256 filledBase; // filled base amount (base smallest units)
        uint256 timestamp;
        bool active;
    }

    struct OrderView {
        uint256 id;
        Side side;
        uint256 price;
        uint256 amountBase;
        uint256 filledBase;
        uint256 timestamp;
        bool active;
    }

    // -------------------------
    // Internal balances
    // -------------------------

    mapping(address => uint256) public baseBalance; // base smallest units
    mapping(address => uint256) public quoteBalance; // quote smallest units

    event Deposited(
        address indexed trader,
        address indexed token,
        uint256 amount
    );
    event Withdrawn(
        address indexed trader,
        address indexed token,
        uint256 amount
    );

    // -------------------------
    // Order book storage
    // -------------------------

    mapping(uint256 => Order) public orders;

    // For UI depth aggregation: store active order ids.
    // Keep same semantics as original: bids high->low, asks low->high.
    uint256[] public bidIds;
    uint256[] public askIds;

    uint256 public lastTradePrice; // scaled by 1e18

    // Parallel-friendly per-user nonce to derive orderId; avoids global counter hot-spot.
    mapping(address => uint64) public userOrderNonce;

    event LimitOrderPlaced(
        uint256 indexed orderId,
        address indexed trader,
        Side side,
        uint256 price,
        uint256 amountBase
    );
    event OrderCancelled(uint256 indexed orderId, address indexed trader);
    event Trade(
        uint256 indexed makerOrderId,
        address indexed maker,
        address indexed taker,
        Side takerSide,
        uint256 price,
        uint256 amountBase
    );

    error InvalidAmount();
    error InvalidPrice();
    error NotOwner();
    error NotActive();
    error InsufficientBalance();
    error TransferFailed();

    constructor(address _base, address _quote) {
        baseToken = IERC20(_base);
        quoteToken = IERC20(_quote);

        baseDecimals = IERC20Metadata(_base).decimals();
        quoteDecimals = IERC20Metadata(_quote).decimals();
    }

    // -------------------------
    // View helpers (unchanged interface shape)
    // -------------------------

    function getMyOpenOrders() external view returns (OrderView[] memory) {
        return getOpenOrdersOf(msg.sender);
    }

    function getOpenOrdersOf(
        address trader
    ) public view returns (OrderView[] memory) {
        uint256 count = 0;

        for (uint256 i = 0; i < bidIds.length; i++) {
            Order storage o = orders[bidIds[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase)
                count++;
        }
        for (uint256 i = 0; i < askIds.length; i++) {
            Order storage o = orders[askIds[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase)
                count++;
        }

        OrderView[] memory res = new OrderView[](count);
        uint256 k = 0;

        for (uint256 i = 0; i < bidIds.length; i++) {
            Order storage o = orders[bidIds[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase) {
                res[k++] = OrderView({
                    id: o.id,
                    side: o.side,
                    price: o.price,
                    amountBase: o.amountBase,
                    filledBase: o.filledBase,
                    timestamp: o.timestamp,
                    active: o.active
                });
            }
        }

        for (uint256 i = 0; i < askIds.length; i++) {
            Order storage o = orders[askIds[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase) {
                res[k++] = OrderView({
                    id: o.id,
                    side: o.side,
                    price: o.price,
                    amountBase: o.amountBase,
                    filledBase: o.filledBase,
                    timestamp: o.timestamp,
                    active: o.active
                });
            }
        }

        return res;
    }

    function getLastPrice() external view returns (uint256) {
        return lastTradePrice;
    }

    function getOrderBookDepth(
        uint256 topN
    )
        external
        view
        returns (
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        if (topN == 0) topN = 10;
        (uint256[] memory bp, uint256[] memory bs) = _aggregateDepth(
            bidIds,
            topN
        );
        (uint256[] memory ap, uint256[] memory asz) = _aggregateDepth(
            askIds,
            topN
        );
        return (bp, bs, ap, asz);
    }

    // -------------------------
    // Deposit / Withdraw (new)
    // -------------------------

    function depositBase(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _safeTransferFrom(
            address(baseToken),
            msg.sender,
            address(this),
            amount
        );
        baseBalance[msg.sender] += amount;
        emit Deposited(msg.sender, address(baseToken), amount);
    }

    function withdrawBase(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        if (baseBalance[msg.sender] < amount) revert InsufficientBalance();
        baseBalance[msg.sender] -= amount;
        _safeTransfer(address(baseToken), msg.sender, amount);
        emit Withdrawn(msg.sender, address(baseToken), amount);
    }

    function depositQuote(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        _safeTransferFrom(
            address(quoteToken),
            msg.sender,
            address(this),
            amount
        );
        quoteBalance[msg.sender] += amount;
        emit Deposited(msg.sender, address(quoteToken), amount);
    }

    function withdrawQuote(uint256 amount) external {
        if (amount == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < amount) revert InsufficientBalance();
        quoteBalance[msg.sender] -= amount;
        _safeTransfer(address(quoteToken), msg.sender, amount);
        emit Withdrawn(msg.sender, address(quoteToken), amount);
    }

    // -------------------------
    // Trading interfaces (keep signatures)
    // -------------------------

    // 1) 市价买：最多花 maxQuoteIn(quote 最小单位) 去买 base
    //    In vault model: spend from quoteBalance and credit baseBalance
    function marketBuy(uint256 maxQuoteIn) external {
        if (maxQuoteIn == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < maxQuoteIn) revert InsufficientBalance();

        uint256 remainingQuote = maxQuoteIn;

        uint256 i = 0;
        while (i < askIds.length && remainingQuote > 0) {
            uint256 oid = askIds[i];
            Order storage ask = orders[oid];
            if (!ask.active) {
                i++;
                continue;
            }

            uint256 remainingBaseInOrder = ask.amountBase - ask.filledBase;
            if (remainingBaseInOrder == 0) {
                _deactivateAndRemoveAskAt(i);
                continue;
            }

            uint256 buyableBase = _baseForQuote(remainingQuote, ask.price);
            if (buyableBase == 0) break;

            uint256 tradeBase = buyableBase < remainingBaseInOrder
                ? buyableBase
                : remainingBaseInOrder;
            uint256 tradeQuote = _quoteForBase(tradeBase, ask.price);
            if (tradeQuote == 0) break;

            // accounting
            ask.filledBase += tradeBase;
            remainingQuote -= tradeQuote;

            // taker spends quote, receives base
            quoteBalance[msg.sender] -= tradeQuote;
            baseBalance[msg.sender] += tradeBase;

            // maker receives quote (base was already locked at order creation)
            quoteBalance[ask.trader] += tradeQuote;

            lastTradePrice = ask.price;
            emit Trade(
                ask.id,
                ask.trader,
                msg.sender,
                Side.BUY,
                ask.price,
                tradeBase
            );

            if (ask.filledBase == ask.amountBase) {
                _deactivateAndRemoveAskAt(i);
            } else {
                i++;
            }
        }

        // no ERC20 transfer here; unused quote stays in balance
    }

    // 2) 市价卖：卖 amountBase(base 最小单位)，换 quote
    function marketSell(uint256 amountBase) external {
        if (amountBase == 0) revert InvalidAmount();
        if (baseBalance[msg.sender] < amountBase) revert InsufficientBalance();

        uint256 remainingBase = amountBase;

        uint256 i = 0;
        while (i < bidIds.length && remainingBase > 0) {
            uint256 oid = bidIds[i];
            Order storage bid = orders[oid];
            if (!bid.active) {
                i++;
                continue;
            }

            uint256 remainingBaseInOrder = bid.amountBase - bid.filledBase;
            if (remainingBaseInOrder == 0) {
                _deactivateAndRemoveBidAt(i);
                continue;
            }

            uint256 tradeBase = remainingBase < remainingBaseInOrder
                ? remainingBase
                : remainingBaseInOrder;
            uint256 tradeQuote = _quoteForBase(tradeBase, bid.price);
            if (tradeQuote == 0) break;

            bid.filledBase += tradeBase;
            remainingBase -= tradeBase;

            // taker gives base, receives quote
            baseBalance[msg.sender] -= tradeBase;
            quoteBalance[msg.sender] += tradeQuote;

            // maker receives base (quote was already locked at order creation)
            baseBalance[bid.trader] += tradeBase;

            lastTradePrice = bid.price;
            emit Trade(
                bid.id,
                bid.trader,
                msg.sender,
                Side.SELL,
                bid.price,
                tradeBase
            );

            if (bid.filledBase == bid.amountBase) {
                _deactivateAndRemoveBidAt(i);
            } else {
                i++;
            }
        }

        // remainingBase stays as baseBalance (not auto-refund via transfer)
    }

    // 3) 限价买：挂买 amountBase(base最小单位)，价格 price(1e18 标度)
    function limitBuy(
        uint256 price,
        uint256 amountBase
    ) external returns (uint256 orderId) {
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();

        uint256 quoteToLock = _quoteForBase(amountBase, price);
        if (quoteToLock == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < quoteToLock)
            revert InsufficientBalance();

        // lock funds in vault (deduct from available balance)
        quoteBalance[msg.sender] -= quoteToLock;

        orderId = _createOrder(Side.BUY, price, amountBase);
        _insertBid(orderId);

        emit LimitOrderPlaced(orderId, msg.sender, Side.BUY, price, amountBase);
        _tryMatch();
    }

    // 4) 限价卖：锁 base
    function limitSell(
        uint256 price,
        uint256 amountBase
    ) external returns (uint256 orderId) {
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();
        if (baseBalance[msg.sender] < amountBase) revert InsufficientBalance();

        baseBalance[msg.sender] -= amountBase;

        orderId = _createOrder(Side.SELL, price, amountBase);
        _insertAsk(orderId);

        emit LimitOrderPlaced(
            orderId,
            msg.sender,
            Side.SELL,
            price,
            amountBase
        );
        _tryMatch();
    }

    // 5) 撤单：退回未成交部分（返到 vault 余额）
    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (!o.active) revert NotActive();
        if (o.trader != msg.sender) revert NotOwner();

        o.active = false;

        uint256 remainingBase = o.amountBase - o.filledBase;
        if (remainingBase > 0) {
            if (o.side == Side.BUY) {
                uint256 refundQuote = _quoteForBase(remainingBase, o.price);
                if (refundQuote > 0) quoteBalance[msg.sender] += refundQuote;
            } else {
                baseBalance[msg.sender] += remainingBase;
            }
        }

        if (o.side == Side.BUY) {
            _removeIdFromArray(bidIds, orderId);
        } else {
            _removeIdFromArray(askIds, orderId);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // -------------------------
    // Matching (internal)
    // -------------------------

    function _createOrder(
        Side side,
        uint256 price,
        uint256 amountBase
    ) internal returns (uint256 id) {
        // hash-based id to reduce contention: (chainid, this, trader, nonce, side, price, amount)
        uint64 nonce = userOrderNonce[msg.sender]++;
        id = uint256(
            keccak256(
                abi.encodePacked(
                    block.chainid,
                    address(this),
                    msg.sender,
                    nonce,
                    side,
                    price,
                    amountBase
                )
            )
        );

        // Extremely unlikely collision; still protect from overwriting existing active order.
        if (orders[id].trader != address(0)) {
            // if collision happens, add timestamp salt
            id = uint256(keccak256(abi.encodePacked(id, block.timestamp)));
        }

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

            if (!bestBid.active) {
                _deactivateAndRemoveBidAt(0);
                continue;
            }
            if (!bestAsk.active) {
                _deactivateAndRemoveAskAt(0);
                continue;
            }

            if (bestBid.price < bestAsk.price) break;

            uint256 bidRemain = bestBid.amountBase - bestBid.filledBase;
            uint256 askRemain = bestAsk.amountBase - bestAsk.filledBase;

            if (bidRemain == 0) {
                _deactivateAndRemoveBidAt(0);
                continue;
            }
            if (askRemain == 0) {
                _deactivateAndRemoveAskAt(0);
                continue;
            }

            uint256 tradeBase = bidRemain < askRemain ? bidRemain : askRemain;

            // demo rule: take ask price
            uint256 tradePrice = bestAsk.price;
            uint256 tradeQuote = _quoteForBase(tradeBase, tradePrice);
            if (tradeQuote == 0) break;

            // update fills
            bestBid.filledBase += tradeBase;
            bestAsk.filledBase += tradeBase;

            // vault settlement:
            // - Bid maker receives base
            // - Ask maker receives quote
            baseBalance[bestBid.trader] += tradeBase;
            quoteBalance[bestAsk.trader] += tradeQuote;

            // refund bid maker if bid was locked at bid.price but executed at lower tradePrice
            if (bestBid.filledBase == bestBid.amountBase) {
                uint256 lockedAtBid = _quoteForBase(
                    bestBid.amountBase,
                    bestBid.price
                );
                uint256 spentAtAsk = _quoteForBase(
                    bestBid.amountBase,
                    tradePrice
                );
                if (lockedAtBid > spentAtAsk) {
                    quoteBalance[bestBid.trader] += (lockedAtBid - spentAtAsk);
                }
            }

            lastTradePrice = tradePrice;
            emit Trade(
                bestAsk.id,
                bestAsk.trader,
                bestBid.trader,
                Side.BUY,
                tradePrice,
                tradeBase
            );

            if (bestBid.filledBase == bestBid.amountBase)
                _deactivateAndRemoveBidAt(0);
            if (bestAsk.filledBase == bestAsk.amountBase)
                _deactivateAndRemoveAskAt(0);
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
            bool shouldSwap = (o.price > prev.price) ||
                (o.price == prev.price && o.timestamp < prev.timestamp);
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
            bool shouldSwap = (o.price < prev.price) ||
                (o.price == prev.price && o.timestamp < prev.timestamp);
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
        // O(n) shift; kept to preserve behavior. Parallelism improvements focus on removing global counter.
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

    function _aggregateDepth(
        uint256[] storage ids,
        uint256 topN
    ) internal view returns (uint256[] memory prices, uint256[] memory sizes) {
        prices = new uint256[](topN);
        sizes = new uint256[](topN);

        uint256 level = 0;
        uint256 i = 0;

        while (i < ids.length && level < topN) {
            Order storage o = orders[ids[i]];
            if (!o.active) {
                i++;
                continue;
            }

            uint256 rem = o.amountBase - o.filledBase;
            if (rem == 0) {
                i++;
                continue;
            }

            uint256 p = o.price;
            uint256 sum = 0;

            uint256 k = i;
            while (k < ids.length) {
                Order storage ok = orders[ids[k]];
                if (!ok.active) {
                    k++;
                    continue;
                }
                if (ok.price != p) break;
                uint256 remk = ok.amountBase - ok.filledBase;
                if (remk > 0) sum += remk;
                k++;
            }

            prices[level] = p;
            sizes[level] = sum;
            level++;
            i = k;
        }
    }

    // -------------------------
    // Decimals-aware conversion helpers
    // -------------------------

    function _pow10(uint8 d) internal pure returns (uint256) {
        return 10 ** uint256(d);
    }

    function _quoteForBase(
        uint256 baseAmount,
        uint256 price
    ) internal view returns (uint256) {
        // Use mulDiv for better precision & overflow safety.
        // quoteSmallest = baseAmount * price * 10^quoteDecimals / (1e18 * 10^baseDecimals)
        uint256 numerator = baseAmount.mulDiv(price, 1); // baseAmount * price
        numerator = numerator.mulDiv(_pow10(quoteDecimals), 1);
        uint256 denom = PRICE_SCALE * _pow10(baseDecimals);
        return numerator / denom;
    }

    function _baseForQuote(
        uint256 quoteAmount,
        uint256 price
    ) internal view returns (uint256) {
        // baseSmallest = quoteAmount * 1e18 * 10^baseDecimals / (price * 10^quoteDecimals)
        uint256 numerator = quoteAmount.mulDiv(PRICE_SCALE, 1);
        numerator = numerator.mulDiv(_pow10(baseDecimals), 1);
        uint256 denom = price * _pow10(quoteDecimals);
        return numerator / denom;
    }

    // -------------------------
    // Safe ERC20 transfers
    // -------------------------

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20.transferFrom.selector,
                from,
                to,
                amount
            )
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }
}
