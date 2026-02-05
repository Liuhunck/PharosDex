const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("SinglePairOrderBookDEX", function () {
  let owner, alice, bob;
  let doge, usdt, dex;

  const PRICE_SCALE = ethers.parseUnits("1", 18);

  beforeEach(async function () {
    [owner, alice, bob] = await ethers.getSigners();

    // 1️⃣ Deploy MockERC20
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    doge = await MockERC20.deploy("DOGE", "DOGE", 18);
    usdt = await MockERC20.deploy("USDT", "USDT", 6);

    // 2️⃣ Deploy DEX
    const DEX = await ethers.getContractFactory("SinglePairOrderBookDEX");
    dex = await DEX.deploy(doge.target, usdt.target);

    // 3️⃣ Mint tokens
    await doge.mint(alice.address, ethers.parseUnits("1000", 18));
    await usdt.mint(alice.address, ethers.parseUnits("1000", 6));

    await doge.mint(bob.address, ethers.parseUnits("1000", 18));
    await usdt.mint(bob.address, ethers.parseUnits("1000", 6));

    // 4️⃣ Approve
    await doge.connect(alice).approve(dex.target, ethers.MaxUint256);
    await usdt.connect(alice).approve(dex.target, ethers.MaxUint256);

    await doge.connect(bob).approve(dex.target, ethers.MaxUint256);
    await usdt.connect(bob).approve(dex.target, ethers.MaxUint256);
  });

  it("limitBuy should place bid correctly", async function () {
    const price = ethers.parseUnits("0.1", 18); // 0.1 USDT / DOGE
    const amount = ethers.parseUnits("100", 18); // 100 DOGE

    await expect(
      dex.connect(alice).limitBuy(price, amount)
    ).to.emit(dex, "LimitOrderPlaced");

    const bidId = await dex.bidIds(0);
    const order = await dex.orders(bidId);

    expect(order.trader).to.equal(alice.address);
    expect(order.price).to.equal(price);
    expect(order.amountBase).to.equal(amount);
    expect(order.active).to.equal(true);
  });

  it("limitSell should place ask correctly", async function () {
    const price = ethers.parseUnits("0.1", 18);
    const amount = ethers.parseUnits("100", 18);

    await expect(
      dex.connect(bob).limitSell(price, amount)
    ).to.emit(dex, "LimitOrderPlaced");

    const askId = await dex.askIds(0);
    const order = await dex.orders(askId);

    expect(order.trader).to.equal(bob.address);
    expect(order.price).to.equal(price);
    expect(order.amountBase).to.equal(amount);
  });

  it("marketBuy should match against asks", async function () {
    const price = ethers.parseUnits("0.1", 18);
    const amount = ethers.parseUnits("100", 18);

    // Bob 挂卖单
    await dex.connect(bob).limitSell(price, amount);

    // Alice 市价买，最多花 20 USDT
    await expect(
      dex.connect(alice).marketBuy(ethers.parseUnits("20", 6))
    ).to.emit(dex, "Trade");

    const aliceDoge = await doge.balanceOf(alice.address);
    const bobUsdt = await usdt.balanceOf(bob.address);

    expect(aliceDoge).to.be.gt(ethers.parseUnits("1000", 18)); // 买到了 DOGE
    expect(bobUsdt).to.be.gt(ethers.parseUnits("1000", 6));    // 卖到了 USDT

    const lastPrice = await dex.getLastPrice();
    expect(lastPrice).to.equal(price);
  });

  it("marketSell should match against bids", async function () {
    const price = ethers.parseUnits("0.2", 18);
    const amount = ethers.parseUnits("50", 18);

    // Alice 挂买单
    await dex.connect(alice).limitBuy(price, amount);

    // Bob 市价卖
    await expect(
      dex.connect(bob).marketSell(ethers.parseUnits("10", 18))
    ).to.emit(dex, "Trade");

    const bobUsdt = await usdt.balanceOf(bob.address);
    expect(bobUsdt).to.be.gt(ethers.parseUnits("1000", 6));
  });

  it("cancelOrder should refund remaining funds", async function () {
    const price = ethers.parseUnits("0.1", 18);
    const amount = ethers.parseUnits("100", 18);

    await dex.connect(alice).limitBuy(price, amount);

    const bidId = await dex.bidIds(0);

    const before = await usdt.balanceOf(alice.address);
    await dex.connect(alice).cancelOrder(bidId);
    const after = await usdt.balanceOf(alice.address);

    expect(after).to.be.gt(before);
  });

  it("should revert on invalid amount", async function () {
    await expect(
      dex.connect(alice).limitBuy(0, 0)
    ).to.be.revertedWithCustomError(dex, "InvalidPrice");
  });

  it("getOrderBookDepth returns correct depth", async function () {
    const price = ethers.parseUnits("0.1", 18);
    const amount = ethers.parseUnits("100", 18);

    await dex.connect(alice).limitBuy(price, amount);

    const [bp, bs, ap, as] = await dex.getOrderBookDepth(5);

    expect(bp[0]).to.equal(price);
    expect(bs[0]).to.equal(amount);
    expect(ap[0]).to.equal(0);
  });
});
