// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice A simple on-chain spot orderbook + vault for a single base/quote market.
///
/// Design notes for high-parallel chains (e.g. Pharos):
/// - One contract per market/pair to isolate state and maximize parallelism across markets.
/// - Optional `hintPrice` + `maxHops` to avoid long linked-list traversal (reduce shared-state reads).
/// - Matching work is bounded via `maxMatches` to keep transactions small and schedulable.
contract PharosSpotMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Side {
        Buy,
        Sell
    }

    struct Order {
        address owner;
        Side side;
        uint256 priceE18;
        uint256 amountBaseRemaining;
        // For BUY: reserved quote (locked). For SELL: reserved base (locked).
        uint256 reserved;
        uint256 prev;
        uint256 next;
        bool isMarket;
        bool active;
    }

    struct Level {
        uint256 head;
        uint256 tail;
        uint256 totalBase;
        uint256 prevPrice;
        uint256 nextPrice;
        bool exists;
    }

    error ZeroAmount();
    error ZeroPrice();
    error InsufficientBalance();
    error NotOrderOwner();
    error OrderNotActive();
    error WouldCrossBook();
    error BadHint();
    error EmptyBook();
    error Slippage();

    event Deposit(address indexed user, address indexed token, uint256 amount);
    event Withdraw(address indexed user, address indexed token, uint256 amount);

    event OrderPlaced(
        uint256 indexed orderId,
        address indexed user,
        Side side,
        bool isMarket,
        uint256 priceE18,
        uint256 amountBase,
        uint256 reserved
    );

    event OrderCanceled(
        uint256 indexed orderId,
        address indexed user,
        uint256 refundAmount
    );

    event Trade(
        uint256 indexed makerOrderId,
        uint256 indexed takerOrderId,
        address indexed maker,
        address taker,
        Side makerSide,
        uint256 priceE18,
        uint256 amountBase,
        uint256 amountQuote
    );

    IERC20 public immutable baseToken;
    IERC20 public immutable quoteToken;

    // balances[token][user] => available balance in vault
    mapping(address => mapping(address => uint256)) public balances;

    // orderbook storage
    uint256 public nextOrderId = 1;
    mapping(uint256 => Order) public orders;

    // price => level
    mapping(uint256 => Level) private bidLevels;
    mapping(uint256 => Level) private askLevels;

    uint256 public bestBidPrice; // highest bid
    uint256 public bestAskPrice; // lowest ask

    uint256 public lastTradePriceE18;

    constructor(address baseToken_, address quoteToken_) {
        require(
            baseToken_ != address(0) && quoteToken_ != address(0),
            "ZERO_TOKEN"
        );
        require(baseToken_ != quoteToken_, "SAME_TOKEN");
        baseToken = IERC20(baseToken_);
        quoteToken = IERC20(quoteToken_);
    }

    // -------------------------
    // Vault: deposit / withdraw
    // -------------------------

    function deposit(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        balances[token][msg.sender] += amount;
        emit Deposit(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 bal = balances[token][msg.sender];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balances[token][msg.sender] = bal - amount;
        }
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, token, amount);
    }

    // -------------------------
    // Views: orderbook / price
    // -------------------------

    function getBestPrices()
        external
        view
        returns (uint256 bidPriceE18, uint256 askPriceE18)
    {
        return (bestBidPrice, bestAskPrice);
    }

    /// @notice Returns up to `levels` price levels for each side.
    /// @dev Arrays may be shorter if book has fewer levels.
    function getDepth(
        uint32 levels
    )
        external
        view
        returns (
            uint256[] memory bidPrices,
            uint256[] memory bidBaseTotals,
            uint256[] memory askPrices,
            uint256[] memory askBaseTotals
        )
    {
        bidPrices = new uint256[](levels);
        bidBaseTotals = new uint256[](levels);
        askPrices = new uint256[](levels);
        askBaseTotals = new uint256[](levels);

        uint256 p = bestBidPrice;
        uint256 i = 0;
        while (p != 0 && i < levels) {
            Level storage lvl = bidLevels[p];
            bidPrices[i] = p;
            bidBaseTotals[i] = lvl.totalBase;
            p = lvl.nextPrice;
            unchecked {
                ++i;
            }
        }
        assembly {
            mstore(bidPrices, i)
            mstore(bidBaseTotals, i)
        }

        p = bestAskPrice;
        i = 0;
        while (p != 0 && i < levels) {
            Level storage lvl2 = askLevels[p];
            askPrices[i] = p;
            askBaseTotals[i] = lvl2.totalBase;
            p = lvl2.nextPrice;
            unchecked {
                ++i;
            }
        }
        assembly {
            mstore(askPrices, i)
            mstore(askBaseTotals, i)
        }
    }

    // -------------------------
    // Orders: limit / market
    // -------------------------

    /// @param hintPrice For a NEW price level insertion: expected previous price on the sorted list (0 for head).
    /// @param maxHops Bounds traversal when hint is not provided; set small to keep tx parallel-friendly.
    /// @param postOnly If true, reverts if the order would immediately match.
    /// @param maxMatches Bound matching loop; set 0 to skip matching and only post to book.
    function placeLimitOrder(
        Side side,
        uint256 priceE18,
        uint256 amountBase,
        uint256 hintPrice,
        uint32 maxHops,
        bool postOnly,
        uint32 maxMatches
    ) external nonReentrant returns (uint256 orderId) {
        if (amountBase == 0) revert ZeroAmount();
        if (priceE18 == 0) revert ZeroPrice();

        // post-only guard
        if (postOnly) {
            if (side == Side.Buy) {
                if (bestAskPrice != 0 && bestAskPrice <= priceE18)
                    revert WouldCrossBook();
            } else {
                if (bestBidPrice != 0 && bestBidPrice >= priceE18)
                    revert WouldCrossBook();
            }
        }

        orderId = _createLimitOrder(side, priceE18, amountBase);
        emit OrderPlaced(
            orderId,
            msg.sender,
            side,
            false,
            priceE18,
            amountBase,
            orders[orderId].reserved
        );

        // try match (bounded)
        if (maxMatches > 0) {
            _match(orderId, hintPrice, maxHops, maxMatches);
        } else {
            // If not matching now, ensure order is posted to book.
            _ensurePosted(orderId, hintPrice, maxHops);
        }
    }

    /// @notice Market order.
    /// @param amountBase For sell: exact base to sell. For buy: desired base to buy (may be partially filled).
    /// @param maxQuoteIn For buy: max quote to spend. Ignored for sell.
    /// @param minQuoteOut For sell: minimum quote to receive. Ignored for buy.
    function placeMarketOrder(
        Side side,
        uint256 amountBase,
        uint256 maxQuoteIn,
        uint256 minQuoteOut,
        uint32 maxMatches
    )
        external
        nonReentrant
        returns (uint256 orderId, uint256 filledBase, uint256 filledQuote)
    {
        if (amountBase == 0) revert ZeroAmount();
        if (maxMatches == 0) maxMatches = 64; // reasonable default bound

        if (side == Side.Buy) {
            if (bestAskPrice == 0) revert EmptyBook();
            if (maxQuoteIn == 0) revert ZeroAmount();
            // lock quote
            if (balances[address(quoteToken)][msg.sender] < maxQuoteIn)
                revert InsufficientBalance();
            balances[address(quoteToken)][msg.sender] -= maxQuoteIn;
            orderId = _newOrderId();
            orders[orderId] = Order({
                owner: msg.sender,
                side: side,
                priceE18: 0,
                amountBaseRemaining: amountBase,
                reserved: maxQuoteIn,
                prev: 0,
                next: 0,
                isMarket: true,
                active: true
            });
            emit OrderPlaced(
                orderId,
                msg.sender,
                side,
                true,
                0,
                amountBase,
                maxQuoteIn
            );

            (filledBase, filledQuote) = _matchMarketBuy(orderId, maxMatches);
            // refund remaining quote reserve
            uint256 rem = orders[orderId].reserved;
            if (rem > 0) {
                balances[address(quoteToken)][msg.sender] += rem;
                orders[orderId].reserved = 0;
            }

            if (filledQuote > maxQuoteIn) revert Slippage();
        } else {
            if (bestBidPrice == 0) revert EmptyBook();
            // lock base
            if (balances[address(baseToken)][msg.sender] < amountBase)
                revert InsufficientBalance();
            balances[address(baseToken)][msg.sender] -= amountBase;

            orderId = _newOrderId();
            orders[orderId] = Order({
                owner: msg.sender,
                side: side,
                priceE18: 0,
                amountBaseRemaining: amountBase,
                reserved: amountBase,
                prev: 0,
                next: 0,
                isMarket: true,
                active: true
            });
            emit OrderPlaced(
                orderId,
                msg.sender,
                side,
                true,
                0,
                amountBase,
                amountBase
            );

            (filledBase, filledQuote) = _matchMarketSell(orderId, maxMatches);

            // return remaining base reserve
            uint256 remBase = orders[orderId].reserved;
            if (remBase > 0) {
                balances[address(baseToken)][msg.sender] += remBase;
                orders[orderId].reserved = 0;
            }

            if (filledQuote < minQuoteOut) revert Slippage();
        }

        orders[orderId].active = false;
    }

    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage o = orders[orderId];
        if (!o.active || o.isMarket) revert OrderNotActive();
        if (o.owner != msg.sender) revert NotOrderOwner();

        // remove from book
        _removeFromBook(orderId);

        uint256 refund;
        if (o.side == Side.Buy) {
            refund = o.reserved;
            if (refund > 0) balances[address(quoteToken)][msg.sender] += refund;
        } else {
            refund = o.reserved;
            if (refund > 0) balances[address(baseToken)][msg.sender] += refund;
        }

        o.reserved = 0;
        o.amountBaseRemaining = 0;
        o.active = false;

        emit OrderCanceled(orderId, msg.sender, refund);
    }

    // -------------------------
    // Internal: order creation
    // -------------------------

    function _newOrderId() internal returns (uint256 id) {
        id = nextOrderId;
        unchecked {
            nextOrderId = id + 1;
        }
    }

    function _createLimitOrder(
        Side side,
        uint256 priceE18,
        uint256 amountBase
    ) internal returns (uint256 orderId) {
        orderId = _newOrderId();

        if (side == Side.Buy) {
            // reserve quote at limit price (ceil to ensure enough)
            uint256 reserveQuote = Math.mulDiv(
                amountBase,
                priceE18,
                1e18,
                Math.Rounding.Ceil
            );
            if (balances[address(quoteToken)][msg.sender] < reserveQuote)
                revert InsufficientBalance();
            balances[address(quoteToken)][msg.sender] -= reserveQuote;

            orders[orderId] = Order({
                owner: msg.sender,
                side: side,
                priceE18: priceE18,
                amountBaseRemaining: amountBase,
                reserved: reserveQuote,
                prev: 0,
                next: 0,
                isMarket: false,
                active: true
            });
        } else {
            // reserve base
            if (balances[address(baseToken)][msg.sender] < amountBase)
                revert InsufficientBalance();
            balances[address(baseToken)][msg.sender] -= amountBase;

            orders[orderId] = Order({
                owner: msg.sender,
                side: side,
                priceE18: priceE18,
                amountBaseRemaining: amountBase,
                reserved: amountBase,
                prev: 0,
                next: 0,
                isMarket: false,
                active: true
            });
        }
    }

    // -------------------------
    // Internal: posting / levels
    // -------------------------

    function _ensurePosted(
        uint256 orderId,
        uint256 hintPrice,
        uint32 maxHops
    ) internal {
        Order storage o = orders[orderId];
        if (!o.active || o.isMarket) return;
        if (o.prev != 0 || o.next != 0) return; // already linked in some level

        if (o.side == Side.Buy) {
            _addToSideBook(orderId, bidLevels, true, hintPrice, maxHops);
        } else {
            _addToSideBook(orderId, askLevels, false, hintPrice, maxHops);
        }
    }

    function _addToSideBook(
        uint256 orderId,
        mapping(uint256 => Level) storage levels,
        bool isBids,
        uint256 hintPrice,
        uint32 maxHops
    ) internal {
        Order storage o = orders[orderId];
        uint256 price = o.priceE18;
        Level storage lvl = levels[price];

        if (!lvl.exists) {
            _insertPriceLevel(levels, isBids, price, hintPrice, maxHops);
            lvl.exists = true;
        }

        // FIFO append at tail
        if (lvl.tail == 0) {
            lvl.head = orderId;
            lvl.tail = orderId;
        } else {
            uint256 oldTail = lvl.tail;
            orders[oldTail].next = orderId;
            o.prev = oldTail;
            lvl.tail = orderId;
        }

        lvl.totalBase += o.amountBaseRemaining;
    }

    function _insertPriceLevel(
        mapping(uint256 => Level) storage levels,
        bool isBids,
        uint256 price,
        uint256 hintPrevPrice,
        uint32 maxHops
    ) internal {
        // If book empty
        if (isBids) {
            if (bestBidPrice == 0) {
                bestBidPrice = price;
                return;
            }
            // Fast-path: new best
            if (price > bestBidPrice) {
                Level storage oldBest = levels[bestBidPrice];
                oldBest.prevPrice = price;
                levels[price].nextPrice = bestBidPrice;
                bestBidPrice = price;
                return;
            }
        } else {
            if (bestAskPrice == 0) {
                bestAskPrice = price;
                return;
            }
            if (price < bestAskPrice) {
                Level storage oldBest2 = levels[bestAskPrice];
                oldBest2.prevPrice = price;
                levels[price].nextPrice = bestAskPrice;
                bestAskPrice = price;
                return;
            }
        }

        // Use hint if provided.
        if (hintPrevPrice != 0) {
            Level storage hintPrev = levels[hintPrevPrice];
            uint256 nextP = hintPrev.nextPrice;

            if (isBids) {
                // ... hintPrevPrice >= price >= nextP (or nextP==0)
                if (hintPrevPrice < price) revert BadHint();
                if (nextP != 0 && nextP > price) revert BadHint();
            } else {
                // ... hintPrevPrice <= price <= nextP (or nextP==0)
                if (hintPrevPrice > price) revert BadHint();
                if (nextP != 0 && nextP < price) revert BadHint();
            }

            // link between hintPrevPrice and nextP
            levels[price].prevPrice = hintPrevPrice;
            levels[price].nextPrice = nextP;
            hintPrev.nextPrice = price;
            if (nextP != 0) {
                levels[nextP].prevPrice = price;
            }
            return;
        }

        // No hint: traverse from best, bounded.
        uint256 cur = isBids ? bestBidPrice : bestAskPrice;
        uint32 hops = 0;
        while (cur != 0) {
            uint256 nxt = levels[cur].nextPrice;
            bool shouldInsert;
            if (isBids) {
                // descending: insert after cur if cur >= price and (nxt==0 or nxt <= price)
                shouldInsert = cur >= price && (nxt == 0 || nxt <= price);
            } else {
                // ascending: insert after cur if cur <= price and (nxt==0 or nxt >= price)
                shouldInsert = cur <= price && (nxt == 0 || nxt >= price);
            }

            if (shouldInsert) {
                levels[price].prevPrice = cur;
                levels[price].nextPrice = nxt;
                levels[cur].nextPrice = price;
                if (nxt != 0) levels[nxt].prevPrice = price;
                return;
            }

            cur = nxt;
            unchecked {
                ++hops;
            }
            if (maxHops != 0 && hops >= maxHops) revert BadHint();
        }

        revert BadHint();
    }

    function _removeFromBook(uint256 orderId) internal {
        Order storage o = orders[orderId];
        uint256 price = o.priceE18;

        if (o.side == Side.Buy) {
            _removeFromSideBook(orderId, bidLevels, true, price);
        } else {
            _removeFromSideBook(orderId, askLevels, false, price);
        }
    }

    function _removeFromSideBook(
        uint256 orderId,
        mapping(uint256 => Level) storage levels,
        bool isBids,
        uint256 price
    ) internal {
        Order storage o = orders[orderId];
        Level storage lvl = levels[price];

        // unlink from level queue
        uint256 p = o.prev;
        uint256 n = o.next;
        if (p != 0) orders[p].next = n;
        if (n != 0) orders[n].prev = p;

        if (lvl.head == orderId) lvl.head = n;
        if (lvl.tail == orderId) lvl.tail = p;

        o.prev = 0;
        o.next = 0;

        // update level total
        if (lvl.totalBase >= o.amountBaseRemaining) {
            lvl.totalBase -= o.amountBaseRemaining;
        } else {
            lvl.totalBase = 0;
        }

        // If level empty, remove level from price list
        if (lvl.head == 0) {
            _removePriceLevel(levels, isBids, price);
            delete levels[price];
        }
    }

    function _removePriceLevel(
        mapping(uint256 => Level) storage levels,
        bool isBids,
        uint256 price
    ) internal {
        uint256 prevP = levels[price].prevPrice;
        uint256 nextP = levels[price].nextPrice;

        if (prevP != 0) {
            levels[prevP].nextPrice = nextP;
        } else {
            // removing best
            if (isBids) bestBidPrice = nextP;
            else bestAskPrice = nextP;
        }

        if (nextP != 0) {
            levels[nextP].prevPrice = prevP;
        }
    }

    // -------------------------
    // Internal: matching (limit)
    // -------------------------

    function _match(
        uint256 takerOrderId,
        uint256 hintPrice,
        uint32 maxHops,
        uint32 maxMatches
    ) internal {
        Order storage taker = orders[takerOrderId];

        // If not on book yet (taker could be maker after partial), ensure posted before matching remainder.
        // We match first, and only post residual.
        if (taker.side == Side.Buy) {
            uint32 matches = 0;
            while (taker.amountBaseRemaining > 0 && matches < maxMatches) {
                uint256 askP = bestAskPrice;
                if (askP == 0 || askP > taker.priceE18) break;

                uint256 makerId = askLevels[askP].head;
                if (makerId == 0) {
                    _removePriceLevel(askLevels, false, askP);
                    delete askLevels[askP];
                    continue;
                }

                _trade(takerOrderId, makerId);
                unchecked {
                    ++matches;
                }
            }

            if (taker.amountBaseRemaining > 0) {
                _addToSideBook(
                    takerOrderId,
                    bidLevels,
                    true,
                    hintPrice,
                    maxHops
                );
            } else {
                taker.active = false;
            }
        } else {
            uint32 matches2 = 0;
            while (taker.amountBaseRemaining > 0 && matches2 < maxMatches) {
                uint256 bidP = bestBidPrice;
                if (bidP == 0 || bidP < taker.priceE18) break;

                uint256 makerId2 = bidLevels[bidP].head;
                if (makerId2 == 0) {
                    _removePriceLevel(bidLevels, true, bidP);
                    delete bidLevels[bidP];
                    continue;
                }

                _trade(takerOrderId, makerId2);
                unchecked {
                    ++matches2;
                }
            }

            if (taker.amountBaseRemaining > 0) {
                _addToSideBook(
                    takerOrderId,
                    askLevels,
                    false,
                    hintPrice,
                    maxHops
                );
            } else {
                taker.active = false;
            }
        }
    }

    // -------------------------
    // Internal: matching (market)
    // -------------------------

    function _matchMarketBuy(
        uint256 takerOrderId,
        uint32 maxMatches
    ) internal returns (uint256 filledBase, uint256 filledQuote) {
        Order storage taker = orders[takerOrderId];
        uint32 matches = 0;

        while (
            taker.amountBaseRemaining > 0 &&
            taker.reserved > 0 &&
            matches < maxMatches
        ) {
            uint256 askP = bestAskPrice;
            if (askP == 0) break;

            uint256 makerId = askLevels[askP].head;
            if (makerId == 0) {
                _removePriceLevel(askLevels, false, askP);
                delete askLevels[askP];
                continue;
            }

            // compute max base affordable at this price
            uint256 maxBase = Math.mulDiv(
                taker.reserved,
                1e18,
                askP,
                Math.Rounding.Floor
            );
            if (maxBase == 0) break;

            (uint256 db, uint256 dq) = _tradeWithCap(
                takerOrderId,
                makerId,
                maxBase
            );
            filledBase += db;
            filledQuote += dq;

            unchecked {
                ++matches;
            }
        }

        return (filledBase, filledQuote);
    }

    function _matchMarketSell(
        uint256 takerOrderId,
        uint32 maxMatches
    ) internal returns (uint256 filledBase, uint256 filledQuote) {
        Order storage taker = orders[takerOrderId];
        uint32 matches = 0;

        while (
            taker.amountBaseRemaining > 0 &&
            taker.reserved > 0 &&
            matches < maxMatches
        ) {
            uint256 bidP = bestBidPrice;
            if (bidP == 0) break;

            uint256 makerId = bidLevels[bidP].head;
            if (makerId == 0) {
                _removePriceLevel(bidLevels, true, bidP);
                delete bidLevels[bidP];
                continue;
            }

            (uint256 db, uint256 dq) = _tradeWithCap(
                takerOrderId,
                makerId,
                taker.amountBaseRemaining
            );
            filledBase += db;
            filledQuote += dq;

            unchecked {
                ++matches;
            }
        }

        return (filledBase, filledQuote);
    }

    // -------------------------
    // Internal: trade execution
    // -------------------------

    function _trade(uint256 takerOrderId, uint256 makerOrderId) internal {
        _tradeWithCap(takerOrderId, makerOrderId, type(uint256).max);
    }

    /// @dev Executes one maker vs taker match, capped by `capBase` on the taker side.
    function _tradeWithCap(
        uint256 takerOrderId,
        uint256 makerOrderId,
        uint256 capBase
    ) internal returns (uint256 fillBase, uint256 fillQuote) {
        Order storage taker = orders[takerOrderId];
        Order storage maker = orders[makerOrderId];

        if (!taker.active || !maker.active) return (0, 0);
        if (taker.isMarket == false && maker.isMarket == true) return (0, 0);

        // maker is from the book; trade price is maker price
        uint256 tradePrice = maker.priceE18;

        uint256 a = taker.amountBaseRemaining;
        uint256 b = maker.amountBaseRemaining;
        uint256 m = capBase;
        fillBase = a < b ? a : b;
        if (fillBase > m) fillBase = m;
        if (fillBase == 0) return (0, 0);

        // quote computed with floor
        fillQuote = Math.mulDiv(
            fillBase,
            tradePrice,
            1e18,
            Math.Rounding.Floor
        );
        if (fillQuote == 0) {
            // If the quote rounds to 0 at this precision, don't trade (prevents free base).
            return (0, 0);
        }

        // Apply balance movements depending on sides.
        // maker is either Sell (ask) or Buy (bid) depending on which book we took it from.
        if (maker.side == Side.Sell) {
            // maker sells base, receives quote; taker buys base, pays quote
            _consumeTakerQuote(taker, fillBase, fillQuote, tradePrice);
            _consumeMakerBase(maker, fillBase);

            balances[address(baseToken)][taker.owner] += fillBase;
            balances[address(quoteToken)][maker.owner] += fillQuote;
        } else {
            // maker buys base, pays quote; taker sells base, receives quote
            _consumeTakerBase(taker, fillBase);
            _consumeMakerQuote(maker, fillBase, fillQuote);

            balances[address(baseToken)][maker.owner] += fillBase;
            balances[address(quoteToken)][taker.owner] += fillQuote;
        }

        // Update remaining sizes
        taker.amountBaseRemaining -= fillBase;
        maker.amountBaseRemaining -= fillBase;

        lastTradePriceE18 = tradePrice;

        // Update levels totals and remove empty orders from book
        _onFillFromBook(makerOrderId, fillBase);

        // Close orders if done
        if (maker.amountBaseRemaining == 0) {
            maker.active = false;
        }

        emit Trade(
            makerOrderId,
            takerOrderId,
            maker.owner,
            taker.owner,
            maker.side,
            tradePrice,
            fillBase,
            fillQuote
        );

        return (fillBase, fillQuote);
    }

    function _consumeMakerBase(Order storage maker, uint256 fillBase) internal {
        // SELL maker reserved base decreases by fillBase
        maker.reserved -= fillBase;
    }

    function _consumeTakerBase(Order storage taker, uint256 fillBase) internal {
        // SELL taker (market or limit) reserved base decreases by fillBase
        taker.reserved -= fillBase;
    }

    function _consumeTakerQuote(
        Order storage taker,
        uint256 fillBase,
        uint256 fillQuote,
        uint256 tradePrice
    ) internal {
        if (taker.isMarket) {
            // Market buy: pay exactly fillQuote from reserve
            if (taker.reserved < fillQuote) revert InsufficientBalance();
            taker.reserved -= fillQuote;
            return;
        }

        // Limit buy: reserve reduces by (fillBase * limitPrice) ceil; refund the difference
        uint256 reservedDelta = Math.mulDiv(
            fillBase,
            taker.priceE18,
            1e18,
            Math.Rounding.Ceil
        );
        if (taker.reserved < reservedDelta) revert InsufficientBalance();
        taker.reserved -= reservedDelta;

        // refund = reservedDelta - actualQuote (at maker price)
        uint256 refund = reservedDelta - fillQuote;
        if (refund > 0) {
            balances[address(quoteToken)][taker.owner] += refund;
        }

        // (tradePrice is unused here but kept for clarity)
        tradePrice;
    }

    function _consumeMakerQuote(
        Order storage maker,
        uint256 fillBase,
        uint256 fillQuote
    ) internal {
        // BUY maker reserved quote decreases by (fillBase * maker.limitPrice) ceil; refund delta (since trade can be better)
        uint256 reservedDelta = Math.mulDiv(
            fillBase,
            maker.priceE18,
            1e18,
            Math.Rounding.Ceil
        );
        if (maker.reserved < reservedDelta) revert InsufficientBalance();
        maker.reserved -= reservedDelta;

        // maker pays actualQuote; refund difference
        uint256 refund = reservedDelta - fillQuote;
        if (refund > 0) {
            balances[address(quoteToken)][maker.owner] += refund;
        }
    }

    function _onFillFromBook(uint256 makerOrderId, uint256 fillBase) internal {
        Order storage maker = orders[makerOrderId];
        uint256 price = maker.priceE18;

        if (maker.side == Side.Buy) {
            Level storage lvl = bidLevels[price];
            if (lvl.totalBase >= fillBase) lvl.totalBase -= fillBase;
            else lvl.totalBase = 0;

            if (maker.amountBaseRemaining == 0) {
                _dequeueHeadIfNeeded(makerOrderId, bidLevels, true, price);
            }
        } else {
            Level storage lvl2 = askLevels[price];
            if (lvl2.totalBase >= fillBase) lvl2.totalBase -= fillBase;
            else lvl2.totalBase = 0;

            if (maker.amountBaseRemaining == 0) {
                _dequeueHeadIfNeeded(makerOrderId, askLevels, false, price);
            }
        }
    }

    function _dequeueHeadIfNeeded(
        uint256 makerOrderId,
        mapping(uint256 => Level) storage levels,
        bool isBids,
        uint256 price
    ) internal {
        Level storage lvl = levels[price];
        if (lvl.head != makerOrderId) return;

        uint256 nextId = orders[makerOrderId].next;
        lvl.head = nextId;
        if (nextId == 0) {
            lvl.tail = 0;
            _removePriceLevel(levels, isBids, price);
            delete levels[price];
        } else {
            orders[nextId].prev = 0;
        }

        orders[makerOrderId].next = 0;
        orders[makerOrderId].prev = 0;
    }
}
