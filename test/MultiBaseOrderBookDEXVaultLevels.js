const { expect } = require("chai");

function u(amount, decimals) {
    return ethers.parseUnits(String(amount), decimals);
}

function findEventArgs(receipt, contract, eventName) {
    for (const log of receipt.logs) {
        try {
            const parsed = contract.interface.parseLog(log);
            if (parsed && parsed.name === eventName) return parsed.args;
        } catch (_) {
            // ignore non-matching logs
        }
    }
    return null;
}

describe("MultiBaseOrderBookDEXVaultLevels", function () {
    async function deployFixture() {
        const [owner, alice, bob, carol] = await ethers.getSigners();

        const MockERC20 = await ethers.getContractFactory("MockERC20");
        const quote = await MockERC20.deploy("USD Tether", "USDT", 6);
        const baseA = await MockERC20.deploy("Dogecoin", "DOGE", 18);
        const baseB = await MockERC20.deploy("Bitcoin", "WBTC", 8);

        // Mint tokens
        await quote.mint(alice.address, u(100000, 6));
        await quote.mint(bob.address, u(100000, 6));
        await quote.mint(carol.address, u(100000, 6));

        await baseA.mint(alice.address, u(1000, 18));
        await baseA.mint(bob.address, u(1000, 18));
        await baseA.mint(carol.address, u(1000, 18));

        await baseB.mint(alice.address, u(10, 8));
        await baseB.mint(bob.address, u(10, 8));

        const Dex = await ethers.getContractFactory("MultiBaseOrderBookDEXVaultLevels");
        const dex = await Dex.deploy(quote.target);

        // Support bases
        await dex.connect(owner).supportBaseToken(baseA.target);
        await dex.connect(owner).supportBaseToken(baseB.target);

        return { owner, alice, bob, carol, dex, quote, baseA, baseB };
    }

    it("reverts on unsupported base and invalid params", async function () {
        const { alice, bob, dex, quote, baseA } = await deployFixture();

        // Unsupported base
        await expect(dex.getLastPriceFor(ethers.ZeroAddress)).to.be.revertedWithCustomError(
            dex,
            "UnsupportedBaseToken",
        );

        await expect(dex.connect(alice).depositBaseFor(ethers.ZeroAddress, 1n)).to.be.revertedWithCustomError(
            dex,
            "UnsupportedBaseToken",
        );

        await expect(dex.connect(alice).limitBuyFor(ethers.ZeroAddress, u(1, 18), 1n)).to.be.revertedWithCustomError(
            dex,
            "UnsupportedBaseToken",
        );

        // Invalid amounts/prices
        await expect(dex.connect(alice).depositQuote(0n)).to.be.revertedWithCustomError(dex, "InvalidAmount");
        await expect(dex.connect(alice).withdrawQuote(0n)).to.be.revertedWithCustomError(dex, "InvalidAmount");

        await expect(dex.connect(alice).depositBaseFor(baseA.target, 0n)).to.be.revertedWithCustomError(
            dex,
            "InvalidAmount",
        );
        await expect(dex.connect(alice).withdrawBaseFor(baseA.target, 0n)).to.be.revertedWithCustomError(
            dex,
            "InvalidAmount",
        );

        await expect(dex.connect(alice).limitBuyFor(baseA.target, 0n, u(1, 18))).to.be.revertedWithCustomError(
            dex,
            "InvalidPrice",
        );
        await expect(dex.connect(alice).limitBuyFor(baseA.target, u(1, 18), 0n)).to.be.revertedWithCustomError(
            dex,
            "InvalidAmount",
        );

        await expect(dex.connect(alice).limitSellFor(baseA.target, 0n, u(1, 18))).to.be.revertedWithCustomError(
            dex,
            "InvalidPrice",
        );
        await expect(dex.connect(alice).limitSellFor(baseA.target, u(1, 18), 0n)).to.be.revertedWithCustomError(
            dex,
            "InvalidAmount",
        );

        await expect(dex.connect(alice).marketBuyFor(baseA.target, 0n)).to.be.revertedWithCustomError(
            dex,
            "InvalidAmount",
        );
        await expect(dex.connect(alice).marketSellFor(baseA.target, 0n)).to.be.revertedWithCustomError(
            dex,
            "InvalidAmount",
        );

        // Insufficient balances
        await expect(dex.connect(alice).withdrawQuote(1n)).to.be.revertedWithCustomError(dex, "InsufficientBalance");
        await expect(dex.connect(alice).withdrawBaseFor(baseA.target, 1n)).to.be.revertedWithCustomError(
            dex,
            "InsufficientBalance",
        );

        await expect(dex.connect(bob).marketBuyFor(baseA.target, 1n)).to.be.revertedWithCustomError(
            dex,
            "InsufficientBalance",
        );
        await expect(dex.connect(bob).marketSellFor(baseA.target, 1n)).to.be.revertedWithCustomError(
            dex,
            "InsufficientBalance",
        );
    });

    it("enumerates supported bases", async function () {
        const { dex, baseA, baseB } = await deployFixture();

        const bases = await dex.getSupportedBases();
        expect(bases).to.deep.equal([baseA.target, baseB.target]);

        expect(await dex.supportedBasesLength()).to.equal(2n);
        expect(await dex.supportedBaseAt(0)).to.equal(baseA.target);
        expect(await dex.supportedBaseAt(1)).to.equal(baseB.target);
    });

    it("deposit/withdraw quote and base work", async function () {
        const { alice, dex, quote, baseA } = await deployFixture();

        await quote.connect(alice).approve(dex.target, u(1234, 6));
        await dex.connect(alice).depositQuote(u(1234, 6));
        expect(await dex.quoteBalance(alice.address)).to.equal(u(1234, 6));

        await dex.connect(alice).withdrawQuote(u(200, 6));
        expect(await dex.quoteBalance(alice.address)).to.equal(u(1034, 6));

        await baseA.connect(alice).approve(dex.target, u(12, 18));
        await dex.connect(alice).depositBaseFor(baseA.target, u(12, 18));
        expect(await dex.baseBalance(alice.address, baseA.target)).to.equal(u(12, 18));

        await dex.connect(alice).withdrawBaseFor(baseA.target, u(5, 18));
        expect(await dex.baseBalance(alice.address, baseA.target)).to.equal(u(7, 18));
    });

    it("limit sell + limit buy match at ask price and update balances", async function () {
        const { alice, bob, dex, quote, baseA } = await deployFixture();

        // Alice deposits base to sell
        await baseA.connect(alice).approve(dex.target, u(100, 18));
        await dex.connect(alice).depositBaseFor(baseA.target, u(100, 18));

        // Bob deposits quote to buy
        await quote.connect(bob).approve(dex.target, u(1000, 6));
        await dex.connect(bob).depositQuote(u(1000, 6));

        const priceAsk = u(2, 18); // 2 quote per 1 base
        const priceBid = u(21, 17); // 2.1

        const txAsk = await dex.connect(alice).limitSellFor(baseA.target, priceAsk, u(10, 18));
        const askReceipt = await txAsk.wait();
        const askEvt = findEventArgs(askReceipt, dex, "LimitOrderPlaced");
        expect(askEvt).to.not.equal(null);

        const txBid = await dex.connect(bob).limitBuyFor(baseA.target, priceBid, u(5, 18));
        await txBid.wait();

        // Trade executes at ask price (per-base)
        expect(await dex.getLastPriceFor(baseA.target)).to.equal(priceAsk);

        // Bob gets 5 base
        expect(await dex.baseBalance(bob.address, baseA.target)).to.equal(u(5, 18));

        // Alice gets 10 quote (5*2)
        expect(await dex.quoteBalance(alice.address)).to.equal(u(10, 6));

        // Depth should still show 5 base remaining at ask price
        const depth = await dex.getOrderBookDepthFor(baseA.target, 5);
        expect(depth[2][0]).to.equal(priceAsk); // askPrices
        expect(depth[3][0]).to.equal(u(5, 18)); // askSizes
    });

    it("same price FIFO: earlier order is matched first", async function () {
        const { alice, bob, carol, dex, quote, baseA } = await deployFixture();

        // Alice & Bob deposit base to sell
        await baseA.connect(alice).approve(dex.target, u(10, 18));
        await dex.connect(alice).depositBaseFor(baseA.target, u(10, 18));
        await baseA.connect(bob).approve(dex.target, u(10, 18));
        await dex.connect(bob).depositBaseFor(baseA.target, u(10, 18));

        // Carol deposits quote to buy
        await quote.connect(carol).approve(dex.target, u(1000, 6));
        await dex.connect(carol).depositQuote(u(1000, 6));

        const price = u(2, 18);

        const tx1 = await dex.connect(alice).limitSellFor(baseA.target, price, u(5, 18));
        const r1 = await tx1.wait();
        const e1 = findEventArgs(r1, dex, "LimitOrderPlaced");
        const aliceOrderId = e1.orderId;

        const tx2 = await dex.connect(bob).limitSellFor(baseA.target, price, u(5, 18));
        const r2 = await tx2.wait();
        const e2 = findEventArgs(r2, dex, "LimitOrderPlaced");
        const bobOrderId = e2.orderId;

        // Market buy 6 base (spend max 12 quote) => should fill Alice 5 first then Bob 1
        await dex.connect(carol).marketBuyFor(baseA.target, u(12, 6));

        // Carol received 6 base
        expect(await dex.baseBalance(carol.address, baseA.target)).to.equal(u(6, 18));

        // Order statuses
        const aliceOrder = await dex.orders(aliceOrderId);
        const bobOrder = await dex.orders(bobOrderId);

        expect(aliceOrder.filledBase).to.equal(u(5, 18));
        expect(aliceOrder.active).to.equal(false); // filled removed

        expect(bobOrder.filledBase).to.equal(u(1, 18));
        expect(bobOrder.active).to.equal(true);
    });

    it("cancel buy refunds remaining lockedQuote; cancel sell refunds remaining base", async function () {
        const { alice, dex, quote, baseA } = await deployFixture();

        await quote.connect(alice).approve(dex.target, u(100, 6));
        await dex.connect(alice).depositQuote(u(100, 6));

        const priceBid = u(2, 18);
        const amountBase = u(10, 18);

        const before = await dex.quoteBalance(alice.address);
        const tx = await dex.connect(alice).limitBuyFor(baseA.target, priceBid, amountBase);
        const receipt = await tx.wait();
        const evt = findEventArgs(receipt, dex, "LimitOrderPlaced");
        const orderId = evt.orderId;

        const mid = await dex.quoteBalance(alice.address);
        expect(mid).to.be.lt(before);

        await dex.connect(alice).cancelOrder(orderId);
        const after = await dex.quoteBalance(alice.address);
        expect(after).to.equal(before);

        // sell cancel refunds base
        await baseA.connect(alice).approve(dex.target, u(10, 18));
        await dex.connect(alice).depositBaseFor(baseA.target, u(10, 18));

        const baseBefore = await dex.baseBalance(alice.address, baseA.target);
        const txS = await dex.connect(alice).limitSellFor(baseA.target, u(3, 18), u(4, 18));
        const rS = await txS.wait();
        const eS = findEventArgs(rS, dex, "LimitOrderPlaced");
        const sellId = eS.orderId;

        const baseMid = await dex.baseBalance(alice.address, baseA.target);
        expect(baseMid).to.equal(baseBefore - u(4, 18));

        await dex.connect(alice).cancelOrder(sellId);
        const baseAfter = await dex.baseBalance(alice.address, baseA.target);
        expect(baseAfter).to.equal(baseBefore);
    });

    it("cancel reverts for wrong owner and for inactive orders", async function () {
        const { alice, bob, dex, quote, baseA } = await deployFixture();

        await quote.connect(alice).approve(dex.target, u(10, 6));
        await dex.connect(alice).depositQuote(u(10, 6));

        const tx = await dex.connect(alice).limitBuyFor(baseA.target, u(2, 18), u(1, 18));
        const receipt = await tx.wait();
        const evt = findEventArgs(receipt, dex, "LimitOrderPlaced");
        const orderId = evt.orderId;

        await expect(dex.connect(bob).cancelOrder(orderId)).to.be.revertedWithCustomError(dex, "NotOwner");

        await dex.connect(alice).cancelOrder(orderId);
        await expect(dex.connect(alice).cancelOrder(orderId)).to.be.revertedWithCustomError(dex, "NotActive");
    });

    it("bid/ask levels are sorted; best prices update after cancels", async function () {
        const { alice, bob, dex, quote, baseA } = await deployFixture();

        // prep balances
        await quote.connect(alice).approve(dex.target, u(1000, 6));
        await dex.connect(alice).depositQuote(u(1000, 6));
        await baseA.connect(bob).approve(dex.target, u(100, 18));
        await dex.connect(bob).depositBaseFor(baseA.target, u(100, 18));

        // Keep bids strictly below asks to avoid matching in this test.
        const bidP1 = u(1, 18);
        const bidP2 = u(11, 17); // 1.1
        const bidP3 = u(9, 17); // 0.9

        // create three bid levels (no asks so no matching)
        const b1 = await (await dex.connect(alice).limitBuyFor(baseA.target, bidP1, u(1, 18))).wait();
        const b1e = findEventArgs(b1, dex, "LimitOrderPlaced");
        const b1id = b1e.orderId;

        const b2 = await (await dex.connect(alice).limitBuyFor(baseA.target, bidP2, u(1, 18))).wait();
        const b2e = findEventArgs(b2, dex, "LimitOrderPlaced");
        const b2id = b2e.orderId;

        await (await dex.connect(alice).limitBuyFor(baseA.target, bidP3, u(1, 18))).wait();

        const depth1 = await dex.getOrderBookDepthFor(baseA.target, 5);
        expect(depth1[0][0]).to.equal(bidP2);
        expect(depth1[0][1]).to.equal(bidP1);
        expect(depth1[0][2]).to.equal(bidP3);

        // create three ask levels (still above best bid so no crossing)
        const askP1 = u(2, 18);
        const askP2 = u(18, 17); // 1.8
        const askP3 = u(25, 17); // 2.5

        await dex.connect(bob).limitSellFor(baseA.target, askP1, u(1, 18));
        const a2 = await (await dex.connect(bob).limitSellFor(baseA.target, askP2, u(1, 18))).wait();
        const a2e = findEventArgs(a2, dex, "LimitOrderPlaced");
        const a2id = a2e.orderId;
        await dex.connect(bob).limitSellFor(baseA.target, askP3, u(1, 18));

        const depth2 = await dex.getOrderBookDepthFor(baseA.target, 5);
        expect(depth2[2][0]).to.equal(askP2);
        expect(depth2[2][1]).to.equal(askP1);
        expect(depth2[2][2]).to.equal(askP3);

        // cancel current best bid (bidP2), best should move to bidP1
        await dex.connect(alice).cancelOrder(b2id);
        const depth3 = await dex.getOrderBookDepthFor(baseA.target, 5);
        expect(depth3[0][0]).to.equal(bidP1);

        // cancel current best ask (askP2), best should move to askP1
        await dex.connect(bob).cancelOrder(a2id);
        const depth4 = await dex.getOrderBookDepthFor(baseA.target, 5);
        expect(depth4[2][0]).to.equal(askP1);

        // cancel remaining best bid too, ensure depth updates (no assumption about other bids)
        await dex.connect(alice).cancelOrder(b1id);
    });

    it("price improvement refunds unused lockedQuote when bid is fully filled", async function () {
        const { alice, bob, dex, quote, baseA } = await deployFixture();

        // Alice deposits quote and places a bid @ 3.0
        await quote.connect(alice).approve(dex.target, u(10, 6));
        await dex.connect(alice).depositQuote(u(10, 6));
        const before = await dex.quoteBalance(alice.address);

        const bidPrice = u(3, 18);
        const askPrice = u(2, 18);
        const amount = u(1, 18);

        await (await dex.connect(alice).limitBuyFor(baseA.target, bidPrice, amount)).wait();
        const afterLock = await dex.quoteBalance(alice.address);
        expect(afterLock).to.equal(before - u(3, 6));

        // Bob deposits base and sells @ 2.0, should match at 2.0 and refund 1.0 quote
        await baseA.connect(bob).approve(dex.target, u(10, 18));
        await dex.connect(bob).depositBaseFor(baseA.target, u(10, 18));
        await (await dex.connect(bob).limitSellFor(baseA.target, askPrice, amount)).wait();

        const afterTrade = await dex.quoteBalance(alice.address);
        expect(afterTrade).to.equal(before - u(2, 6));

        expect(await dex.baseBalance(alice.address, baseA.target)).to.equal(amount);
        expect(await dex.getLastPriceFor(baseA.target)).to.equal(askPrice);
    });

    it("marketBuy does not spend quote if it cannot afford 1 base unit at best ask", async function () {
        const { alice, bob, dex, quote, baseA } = await deployFixture();

        // Bob posts an ask with a very high price
        await baseA.connect(bob).approve(dex.target, u(1, 18));
        await dex.connect(bob).depositBaseFor(baseA.target, u(1, 18));
        // Price high enough so baseForQuote(1, price) == 0 with quoteDecimals=6 and baseDecimals=18.
        await dex.connect(bob).limitSellFor(baseA.target, u("10000000000000", 18), u(1, 18));

        // Alice has only 1 micro-quote
        await quote.connect(alice).approve(dex.target, 1n);
        await dex.connect(alice).depositQuote(1n);
        const qBefore = await dex.quoteBalance(alice.address);

        await dex.connect(alice).marketBuyFor(baseA.target, 1n);
        const qAfter = await dex.quoteBalance(alice.address);

        expect(qAfter).to.equal(qBefore);
        expect(await dex.baseBalance(alice.address, baseA.target)).to.equal(0n);
    });

    it("getOrderBookDepthFor defaults topN=10 when passed 0", async function () {
        const { dex, baseA } = await deployFixture();
        const depth = await dex.getOrderBookDepthFor(baseA.target, 0);
        expect(depth[0].length).to.equal(10);
        expect(depth[1].length).to.equal(10);
        expect(depth[2].length).to.equal(10);
        expect(depth[3].length).to.equal(10);
    });

    it("works with different base decimals (8) for quote/base conversions", async function () {
        const { alice, bob, dex, quote, baseB } = await deployFixture();

        // Bob sells 1.0 baseB (8 decimals) at 30000 quote
        await baseB.connect(bob).approve(dex.target, u(2, 8));
        await dex.connect(bob).depositBaseFor(baseB.target, u(2, 8));
        await dex.connect(bob).limitSellFor(baseB.target, u(30000, 18), u(1, 8));

        // Alice buys with exactly 30000 quote
        await quote.connect(alice).approve(dex.target, u(30000, 6));
        await dex.connect(alice).depositQuote(u(30000, 6));

        await dex.connect(alice).marketBuyFor(baseB.target, u(30000, 6));
        expect(await dex.baseBalance(alice.address, baseB.target)).to.equal(u(1, 8));
        expect(await dex.quoteBalance(alice.address)).to.equal(0n);
    });

    it("depth aggregation groups by price and is isolated per base", async function () {
        const { alice, dex, baseA, baseB } = await deployFixture();

        // deposit bases
        await baseA.connect(alice).approve(dex.target, u(100, 18));
        await dex.connect(alice).depositBaseFor(baseA.target, u(100, 18));

        await baseB.connect(alice).approve(dex.target, u(5, 8));
        await dex.connect(alice).depositBaseFor(baseB.target, u(5, 8));

        // baseA: two asks at same price and one at different
        const p1 = u(2, 18);
        const p2 = u(25, 17); // 2.5

        await dex.connect(alice).limitSellFor(baseA.target, p1, u(10, 18));
        await dex.connect(alice).limitSellFor(baseA.target, p1, u(5, 18));
        await dex.connect(alice).limitSellFor(baseA.target, p2, u(1, 18));

        const depthA = await dex.getOrderBookDepthFor(baseA.target, 5);
        expect(depthA[2][0]).to.equal(p1);
        expect(depthA[3][0]).to.equal(u(15, 18));
        expect(depthA[2][1]).to.equal(p2);
        expect(depthA[3][1]).to.equal(u(1, 18));

        // baseB: separate book should be empty until orders placed
        const depthB0 = await dex.getOrderBookDepthFor(baseB.target, 5);
        expect(depthB0[2][0]).to.equal(0n);
        expect(depthB0[3][0]).to.equal(0n);

        await dex.connect(alice).limitSellFor(baseB.target, u(30000, 18), u(1, 8));
        const depthB1 = await dex.getOrderBookDepthFor(baseB.target, 5);
        expect(depthB1[2][0]).to.equal(u(30000, 18));
        expect(depthB1[3][0]).to.equal(u(1, 8));
    });

    it("open orders view excludes filled and cancelled orders", async function () {
        const { alice, bob, dex, quote, baseA } = await deployFixture();

        // Seller deposits base and posts sell 2
        await baseA.connect(alice).approve(dex.target, u(10, 18));
        await dex.connect(alice).depositBaseFor(baseA.target, u(10, 18));
        const sellTx = await dex.connect(alice).limitSellFor(baseA.target, u(2, 18), u(2, 18));
        const sellRc = await sellTx.wait();
        const sellEvt = findEventArgs(sellRc, dex, "LimitOrderPlaced");
        const sellId = sellEvt.orderId;

        // Buyer deposits quote and buys 1 via limit buy (crosses)
        await quote.connect(bob).approve(dex.target, u(100, 6));
        await dex.connect(bob).depositQuote(u(100, 6));
        await dex.connect(bob).limitBuyFor(baseA.target, u(3, 18), u(1, 18));

        // Seller has 1 remaining open
        const openSeller = await dex.getOpenOrdersOfFor(alice.address, baseA.target);
        expect(openSeller.length).to.equal(1);
        expect(openSeller[0].id).to.equal(sellId);
        expect(openSeller[0].remainingBase).to.equal(u(1, 18));

        // Cancel and ensure it's gone
        await dex.connect(alice).cancelOrder(sellId);
        const openSeller2 = await dex.getOpenOrdersOfFor(alice.address, baseA.target);
        expect(openSeller2.length).to.equal(0);
    });
});
