const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("TokenFactory integration", function () {
  async function deployFixture() {
    const [owner, creator] = await ethers.getSigners();

    const Factory = await ethers.getContractFactory("TokenFactory");
    const factory = await Factory.deploy();
    await factory.waitForDeployment();

    const MockAggregator = await ethers.getContractFactory("MockV3Aggregator");
    const aggregator = await MockAggregator.deploy(8, 300e8);
    await aggregator.waitForDeployment();

    const Deployer = await ethers.getContractFactory("BondingCurveDeployer");
    const curveDeployer = await Deployer.deploy(await factory.getAddress());
    await curveDeployer.waitForDeployment();

    await factory.setCurveDeployer(await curveDeployer.getAddress());
    await factory.setRaiseAllowedToken(ethers.ZeroAddress, true);
    await factory.setTokenAggregator(ethers.ZeroAddress, await aggregator.getAddress());

    return { factory, owner, creator };
  }

  async function createToken(factory, creator, symbol = "RAVI") {
    const creationFee = await factory.creationFee();
    // Keep target high in local tests to avoid triggering DEX listing path
    // that depends on real Pancake router addresses.
    const targetValue = ethers.parseEther("1000000");

    const tx = await factory.connect(creator).createToken(
      "Ravi Meme",
      symbol,
      "demo token",
      "https://example.com/image.png",
      "https://x.com/ravi",
      "https://t.me/ravi",
      "https://ravi.example",
      targetValue,
      ethers.ZeroAddress,
      { value: creationFee }
    );
    const receipt = await tx.wait();

    const tokenCreatedLog = receipt.logs
      .map((log) => {
        try {
          return factory.interface.parseLog(log);
        } catch (e) {
          return null;
        }
      })
      .find((parsed) => parsed && parsed.name === "TokenCreated");

    return tokenCreatedLog.args.tokenAddress;
  }

  it("creates token and stores token metadata", async function () {
    const { factory, creator } = await deployFixture();
    const tokenAddress = await createToken(factory, creator, "RV1");

    const info = await factory.getTokenInfo(tokenAddress);
    expect(info.tokenAddress).to.equal(tokenAddress);
    expect(info.creator).to.equal(creator.address);
    expect(info.symbol).to.equal("RV1");
    expect(info.raiseToken).to.equal(ethers.ZeroAddress);
  });

  it("reverts when creation fee is missing", async function () {
    const { factory, creator } = await deployFixture();

    await expect(
      factory.connect(creator).createToken(
        "Ravi Meme",
        "RV2",
        "demo token",
        "https://example.com/image.png",
        "https://x.com/ravi",
        "https://t.me/ravi",
        "https://ravi.example",
        ethers.parseEther("2"),
        ethers.ZeroAddress,
        { value: 0 }
      )
    ).to.be.revertedWith("Insufficient creation fee");
  });

  it("allows native buy and sell through factory", async function () {
    const { factory, creator } = await deployFixture();
    const tokenAddress = await createToken(factory, creator, "RV3");

    const buyValue = ethers.parseEther("0.1");
    await factory.connect(creator)["buyToken(address,uint256)"](tokenAddress, 0, { value: buyValue });

    const info = await factory.getTokenInfo(tokenAddress);
    const token = await ethers.getContractAt("Token", tokenAddress);
    const userBalance = await token.balanceOf(creator.address);
    expect(userBalance).to.be.gt(0);

    const sellAmount = userBalance / 2n;
    await token.connect(creator).approve(info.bondingCurve, sellAmount);
    await expect(factory.connect(creator).sellToken(tokenAddress, sellAmount, 0)).to.not.be.reverted;

    const curveBalanceAfter = await token.balanceOf(info.bondingCurve);
    expect(curveBalanceAfter).to.be.gt(0);
  });

  it("keeps virtual constant-product invariant across buy and sell", async function () {
    const { factory, creator } = await deployFixture();
    const tokenAddress = await createToken(factory, creator, "RV4");
    const info = await factory.getTokenInfo(tokenAddress);
    const curve = await ethers.getContractAt("BondingCurve", info.bondingCurve);
    const token = await ethers.getContractAt("Token", tokenAddress);

    const curveK = await curve.curveK();
    const initialVirtualRaise = await curve.initialVirtualRaise();

    const buyAmount = ethers.parseEther("0.2");
    await factory.connect(creator)["buyToken(address,uint256)"](tokenAddress, 0, { value: buyAmount });

    const totalTokenInAfterBuy = await curve.totalTokenIn();
    const xAfterBuy = initialVirtualRaise + totalTokenInAfterBuy;
    // _virtualToken is private; recompute exactly as contract does: y = floor(k / x)
    const yAfterBuyRecomputed = curveK / xAfterBuy;
    expect(xAfterBuy * yAfterBuyRecomputed).to.be.lte(curveK);
    expect(curveK - xAfterBuy * yAfterBuyRecomputed).to.be.lt(xAfterBuy);

    const userBalance = await token.balanceOf(creator.address);
    const sellAmount = userBalance / 3n;
    await token.connect(creator).approve(info.bondingCurve, sellAmount);
    await factory.connect(creator).sellToken(tokenAddress, sellAmount, 0);

    const totalTokenInAfterSell = await curve.totalTokenIn();
    const xAfterSell = initialVirtualRaise + totalTokenInAfterSell;
    const yAfterSellRecomputed = curveK / xAfterSell;
    expect(xAfterSell * yAfterSellRecomputed).to.be.lte(curveK);
    expect(curveK - xAfterSell * yAfterSellRecomputed).to.be.lt(xAfterSell);
  });
});
