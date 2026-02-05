const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SinglePairOrderBookDEX (Route B decimals-aware + open orders view)", function () {
  let owner, alice, bob;
  let doge, usdt, dex;

  const toWei = (v) => ethers.parseUnits(v, 18); // DOGE 18
  const toUsdt = (v) => ethers.parseUnits(v, 6); // USDT 6
  const toPrice = (v) => ethers.parseUnits(v, 18); // price scaled by 1e18

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    doge = await MockERC20.deploy("Mock DOGE", "DOGE", 18);
    usdt = await MockERC20.deploy("Mock USDT", "USDT", 6);

    const DEX = await ethers.getContractFactory("SinglePairOrderBookDEX");
    dex = await DEX.deploy(doge.target, usdt.target);

    // mint balances
    await doge.mint(alice.address, toWei("1000"));
    await usdt.mint(alice.address, toUsdt("1000"));

    await doge.mint(bob.address, toWei("1000"));
    await usdt.mint(bob.address, toUsdt("1000"));

    // approvals
    await doge.connect(alice).approve(dex.target, ethers.MaxUint256);
    await usdt.connect(alice).approve(dex.target, ethers.MaxUint256);

    await doge.connect(bob).approve(dex.target, ethers.MaxUint256);
    await usdt.connect(bob).approve(dex.target, ethers.MaxUint256);
  });

  it("constructor caches decimals correctly", async function () {
    expect(await dex.baseDecimals()).to.equal(18);
    expect(await dex.quoteDecimals()).to.equal(6);
  });

  it("limitBuy locks correct USDT amount with decimals (100 DOGE @ 0.1 USDT/DOGE => 10 USDT)", async function () {
    const price = toPrice("0.1");
    const amount = toWei("100");

    const beforeUsdt = await usdt.balanceOf(alice.address);

    await expect(dex.connect(alice).limitBuy(price, amount))
      .to.emit(dex, "LimitOrderPlaced");

    const afterUsdt = await usdt.balanceOf(alice.address);

    // 10 USDT should be locked
    expect(beforeUsdt - afterUsdt).to.equal(toUsdt("10"));

    // order data
    const bidId = await dex.bidIds(0);
    const order = await dex.orders(bidId);

    expect(order.trader).to.equal(alice.address);
    expect(order.side).to.equal(0); // BUY enum: 0
    expect(order.price).to.equal(price);
    expect(order.amountBase).to.equal(amount);
    expect(order.filledBase).to.equal(0);
    expect(order.active).to.equal(true);
  });

  it("limitSell locks DOGE and places ask correctly", async function () {
    const price = toPrice("0.2");
    const amount = toWei("50");

    const beforeDoge = await doge.balanceOf(bob.address);

    await expect(dex.connect(bob).limitSell(price, amount))
      .to.emit(dex, "LimitOrderPlaced");

    const afterDoge = await doge.balanceOf(bob.address);

    expect(beforeDoge - afterDoge).to.equal(amount);

    const askId = await dex.askIds(0);
    const order = await dex.orders(askId);

    expect(order.trader).to.equal(bob.address);
    expect(order.side).to.equal(1); // SELL enum: 1
    expect(order.price).to.equal(price);
    expect(order.amountBase).to.equal(amount);
    expect(order.active).to.equal(true);
  });

  it("marketBuy matches against asks, updates balances and last price", async function () {
    // Bob posts ask at 0.1, 100 DOGE
    const askPrice = toPrice("0.1");
    const askAmount = toWei("100");
    await dex.connect(bob).limitSell(askPrice, askAmount);

    // Alice market buys with up to 20 USDT
    const aliceDogeBefore = await doge.balanceOf(alice.address);
    const bobUsdtBefore = await usdt.balanceOf(bob.address);

    await expect(dex.connect(alice).marketBuy(toUsdt("20")))
      .to.emit(dex, "Trade");

    const aliceDogeAfter = await doge.balanceOf(alice.address);
    const bobUsdtAfter = await usdt.balanceOf(bob.address);

    // At 0.1, 20 USDT can buy up to 200 DOGE, but order has 100 DOGE => buy 100
    expect(aliceDogeAfter - aliceDogeBefore).to.equal(toWei("100"));
    expect(bobUsdtAfter - bobUsdtBefore).to.equal(toUsdt("10"));

    expect(await dex.getLastPrice()).to.equal(askPrice);
  });

  it("marketSell matches against bids, updates balances and last price", async function () {
    // Alice posts bid at 0.2 for 50 DOGE (locks 10 USDT)
    const bidPrice = toPrice("0.2");
    const bidAmount = toWei("50");
    await dex.connect(alice).limitBuy(bidPrice, bidAmount);

    // Bob market sells 10 DOGE
    const bobUsdtBefore = await usdt.balanceOf(bob.address);
    const bobDogeBefore = await doge.balanceOf(bob.address);

    await expect(dex.connect(bob).marketSell(toWei("10")))
      .to.emit(dex, "Trade");

    const bobUsdtAfter = await usdt.balanceOf(bob.address);
    const bobDogeAfter = await doge.balanceOf(bob.address);

    // 10 DOGE at 0.2 => 2 USDT
    expect(bobDogeBefore - bobDogeAfter).to.equal(toWei("10"));
    expect(bobUsdtAfter - bobUsdtBefore).to.equal(toUsdt("2"));

    expect(await dex.getLastPrice()).to.equal(bidPrice);
  });

  it("cancelOrder refunds remaining quote for BUY orders (partial fill)", async function () {
    // Alice bids 50 DOGE at 0.2 => locks 10 USDT
    const bidPrice = toPrice("0.2");
    const bidAmount = toWei("50");
    await dex.connect(alice).limitBuy(bidPrice, bidAmount);

    // Bob sells 10 DOGE into the bid => Alice spends 2 USDT worth, remaining lock should be refundable
    await dex.connect(bob).marketSell(toWei("10"));

    // Find Alice's bid order id
    const bidId = await dex.bidIds(0);
    const orderBefore = await dex.orders(bidId);
    expect(orderBefore.filledBase).to.equal(toWei("10"));

    const aliceUsdtBeforeCancel = await usdt.balanceOf(alice.address);
    await expect(dex.connect(alice).cancelOrder(bidId))
      .to.emit(dex, "OrderCancelled");
    const aliceUsdtAfterCancel = await usdt.balanceOf(alice.address);

    // Remaining base = 40 DOGE => refund = 40 * 0.2 = 8 USDT
    expect(aliceUsdtAfterCancel - aliceUsdtBeforeCancel).to.equal(toUsdt("8"));
  });

  it("getOrderBookDepth returns correct top levels (only bid present)", async function () {
    // Put one bid far from ask so it won't match
    const bidPrice = toPrice("0.1");
    const bidAmount = toWei("100");
    await dex.connect(alice).limitBuy(bidPrice, bidAmount);

    const [bp, bs, ap, asz] = await dex.getOrderBookDepth(5);

    expect(bp[0]).to.equal(bidPrice);
    expect(bs[0]).to.equal(bidAmount);

    // no asks => 0
    expect(ap[0]).to.equal(0);
    expect(asz[0]).to.equal(0);
  });

  it("getMyOpenOrders returns caller's active orders (both sides)", async function () {
    // Alice posts a bid
    const bidPrice = toPrice("0.1");
    const bidAmount = toWei("100");
    await dex.connect(alice).limitBuy(bidPrice, bidAmount);

    // Alice posts an ask too (different price so no match)
    const askPrice = toPrice("0.5");
    const askAmount = toWei("20");
    await dex.connect(alice).limitSell(askPrice, askAmount);

    const myOrders = await dex.connect(alice).getMyOpenOrders();
    expect(myOrders.length).to.equal(2);

    // Sort by side for stable assertions: BUY(0) first then SELL(1)
    const sorted = [...myOrders].sort((a, b) => Number(a.side) - Number(b.side));

    // BUY order
    expect(sorted[0].side).to.equal(0);
    expect(sorted[0].price).to.equal(bidPrice);
    expect(sorted[0].amountBase).to.equal(bidAmount);
    expect(sorted[0].filledBase).to.equal(0);
    expect(sorted[0].remainingBase).to.equal(bidAmount);
    expect(sorted[0].active).to.equal(true);

    // SELL order
    expect(sorted[1].side).to.equal(1);
    expect(sorted[1].price).to.equal(askPrice);
    expect(sorted[1].amountBase).to.equal(askAmount);
    expect(sorted[1].filledBase).to.equal(0);
    expect(sorted[1].remainingBase).to.equal(askAmount);
    expect(sorted[1].active).to.equal(true);

    // Bob should have 0 open orders
    const bobOrders = await dex.connect(bob).getMyOpenOrders();
    expect(bobOrders.length).to.equal(0);
  });

  it("should revert on invalid inputs", async function () {
    await expect(dex.connect(alice).limitBuy(0, toWei("1")))
      .to.be.revertedWithCustomError(dex, "InvalidPrice");

    await expect(dex.connect(alice).limitBuy(toPrice("0.1"), 0))
      .to.be.revertedWithCustomError(dex, "InvalidAmount");

    await expect(dex.connect(alice).marketBuy(0))
      .to.be.revertedWithCustomError(dex, "InvalidAmount");

    await expect(dex.connect(alice).marketSell(0))
      .to.be.revertedWithCustomError(dex, "InvalidAmount");
  });
});
