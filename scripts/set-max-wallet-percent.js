/**
 * Owner TokenFactory: cập nhật max wallet % trên một BondingCurve.
 * (Curve.owner = factory — không gọi trực tiếp BondingCurve.setMaxWalletPercent từ EOA.)
 *
 * Biến môi trường:
 *   BONDING_CURVE_ADDRESS — địa chỉ curve (bắt buộc)
 *   MAX_WALLET_PERCENT — basis points: 10000 = 100% ví, 5000 = 50% (bắt buộc)
 *
 * Tuỳ chọn (nếu không set sẽ đọc giá trị hiện tại trên curve rồi giữ nguyên):
 *   MAX_BUY_AMOUNT_RAW — uint256 raw (wei / smallest unit raise)
 *   MAX_SELL_PERCENT — basis points (ví dụ 500 = 5%)
 *
 *   FACTORY_ADDRESS / TOKEN_FACTORY_ADDRESS — hoặc deployments/<network>.json
 *
 * Ví dụ (BSC testnet, chỉ đổi wallet cap lên 100%):
 *   BONDING_CURVE_ADDRESS=0x... MAX_WALLET_PERCENT=10000 npx hardhat run scripts/set-max-wallet-percent.js --network bscTestnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const factoryAbi = [
  "function owner() view returns (address)",
  "function setBondingCurveLimits(address bondingCurve, uint256 maxBuyAmount, uint256 maxSellPercent, uint256 maxWalletPercent)",
];

const curveAbi = [
  "function maxBuyAmount() view returns (uint256)",
  "function maxSellPercent() view returns (uint256)",
];

function loadFactoryAddress(networkName) {
  const fromEnv =
    process.env.FACTORY_ADDRESS || process.env.TOKEN_FACTORY_ADDRESS;
  if (fromEnv) return fromEnv;

  const depPath = path.join(
    __dirname,
    "..",
    "deployments",
    `${networkName}.json`,
  );
  if (fs.existsSync(depPath)) {
    const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
    const a = dep.tokenFactory || dep.memeFactory;
    if (a) return a;
  }
  return null;
}

function reqEnv(name) {
  const v = process.env[name];
  if (!v || !String(v).trim()) {
    throw new Error(`Missing required env: ${name}`);
  }
  return String(v).trim();
}

async function main() {
  const networkName = hre.network.name;
  const factoryAddr = loadFactoryAddress(networkName);
  if (!factoryAddr) {
    throw new Error(
      "Set FACTORY_ADDRESS or TOKEN_FACTORY_ADDRESS, or deployments/<network>.json with tokenFactory.",
    );
  }

  const curveAddr = reqEnv("BONDING_CURVE_ADDRESS");
  const maxWalletStr = reqEnv("MAX_WALLET_PERCENT");
  const maxWalletPercent = BigInt(maxWalletStr);

  if (maxWalletPercent <= 0n || maxWalletPercent > 10000n) {
    throw new Error(
      "MAX_WALLET_PERCENT must be 1..10000 (basis points; 10000 = 100% of totalTokenSupply per wallet).",
    );
  }

  const [signer] = await hre.ethers.getSigners();
  console.log(`Network: ${networkName}`);
  console.log(`Signer: ${signer.address}`);

  const factory = new hre.ethers.Contract(factoryAddr, factoryAbi, signer);
  const owner = await factory.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer is not TokenFactory owner. Owner: ${owner}`);
  }

  const curve = new hre.ethers.Contract(curveAddr, curveAbi, signer);
  let maxBuyAmount = await curve.maxBuyAmount();
  let maxSellPercent = await curve.maxSellPercent();

  if (process.env.MAX_BUY_AMOUNT_RAW !== undefined) {
    maxBuyAmount = BigInt(process.env.MAX_BUY_AMOUNT_RAW.trim());
  }
  if (process.env.MAX_SELL_PERCENT !== undefined) {
    maxSellPercent = BigInt(process.env.MAX_SELL_PERCENT.trim());
  }

  console.log(`TokenFactory: ${factoryAddr}`);
  console.log(`BondingCurve: ${curveAddr}`);
  console.log(`maxBuyAmount (raw):   ${maxBuyAmount.toString()}`);
  console.log(`maxSellPercent (bps): ${maxSellPercent.toString()}`);
  console.log(`maxWalletPercent (bps): ${maxWalletPercent.toString()}`);

  const tx = await factory.setBondingCurveLimits(
    curveAddr,
    maxBuyAmount,
    maxSellPercent,
    maxWalletPercent,
  );
  console.log(`tx: ${tx.hash}`);
  await tx.wait();
  console.log("confirmed");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
