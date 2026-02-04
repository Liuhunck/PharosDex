const { expect } = require("chai");

describe("MemeHubToken", function () {
    async function deployFixture() {
        const [owner, other] = await ethers.getSigners();

        const Token = await ethers.getContractFactory("MemeHubToken");
        const initialSupply = ethers.parseUnits("1000000", 18);
        const token = await Token.deploy("MemeHub", "MEH", initialSupply);

        return { token, owner, other, initialSupply };
    }

    it("mints initial supply to deployer", async function () {
        const { token, owner, initialSupply } = await deployFixture();

        expect(await token.totalSupply()).to.equal(initialSupply);
        expect(await token.balanceOf(owner.address)).to.equal(initialSupply);
    });

    it("transfers tokens", async function () {
        const { token, owner, other } = await deployFixture();

        await expect(token.transfer(other.address, 123n))
            .to.emit(token, "Transfer")
            .withArgs(owner.address, other.address, 123n);

        expect(await token.balanceOf(other.address)).to.equal(123n);
    });

    it("allows only owner to mint", async function () {
        const { token, other } = await deployFixture();

        await expect(token.connect(other).mint(other.address, 1n)).to.be.reverted;
    });

    it("owner can mint", async function () {
        const { token, other } = await deployFixture();

        await token.mint(other.address, 500n);
        expect(await token.balanceOf(other.address)).to.equal(500n);
    });
});
