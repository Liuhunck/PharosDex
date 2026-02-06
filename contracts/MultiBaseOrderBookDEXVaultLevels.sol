// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Multi-base single-quote orderbook DEX with internal balances (deposit/withdraw)
///         Orderbook storage is price-level bucketed:
///         - Each price has a FIFO linked-list of orders
///         - Each side maintains a sorted linked-list of active prices (levels)
///         This reduces O(n) array shifting and improves parallelism by avoiding global counters.
contract MultiBaseOrderBookDEXVaultLevels is Ownable {
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
        uint256 lockedQuote; // BUY only: remaining locked quote in quote smallest units
        uint256 timestamp;
        bool active;
        // linked-list pointers within the same price level
        uint256 prev;
        uint256 next;
    }

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

    struct PriceLevel {
        // order ids linked list
        uint256 head;
        uint256 tail;
        // aggregated remaining base in this price (for depth)
        uint256 totalRemainingBase;
        uint256 orderCount;
        // price level linked list (sorted)
        uint256 prevPrice;
        uint256 nextPrice;
        bool exists;
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
    // Orders / order id generation
    // -------------------------

    mapping(uint256 => Order) public orders;

    // per-user per-base nonce to derive orderId
    mapping(address => mapping(address => uint64)) public userOrderNonce;

    // per trader history for open-order queries
    mapping(address => mapping(address => uint256[])) private traderOrderIds; // trader => base => orderIds

    // -------------------------
    // Price-level books
    // -------------------------

    // best prices per base
    mapping(address => uint256) public bestBidPrice; // highest
    mapping(address => uint256) public bestAskPrice; // lowest

    // price levels per base
    mapping(address => mapping(uint256 => PriceLevel)) private bidLevels; // base => price => level
    mapping(address => mapping(uint256 => PriceLevel)) private askLevels; // base => price => level

    // last trade price per base (1e18)
    mapping(address => uint256) public lastTradePriceForBase;

    // -------------------------
    // Events / errors (kept compatible)
    // -------------------------

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
    // Admin
    // -------------------------

    function supportBaseToken(address base) external onlyOwner {
        _supportBaseToken(base);
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
    // Supported bases enumeration
    // -------------------------

    function getSupportedBases() external view returns (address[] memory) {
        return supportedBases;
    }

    function supportedBasesLength() external view returns (uint256) {
        return supportedBases.length;
    }

    function supportedBaseAt(uint256 index) external view returns (address) {
        return supportedBases[index];
    }

    // -------------------------
    // Deposit / Withdraw
    // -------------------------

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

    // -------------------------
    // Views
    // -------------------------

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

        uint256[] storage ids = traderOrderIds[trader][base];
        uint256 count = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            Order storage o = orders[ids[i]];
            if (o.active && o.filledBase < o.amountBase) count++;
        }

        OrderViewMulti[] memory res = new OrderViewMulti[](count);
        uint256 k = 0;
        for (uint256 i = 0; i < ids.length; i++) {
            Order storage o = orders[ids[i]];
            if (o.active && o.filledBase < o.amountBase) {
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

    function getLastPriceFor(address base) external view returns (uint256) {
        _requireSupportedBase(base);
        return lastTradePriceForBase[base];
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

        (uint256[] memory bp, uint256[] memory bs) = _depthFromLevelsBid(
            base,
            topN
        );
        (uint256[] memory ap, uint256[] memory asz) = _depthFromLevelsAsk(
            base,
            topN
        );
        return (bp, bs, ap, asz);
    }

    function _depthFromLevelsBid(
        address base,
        uint256 topN
    ) internal view returns (uint256[] memory prices, uint256[] memory sizes) {
        prices = new uint256[](topN);
        sizes = new uint256[](topN);

        uint256 p = bestBidPrice[base];
        uint256 level = 0;
        while (p != 0 && level < topN) {
            PriceLevel storage lvl = bidLevels[base][p];
            prices[level] = p;
            sizes[level] = lvl.totalRemainingBase;
            p = lvl.nextPrice; // next lower price
            level++;
        }
    }

    function _depthFromLevelsAsk(
        address base,
        uint256 topN
    ) internal view returns (uint256[] memory prices, uint256[] memory sizes) {
        prices = new uint256[](topN);
        sizes = new uint256[](topN);

        uint256 p = bestAskPrice[base];
        uint256 level = 0;
        while (p != 0 && level < topN) {
            PriceLevel storage lvl = askLevels[base][p];
            prices[level] = p;
            sizes[level] = lvl.totalRemainingBase;
            p = lvl.nextPrice; // next higher price
            level++;
        }
    }

    // -------------------------
    // Trading
    // -------------------------

    function marketBuyFor(address base, uint256 maxQuoteIn) external {
        _requireSupportedBase(base);
        if (maxQuoteIn == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < maxQuoteIn) revert InsufficientBalance();

        uint256 remainingQuote = maxQuoteIn;

        uint256 price = bestAskPrice[base];
        while (price != 0 && remainingQuote > 0) {
            PriceLevel storage lvl = askLevels[base][price];
            uint256 oid = lvl.head;

            while (oid != 0 && remainingQuote > 0) {
                Order storage ask = orders[oid];

                uint256 remainingBaseInOrder = ask.amountBase - ask.filledBase;
                if (!ask.active || remainingBaseInOrder == 0) {
                    uint256 nextOid = ask.next;
                    _removeOrderFromLevel(base, Side.SELL, price, oid);
                    oid = nextOid;
                    continue;
                }

                uint256 buyableBase = _baseForQuote(
                    base,
                    remainingQuote,
                    ask.price
                );
                if (buyableBase == 0) {
                    // can't afford even 1 unit at this price
                    return;
                }

                uint256 tradeBase = buyableBase < remainingBaseInOrder
                    ? buyableBase
                    : remainingBaseInOrder;
                uint256 tradeQuote = _quoteForBase(base, tradeBase, ask.price);
                if (tradeQuote == 0) return;

                // accounting
                ask.filledBase += tradeBase;
                remainingQuote -= tradeQuote;

                // taker spends quote, receives base
                quoteBalance[msg.sender] -= tradeQuote;
                baseBalance[msg.sender][base] += tradeBase;

                // maker receives quote
                quoteBalance[ask.trader] += tradeQuote;

                // level aggregate
                lvl.totalRemainingBase -= tradeBase;

                lastTradePriceForBase[base] = ask.price;
                emit Trade(
                    ask.id,
                    ask.trader,
                    msg.sender,
                    Side.BUY,
                    ask.price,
                    tradeBase
                );

                if (ask.filledBase == ask.amountBase) {
                    uint256 nextOid = ask.next;
                    _removeOrderFromLevel(base, Side.SELL, price, oid);
                    oid = nextOid;
                } else {
                    oid = ask.next;
                }
            }

            // Move to the current best ask (it may change as orders/levels are removed).
            price = bestAskPrice[base];
        }
    }

    function marketSellFor(address base, uint256 amountBase) external {
        _requireSupportedBase(base);
        if (amountBase == 0) revert InvalidAmount();
        if (baseBalance[msg.sender][base] < amountBase)
            revert InsufficientBalance();

        uint256 remainingBase = amountBase;

        uint256 price = bestBidPrice[base];
        while (price != 0 && remainingBase > 0) {
            PriceLevel storage lvl = bidLevels[base][price];
            uint256 oid = lvl.head;

            while (oid != 0 && remainingBase > 0) {
                Order storage bid = orders[oid];

                uint256 remainingBaseInOrder = bid.amountBase - bid.filledBase;
                if (!bid.active || remainingBaseInOrder == 0) {
                    uint256 nextOid = bid.next;
                    _removeOrderFromLevel(base, Side.BUY, price, oid);
                    oid = nextOid;
                    continue;
                }

                uint256 tradeBase = remainingBase < remainingBaseInOrder
                    ? remainingBase
                    : remainingBaseInOrder;
                uint256 tradeQuote = _quoteForBase(base, tradeBase, bid.price);
                if (tradeQuote == 0) return;

                // settle against bid's locked quote
                if (bid.lockedQuote < tradeQuote) {
                    // should never happen if accounting is correct
                    revert InsufficientBalance();
                }

                bid.filledBase += tradeBase;
                bid.lockedQuote -= tradeQuote;
                remainingBase -= tradeBase;

                // taker gives base, receives quote
                baseBalance[msg.sender][base] -= tradeBase;
                quoteBalance[msg.sender] += tradeQuote;

                // bid maker receives base
                baseBalance[bid.trader][base] += tradeBase;

                lvl.totalRemainingBase -= tradeBase;

                lastTradePriceForBase[base] = bid.price;
                emit Trade(
                    bid.id,
                    bid.trader,
                    msg.sender,
                    Side.SELL,
                    bid.price,
                    tradeBase
                );

                if (bid.filledBase == bid.amountBase) {
                    // refund any unspent locked quote (price improvement / rounding dust)
                    if (bid.lockedQuote > 0) {
                        quoteBalance[bid.trader] += bid.lockedQuote;
                        bid.lockedQuote = 0;
                    }
                    uint256 nextOid = bid.next;
                    _removeOrderFromLevel(base, Side.BUY, price, oid);
                    oid = nextOid;
                } else {
                    oid = bid.next;
                }
            }

            price = bestBidPrice[base];
        }
    }

    function limitBuyFor(
        address base,
        uint256 price,
        uint256 amountBase
    ) external returns (uint256 orderId) {
        _requireSupportedBase(base);
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();

        uint256 quoteToLock = _quoteForBase(base, amountBase, price);
        if (quoteToLock == 0) revert InvalidAmount();
        if (quoteBalance[msg.sender] < quoteToLock)
            revert InsufficientBalance();

        quoteBalance[msg.sender] -= quoteToLock;

        orderId = _createOrder(base, Side.BUY, price, amountBase, quoteToLock);
        _addOrderToLevel(base, Side.BUY, price, orderId);

        emit LimitOrderPlaced(orderId, msg.sender, Side.BUY, price, amountBase);
        _tryMatch(base);
    }

    function limitSellFor(
        address base,
        uint256 price,
        uint256 amountBase
    ) external returns (uint256 orderId) {
        _requireSupportedBase(base);
        if (price == 0) revert InvalidPrice();
        if (amountBase == 0) revert InvalidAmount();
        if (baseBalance[msg.sender][base] < amountBase)
            revert InsufficientBalance();

        baseBalance[msg.sender][base] -= amountBase;

        orderId = _createOrder(base, Side.SELL, price, amountBase, 0);
        _addOrderToLevel(base, Side.SELL, price, orderId);

        emit LimitOrderPlaced(
            orderId,
            msg.sender,
            Side.SELL,
            price,
            amountBase
        );
        _tryMatch(base);
    }

    function cancelOrder(uint256 orderId) external {
        Order storage o = orders[orderId];
        if (!o.active) revert NotActive();
        if (o.trader != msg.sender) revert NotOwner();

        o.active = false;

        uint256 remainingBase = o.amountBase - o.filledBase;

        if (o.side == Side.BUY) {
            // refund remaining locked quote
            if (o.lockedQuote > 0) {
                quoteBalance[msg.sender] += o.lockedQuote;
                o.lockedQuote = 0;
            }
        } else {
            // refund remaining base
            if (remainingBase > 0)
                baseBalance[msg.sender][o.baseToken] += remainingBase;
        }

        _removeOrderFromLevel(o.baseToken, o.side, o.price, orderId);
        emit OrderCancelled(orderId, msg.sender);
    }

    // -------------------------
    // Matching (per base)
    // -------------------------

    function _tryMatch(address base) internal {
        while (true) {
            uint256 bidP = bestBidPrice[base];
            uint256 askP = bestAskPrice[base];
            if (bidP == 0 || askP == 0 || bidP < askP) break;
            if (!_matchOnce(base, bidP, askP)) break;
        }
    }

    function _matchOnce(
        address base,
        uint256 bidP,
        uint256 askP
    ) internal returns (bool shouldContinue) {
        uint256 bidId = bidLevels[base][bidP].head;
        uint256 askId = askLevels[base][askP].head;

        if (bidId == 0) {
            _removePriceLevelIfEmpty(base, Side.BUY, bidP);
            return true;
        }
        if (askId == 0) {
            _removePriceLevelIfEmpty(base, Side.SELL, askP);
            return true;
        }

        Order storage bid = orders[bidId];
        if (!bid.active || bid.filledBase >= bid.amountBase) {
            _removeOrderFromLevel(base, Side.BUY, bidP, bidId);
            return true;
        }

        Order storage ask = orders[askId];
        if (!ask.active || ask.filledBase >= ask.amountBase) {
            _removeOrderFromLevel(base, Side.SELL, askP, askId);
            return true;
        }

        uint256 bidRemain = bid.amountBase - bid.filledBase;
        uint256 askRemain = ask.amountBase - ask.filledBase;
        uint256 tradeBase = bidRemain < askRemain ? bidRemain : askRemain;

        uint256 tradePrice = ask.price;
        uint256 tradeQuote = _quoteForBase(base, tradeBase, tradePrice);
        if (tradeQuote == 0) return false;
        if (bid.lockedQuote < tradeQuote) revert InsufficientBalance();

        bid.filledBase += tradeBase;
        bid.lockedQuote -= tradeQuote;
        ask.filledBase += tradeBase;

        baseBalance[bid.trader][base] += tradeBase;
        quoteBalance[ask.trader] += tradeQuote;

        bidLevels[base][bidP].totalRemainingBase -= tradeBase;
        askLevels[base][askP].totalRemainingBase -= tradeBase;

        lastTradePriceForBase[base] = tradePrice;
        emit Trade(
            ask.id,
            ask.trader,
            bid.trader,
            Side.BUY,
            tradePrice,
            tradeBase
        );

        if (bid.filledBase == bid.amountBase) {
            if (bid.lockedQuote > 0) {
                quoteBalance[bid.trader] += bid.lockedQuote;
                bid.lockedQuote = 0;
            }
            _removeOrderFromLevel(base, Side.BUY, bidP, bidId);
        }

        if (ask.filledBase == ask.amountBase) {
            _removeOrderFromLevel(base, Side.SELL, askP, askId);
        }

        return true;
    }

    // -------------------------
    // Price level management
    // -------------------------

    function _addOrderToLevel(
        address base,
        Side side,
        uint256 price,
        uint256 orderId
    ) internal {
        if (side == Side.BUY) {
            _ensureBidLevel(base, price);
            PriceLevel storage lvl = bidLevels[base][price];
            _appendOrderToLevel(lvl, orderId);
            lvl.totalRemainingBase += (orders[orderId].amountBase -
                orders[orderId].filledBase);
            lvl.orderCount += 1;
        } else {
            _ensureAskLevel(base, price);
            PriceLevel storage lvl = askLevels[base][price];
            _appendOrderToLevel(lvl, orderId);
            lvl.totalRemainingBase += (orders[orderId].amountBase -
                orders[orderId].filledBase);
            lvl.orderCount += 1;
        }
    }

    function _appendOrderToLevel(
        PriceLevel storage lvl,
        uint256 orderId
    ) internal {
        if (lvl.head == 0) {
            lvl.head = orderId;
            lvl.tail = orderId;
        } else {
            Order storage tailOrder = orders[lvl.tail];
            tailOrder.next = orderId;
            Order storage o = orders[orderId];
            o.prev = lvl.tail;
            lvl.tail = orderId;
        }
    }

    function _removeOrderFromLevel(
        address base,
        Side side,
        uint256 price,
        uint256 orderId
    ) internal {
        PriceLevel storage lvl = side == Side.BUY
            ? bidLevels[base][price]
            : askLevels[base][price];
        if (!lvl.exists) return;

        Order storage o = orders[orderId];

        // adjust aggregates if order is still active or partially filled
        uint256 remainingBase = o.amountBase - o.filledBase;
        if (lvl.totalRemainingBase >= remainingBase) {
            lvl.totalRemainingBase -= remainingBase;
        } else {
            lvl.totalRemainingBase = 0;
        }

        if (lvl.orderCount > 0) lvl.orderCount -= 1;

        uint256 prevId = o.prev;
        uint256 nextId = o.next;

        if (prevId != 0) {
            orders[prevId].next = nextId;
        } else {
            lvl.head = nextId;
        }

        if (nextId != 0) {
            orders[nextId].prev = prevId;
        } else {
            lvl.tail = prevId;
        }

        o.prev = 0;
        o.next = 0;

        // Fully-filled orders should no longer be considered active.
        if (o.filledBase >= o.amountBase) {
            o.active = false;
        }

        _removePriceLevelIfEmpty(base, side, price);
    }

    function _removePriceLevelIfEmpty(
        address base,
        Side side,
        uint256 price
    ) internal {
        PriceLevel storage lvl = side == Side.BUY
            ? bidLevels[base][price]
            : askLevels[base][price];
        if (!lvl.exists) return;
        if (lvl.head != 0 || lvl.orderCount != 0 || lvl.totalRemainingBase != 0)
            return;

        uint256 prevP = lvl.prevPrice;
        uint256 nextP = lvl.nextPrice;

        if (side == Side.BUY) {
            if (prevP != 0) {
                bidLevels[base][prevP].nextPrice = nextP;
            } else {
                bestBidPrice[base] = nextP;
            }
            if (nextP != 0) {
                bidLevels[base][nextP].prevPrice = prevP;
            }
        } else {
            if (prevP != 0) {
                askLevels[base][prevP].nextPrice = nextP;
            } else {
                bestAskPrice[base] = nextP;
            }
            if (nextP != 0) {
                askLevels[base][nextP].prevPrice = prevP;
            }
        }

        delete lvl.prevPrice;
        delete lvl.nextPrice;
        lvl.exists = false;
    }

    function _ensureBidLevel(address base, uint256 price) internal {
        PriceLevel storage lvl = bidLevels[base][price];
        if (lvl.exists) return;

        lvl.exists = true;

        uint256 best = bestBidPrice[base];
        if (best == 0) {
            bestBidPrice[base] = price;
            return;
        }

        if (price > best) {
            // new best
            lvl.nextPrice = best;
            bidLevels[base][best].prevPrice = price;
            bestBidPrice[base] = price;
            return;
        }

        // insert into descending list: best -> ... -> lowest
        uint256 cur = best;
        while (true) {
            uint256 next = bidLevels[base][cur].nextPrice;
            if (next == 0 || price > next) {
                // insert after cur
                lvl.prevPrice = cur;
                lvl.nextPrice = next;
                bidLevels[base][cur].nextPrice = price;
                if (next != 0) {
                    bidLevels[base][next].prevPrice = price;
                }
                return;
            }
            cur = next;
        }
    }

    function _ensureAskLevel(address base, uint256 price) internal {
        PriceLevel storage lvl = askLevels[base][price];
        if (lvl.exists) return;

        lvl.exists = true;

        uint256 best = bestAskPrice[base];
        if (best == 0) {
            bestAskPrice[base] = price;
            return;
        }

        if (price < best) {
            // new best
            lvl.nextPrice = best;
            askLevels[base][best].prevPrice = price;
            bestAskPrice[base] = price;
            return;
        }

        // insert into ascending list: best -> ... -> highest
        uint256 cur = best;
        while (true) {
            uint256 next = askLevels[base][cur].nextPrice;
            if (next == 0 || price < next) {
                lvl.prevPrice = cur;
                lvl.nextPrice = next;
                askLevels[base][cur].nextPrice = price;
                if (next != 0) {
                    askLevels[base][next].prevPrice = price;
                }
                return;
            }
            cur = next;
        }
    }

    // -------------------------
    // Order creation
    // -------------------------

    function _createOrder(
        address base,
        Side side,
        uint256 price,
        uint256 amountBase,
        uint256 lockedQuote
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
        if (id == 0 || orders[id].trader != address(0)) {
            id = uint256(
                keccak256(abi.encodePacked(id, block.timestamp, nonce))
            );
            if (id == 0)
                id = uint256(
                    keccak256(
                        abi.encodePacked(block.timestamp, msg.sender, nonce)
                    )
                );
        }

        orders[id] = Order({
            id: id,
            trader: msg.sender,
            baseToken: base,
            side: side,
            price: price,
            amountBase: amountBase,
            filledBase: 0,
            lockedQuote: lockedQuote,
            timestamp: block.timestamp,
            active: true,
            prev: 0,
            next: 0
        });

        traderOrderIds[msg.sender][base].push(id);
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
