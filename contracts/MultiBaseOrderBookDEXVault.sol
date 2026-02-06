// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Multi-base single-quote orderbook DEX with internal balances (deposit/withdraw)
///         - Supports many base tokens against one quote token
///         - Keeps the old no-base-param interfaces as wrappers for `defaultBaseToken`
///         - Uses hash-based order ids (per-user nonce) to reduce global write contention
contract MultiBaseOrderBookDEXVault is Ownable {
    using Math for uint256;

    IERC20 public immutable quoteToken;
    uint8 public immutable quoteDecimals;

    uint256 public constant PRICE_SCALE = 1e18; // price = (quote per 1 base) * 1e18

    enum Side {
        BUY,
        SELL
    }

    struct Order {
        uint256 id;
        address trader;
        address baseToken;
        Side side;
        uint256 price; // 1e18
        uint256 amountBase; // base smallest units
        uint256 filledBase; // base smallest units
        uint256 timestamp;
        bool active;
    }

    /// @dev Extended view for multi-base queries.
    struct OrderViewMulti {
        uint256 id;
        address baseToken;
        Side side;
        uint256 price;
        uint256 amountBase;
        uint256 filledBase;
        uint256 remainingBase;
        uint256 timestamp;
        bool active;
    }

    // -------------------------
    // Support lists / decimals cache
    // -------------------------

    mapping(address => bool) public isBaseSupported;
    mapping(address => uint8) public baseDecimals;

    address[] private supportedBases;

    event BaseTokenSupported(address indexed baseToken, uint8 decimals);

    error UnsupportedBaseToken();

    // -------------------------
    // Internal balances
    // -------------------------

    mapping(address => uint256) public quoteBalance; // quote smallest units
    mapping(address => mapping(address => uint256)) public baseBalance; // baseBalance[trader][baseToken]

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
    // Order books / ids
    // -------------------------

    mapping(uint256 => Order) public orders;

    // order id arrays per base
    mapping(address => uint256[]) public bidIds; // high -> low
    mapping(address => uint256[]) public askIds; // low  -> high

    uint256 public lastTradePrice; // 1e18, last across all bases

    // per-user per-base nonce to derive orderId
    mapping(address => mapping(address => uint64)) public userOrderNonce;

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

    constructor(address _quote) Ownable(msg.sender) {
        quoteToken = IERC20(_quote);
        quoteDecimals = IERC20Metadata(_quote).decimals();
    }

    // -------------------------
    // Admin: manage supported bases
    // -------------------------

    function supportBaseToken(address base) external onlyOwner {
        _supportBaseToken(base);
    }

    /// @notice Enumerate all supported base tokens (for frontend discovery).
    function getSupportedBases() external view returns (address[] memory) {
        return supportedBases;
    }

    function supportedBasesLength() external view returns (uint256) {
        return supportedBases.length;
    }

    function _supportBaseToken(address base) internal {
        if (base == address(0)) revert UnsupportedBaseToken();
        if (isBaseSupported[base]) return;
        uint8 d = IERC20Metadata(base).decimals();
        isBaseSupported[base] = true;
        baseDecimals[base] = d;
        supportedBases.push(base);
        emit BaseTokenSupported(base, d);
    }

    function _requireSupportedBase(address base) internal view {
        if (!isBaseSupported[base]) revert UnsupportedBaseToken();
    }

    // -------------------------
    // Deposit / Withdraw
    // -------------------------

    // Multi-base versions
    function depositBaseFor(address base, uint256 amount) public {
        _requireSupportedBase(base);
        if (amount == 0) revert InvalidAmount();
        _safeTransferFrom(base, msg.sender, address(this), amount);
        baseBalance[msg.sender][base] += amount;
        emit Deposited(msg.sender, base, amount);
    }

    function withdrawBaseFor(address base, uint256 amount) public {
        _requireSupportedBase(base);
        if (amount == 0) revert InvalidAmount();
        if (baseBalance[msg.sender][base] < amount)
            revert InsufficientBalance();
        baseBalance[msg.sender][base] -= amount;
        _safeTransfer(base, msg.sender, amount);
        emit Withdrawn(msg.sender, base, amount);
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

    // Multi-base view helpers
    function getMyOpenOrdersFor(
        address base
    ) external view returns (OrderViewMulti[] memory) {
        return getOpenOrdersOfFor(msg.sender, base);
    }

    function getOpenOrdersOfFor(
        address trader,
        address base
    ) public view returns (OrderViewMulti[] memory) {
        _requireSupportedBase(base);

        uint256[] storage bids = bidIds[base];
        uint256[] storage asks = askIds[base];

        uint256 count = 0;
        for (uint256 i = 0; i < bids.length; i++) {
            Order storage o = orders[bids[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase)
                count++;
        }
        for (uint256 i = 0; i < asks.length; i++) {
            Order storage o = orders[asks[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase)
                count++;
        }

        OrderViewMulti[] memory res = new OrderViewMulti[](count);
        uint256 k = 0;

        for (uint256 i = 0; i < bids.length; i++) {
            Order storage o = orders[bids[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase) {
                uint256 rem = o.amountBase - o.filledBase;
                res[k++] = OrderViewMulti({
                    id: o.id,
                    baseToken: o.baseToken,
                    side: o.side,
                    price: o.price,
                    amountBase: o.amountBase,
                    filledBase: o.filledBase,
                    remainingBase: rem,
                    timestamp: o.timestamp,
                    active: o.active
                });
            }
        }

        for (uint256 i = 0; i < asks.length; i++) {
            Order storage o = orders[asks[i]];
            if (o.active && o.trader == trader && o.filledBase < o.amountBase) {
                uint256 rem = o.amountBase - o.filledBase;
                res[k++] = OrderViewMulti({
                    id: o.id,
                    baseToken: o.baseToken,
                    side: o.side,
                    price: o.price,
                    amountBase: o.amountBase,
                    filledBase: o.filledBase,
                    remainingBase: rem,
                    timestamp: o.timestamp,
                    active: o.active
                });
            }
        }

        return res;
    }

    // -------------------------
    // Price / depth
    // -------------------------

    function getLastPrice() external view returns (uint256) {
        return lastTradePrice;
    }

    function getOrderBookDepthFor(
        address base,
        uint256 topN
    )
        public
        view
        returns (
            uint256[] memory,
            uint256[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        _requireSupportedBase(base);
        if (topN == 0) topN = 10;
        (uint256[] memory bp, uint256[] memory bs) = _aggregateDepth(
            bidIds[base],
            topN
        );
        (uint256[] memory ap, uint256[] memory az) = _aggregateDepth(
            askIds[base],
            topN
        );
        return (bp, bs, ap, az);
    }

    // -------------------------
    // Trading interfaces (multi-base)
    // -------------------------

    function marketBuyFor(address base, uint256 maxQuoteIn) external {
        _marketBuyFor(base, maxQuoteIn);
    }

    function marketSellFor(address base, uint256 amountBase) external {
        _marketSellFor(base, amountBase);
    }

    function limitBuyFor(
        address base,
        uint256 price,
        uint256 amountBase
    ) external returns (uint256 orderId) {
        return _limitBuyFor(base, price, amountBase);
    }

    function limitSellFor(
        address base,
        uint256 price,
        uint256 amountBase
    ) external returns (uint256 orderId) {
        return _limitSellFor(base, price, amountBase);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (!o.active) revert NotActive();
        if (o.trader != msg.sender) revert NotOwner();

        o.active = false;

        uint256 remainingBase = o.amountBase - o.filledBase;
        if (remainingBase > 0) {
            if (o.side == Side.BUY) {
                uint256 refundQuote = _quoteForBase(
                    o.baseToken,
                    remainingBase,
                    o.price
                );
                if (refundQuote > 0) quoteBalance[msg.sender] += refundQuote;
            } else {
                baseBalance[msg.sender][o.baseToken] += remainingBase;
            }
        }

        if (o.side == Side.BUY) {
            _removeIdFromArray(bidIds[o.baseToken], orderId);
        } else {
            _removeIdFromArray(askIds[o.baseToken], orderId);
        }

        emit OrderCancelled(orderId, msg.sender);
    }

    // -------------------------
    // Internal trading implementations
    // -------------------------

    function _marketBuyFor(address base, uint256 maxQuoteIn) internal {
        _requireSupportedBase(base);
        if (maxQuoteIn == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < maxQuoteIn) revert InsufficientBalance();

        uint256[] storage asks = askIds[base];
        uint256 remainingQuote = maxQuoteIn;

        uint256 i = 0;
        while (i < asks.length && remainingQuote > 0) {
            uint256 oid = asks[i];
            Order storage ask = orders[oid];
            if (!ask.active) {
                i++;
                continue;
            }

            uint256 remainingBaseInOrder = ask.amountBase - ask.filledBase;
            if (remainingBaseInOrder == 0) {
                _deactivateAndRemoveAskAt(base, i);
                continue;
            }

            uint256 buyableBase = _baseForQuote(
                base,
                remainingQuote,
                ask.price
            );
            if (buyableBase == 0) break;

            uint256 tradeBase = buyableBase < remainingBaseInOrder
                ? buyableBase
                : remainingBaseInOrder;
            uint256 tradeQuote = _quoteForBase(base, tradeBase, ask.price);
            if (tradeQuote == 0) break;

            ask.filledBase += tradeBase;
            remainingQuote -= tradeQuote;

            quoteBalance[msg.sender] -= tradeQuote;
            baseBalance[msg.sender][base] += tradeBase;

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
                _deactivateAndRemoveAskAt(base, i);
            } else {
                i++;
            }
        }
    }

    function _marketSellFor(address base, uint256 amountBase) internal {
        _requireSupportedBase(base);
        if (amountBase == 0) revert InvalidAmount();
        if (baseBalance[msg.sender][base] < amountBase)
            revert InsufficientBalance();

        uint256[] storage bids = bidIds[base];
        uint256 remainingBase = amountBase;

        uint256 i = 0;
        while (i < bids.length && remainingBase > 0) {
            uint256 oid = bids[i];
            Order storage bid = orders[oid];
            if (!bid.active) {
                i++;
                continue;
            }

            uint256 remainingBaseInOrder = bid.amountBase - bid.filledBase;
            if (remainingBaseInOrder == 0) {
                _deactivateAndRemoveBidAt(base, i);
                continue;
            }

            uint256 tradeBase = remainingBase < remainingBaseInOrder
                ? remainingBase
                : remainingBaseInOrder;
            uint256 tradeQuote = _quoteForBase(base, tradeBase, bid.price);
            if (tradeQuote == 0) break;

            bid.filledBase += tradeBase;
            remainingBase -= tradeBase;

            baseBalance[msg.sender][base] -= tradeBase;
            quoteBalance[msg.sender] += tradeQuote;

            baseBalance[bid.trader][base] += tradeBase;

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
                _deactivateAndRemoveBidAt(base, i);
            } else {
                i++;
            }
        }
    }

    function _limitBuyFor(
        address base,
        uint256 price,
        uint256 amountBase
    ) internal returns (uint256 orderId) {
        _requireSupportedBase(base);
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();

        uint256 quoteToLock = _quoteForBase(base, amountBase, price);
        if (quoteToLock == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < quoteToLock)
            revert InsufficientBalance();

        quoteBalance[msg.sender] -= quoteToLock;

        orderId = _createOrder(base, Side.BUY, price, amountBase);
        _insertBid(base, orderId);

        emit LimitOrderPlaced(orderId, msg.sender, Side.BUY, price, amountBase);
        _tryMatch(base);
    }

    function _limitSellFor(
        address base,
        uint256 price,
        uint256 amountBase
    ) internal returns (uint256 orderId) {
        _requireSupportedBase(base);
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();
        if (baseBalance[msg.sender][base] < amountBase)
            revert InsufficientBalance();

        baseBalance[msg.sender][base] -= amountBase;

        orderId = _createOrder(base, Side.SELL, price, amountBase);
        _insertAsk(base, orderId);

        emit LimitOrderPlaced(
            orderId,
            msg.sender,
            Side.SELL,
            price,
            amountBase
        );
        _tryMatch(base);
    }

    // -------------------------
    // Matching (per base)
    // -------------------------

    function _createOrder(
        address base,
        Side side,
        uint256 price,
        uint256 amountBase
    ) internal returns (uint256 id) {
        uint64 nonce = userOrderNonce[msg.sender][base]++;
        id = uint256(
            keccak256(
                abi.encodePacked(
                    block.chainid,
                    address(this),
                    msg.sender,
                    base,
                    nonce,
                    side,
                    price,
                    amountBase
                )
            )
        );
        if (orders[id].trader != address(0)) {
            id = uint256(keccak256(abi.encodePacked(id, block.timestamp)));
        }

        orders[id] = Order({
            id: id,
            trader: msg.sender,
            baseToken: base,
            side: side,
            price: price,
            amountBase: amountBase,
            filledBase: 0,
            timestamp: block.timestamp,
            active: true
        });
    }

    function _tryMatch(address base) internal {
        uint256[] storage bids = bidIds[base];
        uint256[] storage asks = askIds[base];

        while (bids.length > 0 && asks.length > 0) {
            Order storage bestBid = orders[bids[0]];
            Order storage bestAsk = orders[asks[0]];

            if (!bestBid.active) {
                _deactivateAndRemoveBidAt(base, 0);
                continue;
            }
            if (!bestAsk.active) {
                _deactivateAndRemoveAskAt(base, 0);
                continue;
            }

            if (bestBid.price < bestAsk.price) break;

            uint256 bidRemain = bestBid.amountBase - bestBid.filledBase;
            uint256 askRemain = bestAsk.amountBase - bestAsk.filledBase;

            if (bidRemain == 0) {
                _deactivateAndRemoveBidAt(base, 0);
                continue;
            }
            if (askRemain == 0) {
                _deactivateAndRemoveAskAt(base, 0);
                continue;
            }

            uint256 tradeBase = bidRemain < askRemain ? bidRemain : askRemain;

            uint256 tradePrice = bestAsk.price;
            uint256 tradeQuote = _quoteForBase(base, tradeBase, tradePrice);
            if (tradeQuote == 0) break;

            bestBid.filledBase += tradeBase;
            bestAsk.filledBase += tradeBase;

            // settlement
            baseBalance[bestBid.trader][base] += tradeBase;
            quoteBalance[bestAsk.trader] += tradeQuote;

            // refund bid maker if locked at bid.price but executed at lower price
            if (bestBid.filledBase == bestBid.amountBase) {
                uint256 lockedAtBid = _quoteForBase(
                    base,
                    bestBid.amountBase,
                    bestBid.price
                );
                uint256 spentAtAsk = _quoteForBase(
                    base,
                    bestBid.amountBase,
                    tradePrice
                );
                if (lockedAtBid > spentAtAsk)
                    quoteBalance[bestBid.trader] += (lockedAtBid - spentAtAsk);
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
                _deactivateAndRemoveBidAt(base, 0);
            if (bestAsk.filledBase == bestAsk.amountBase)
                _deactivateAndRemoveAskAt(base, 0);
        }
    }

    // -------------------------
    // Order book insertion (O(n))
    // -------------------------

    function _insertBid(address base, uint256 orderId) internal {
        uint256[] storage bids = bidIds[base];
        Order storage o = orders[orderId];
        uint256 n = bids.length;
        bids.push(orderId);

        uint256 i = n;
        while (i > 0) {
            Order storage prev = orders[bids[i - 1]];
            bool shouldSwap = (o.price > prev.price) ||
                (o.price == prev.price && o.timestamp < prev.timestamp);
            if (!shouldSwap) break;
            bids[i] = bids[i - 1];
            i--;
        }
        bids[i] = orderId;
    }

    function _insertAsk(address base, uint256 orderId) internal {
        uint256[] storage asks = askIds[base];
        Order storage o = orders[orderId];
        uint256 n = asks.length;
        asks.push(orderId);

        uint256 i = n;
        while (i > 0) {
            Order storage prev = orders[asks[i - 1]];
            bool shouldSwap = (o.price < prev.price) ||
                (o.price == prev.price && o.timestamp < prev.timestamp);
            if (!shouldSwap) break;
            asks[i] = asks[i - 1];
            i--;
        }
        asks[i] = orderId;
    }

    function _deactivateAndRemoveBidAt(address base, uint256 idx) internal {
        uint256[] storage bids = bidIds[base];
        uint256 oid = bids[idx];
        orders[oid].active = false;
        _removeIdFromArray(bids, oid);
    }

    function _deactivateAndRemoveAskAt(address base, uint256 idx) internal {
        uint256[] storage asks = askIds[base];
        uint256 oid = asks[idx];
        orders[oid].active = false;
        _removeIdFromArray(asks, oid);
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
    // Decimals-aware conversion helpers (per base)
    // -------------------------

    function _pow10(uint8 d) internal pure returns (uint256) {
        return 10 ** uint256(d);
    }

    function _quoteForBase(
        address base,
        uint256 baseAmount,
        uint256 price
    ) internal view returns (uint256) {
        // quoteSmallest = baseAmount * price * 10^quoteDecimals / (1e18 * 10^baseDecimals)
        uint8 bd = baseDecimals[base];

        uint256 numerator = baseAmount.mulDiv(price, 1);
        numerator = numerator.mulDiv(_pow10(quoteDecimals), 1);
        uint256 denom = PRICE_SCALE * _pow10(bd);
        return numerator / denom;
    }

    function _baseForQuote(
        address base,
        uint256 quoteAmount,
        uint256 price
    ) internal view returns (uint256) {
        // baseSmallest = quoteAmount * 1e18 * 10^baseDecimals / (price * 10^quoteDecimals)
        uint8 bd = baseDecimals[base];

        uint256 numerator = quoteAmount.mulDiv(PRICE_SCALE, 1);
        numerator = numerator.mulDiv(_pow10(bd), 1);
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
