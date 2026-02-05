const { expect } = require("chai");

describe("PharosSpotMarket", function () {
    async function deployFixture() {
        const [deployer, alice, bob] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("MemeHubToken");
        const base = await Token.deploy("Base", "BASE", ethers.parseUnits("1000000", 18));
        const quote = await Token.deploy("Quote", "QUOTE", ethers.parseUnits("1000000", 18));

        // Give alice/bob some tokens
        await base.mint(alice.address, ethers.parseUnits("1000", 18));
        await base.mint(bob.address, ethers.parseUnits("1000", 18));
        await quote.mint(alice.address, ethers.parseUnits("10000", 18));
        await quote.mint(bob.address, ethers.parseUnits("10000", 18));

        const Market = await ethers.getContractFactory("PharosSpotMarket");
        const market = await Market.deploy(base.target, quote.target);

        return { deployer, alice, bob, base, quote, market };
    }

    it("deposit/withdraw works", async function () {
        const { alice, base, market } = await deployFixture();

        await base.connect(alice).approve(market.target, ethers.parseUnits("10", 18));
        await market.connect(alice).deposit(base.target, ethers.parseUnits("10", 18));

        expect(await market.balances(base.target, alice.address)).to.equal(ethers.parseUnits("10", 18));

        await market.connect(alice).withdraw(base.target, ethers.parseUnits("3", 18));
        expect(await market.balances(base.target, alice.address)).to.equal(ethers.parseUnits("7", 18));
    });

    it("limit orders match and update last trade price", async function () {
        const { alice, bob, base, quote, market } = await deployFixture();

        // Alice deposits base to sell
        await base.connect(alice).approve(market.target, ethers.parseUnits("200", 18));
        await market.connect(alice).deposit(base.target, ethers.parseUnits("200", 18));

        // Bob deposits quote to buy
        await quote.connect(bob).approve(market.target, ethers.parseUnits("1000", 18));
        await market.connect(bob).deposit(quote.target, ethers.parseUnits("1000", 18));

        const priceAsk = ethers.parseUnits("2", 18); // 2 quote per 1 base
        const priceBid = ethers.parseUnits("2.1", 18);

        // Alice posts ask 100 base @ 2
        const tx1 = await market.connect(alice).placeLimitOrder(
            1, // Sell
            priceAsk,
            ethers.parseUnits("100", 18),
            0,
            0,
            false,
            0, // maxMatches=0: just post
        );
        await tx1.wait();

        // Depth shows ask
        const depth1 = await market.getDepth(5);
        expect(depth1.askPrices[0]).to.equal(priceAsk);
        expect(depth1.askBaseTotals[0]).to.equal(ethers.parseUnits("100", 18));

        // Bob places bid 50 base @ 2.1 and matches immediately
        const tx2 = await market.connect(bob).placeLimitOrder(
            0, // Buy
            priceBid,
            ethers.parseUnits("50", 18),
            0,
            0,
            false,
            10,
        );
        await tx2.wait();

        // Last trade price should be maker ask (2)
        expect(await market.lastTradePriceE18()).to.equal(priceAsk);

        // Bob should receive 50 base
        expect(await market.balances(base.target, bob.address)).to.equal(ethers.parseUnits("50", 18));

        // Alice should receive 100 quote (50*2)
        expect(await market.balances(quote.target, alice.address)).to.equal(ethers.parseUnits("100", 18));

        // Ask remaining should be 50 base
        const depth2 = await market.getDepth(5);
        expect(depth2.askPrices[0]).to.equal(priceAsk);
        expect(depth2.askBaseTotals[0]).to.equal(ethers.parseUnits("50", 18));
    });

    it("cancel refunds remaining reserve", async function () {
        const { alice, base, quote, market } = await deployFixture();

        await quote.connect(alice).approve(market.target, ethers.parseUnits("1000", 18));
        await market.connect(alice).deposit(quote.target, ethers.parseUnits("1000", 18));

        const priceBid = ethers.parseUnits("1", 18);
        const amountBase = ethers.parseUnits("10", 18);

        // place buy limit and post (no matching)
        const tx = await market.connect(alice).placeLimitOrder(0, priceBid, amountBase, 0, 0, true, 0);
        const receipt = await tx.wait();

        // orderId is first in this test run: 1
        const orderId = 1n;

        const balBefore = await market.balances(quote.target, alice.address);
        await market.connect(alice).cancelOrder(orderId);
        const balAfter = await market.balances(quote.target, alice.address);

        expect(balAfter).to.be.gt(balBefore);
    });

    it("market buy uses maxQuoteIn and refunds remainder", async function () {
        const { alice, bob, base, quote, market } = await deployFixture();

        // Alice posts ask 10 base @ 2
        await base.connect(alice).approve(market.target, ethers.parseUnits("10", 18));
        await market.connect(alice).deposit(base.target, ethers.parseUnits("10", 18));
        const priceAsk = ethers.parseUnits("2", 18);
        await market.connect(alice).placeLimitOrder(1, priceAsk, ethers.parseUnits("10", 18), 0, 0, false, 0);

        // Bob deposits quote
        await quote.connect(bob).approve(market.target, ethers.parseUnits("100", 18));
        await market.connect(bob).deposit(quote.target, ethers.parseUnits("100", 18));

        const quoteBefore = await market.balances(quote.target, bob.address);

        // Market buy up to 10 base, spend at most 25 quote
        const tx = await market
            .connect(bob)
            .placeMarketOrder(0, ethers.parseUnits("10", 18), ethers.parseUnits("25", 18), 0, 32);
        await tx.wait();

        // Should have 10 base
        expect(await market.balances(base.target, bob.address)).to.equal(ethers.parseUnits("10", 18));

        // Actually spent 20 quote, so remaining quote in vault should be quoteBefore - 20
        const quoteAfter = await market.balances(quote.target, bob.address);
        expect(quoteAfter).to.equal(quoteBefore - ethers.parseUnits("20", 18));
    });
});
