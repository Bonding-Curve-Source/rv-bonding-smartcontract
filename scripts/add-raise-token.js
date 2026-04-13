/**
 * Owner: whitelist ERC20 raise + (tuỳ chọn) Chainlink USD feed, hoặc chỉ set feed cho native (BNB/ETH).
 *
 * Biến môi trường:
 *   RAISE_TOKEN_ADDRESS — ERC20 raise (0xabc...). Đặt 0x0 = native: chỉ gọi setTokenAggregator(0, feed), không gọi setRaiseAllowedToken.
 *   RAISE_TOKEN_ALLOWED — mặc định "true" (chỉ áp dụng ERC20)
 *   FACTORY_ADDRESS / TOKEN_FACTORY_ADDRESS — tuỳ chọn; có thể đọc deployments/<network>.json
 *   RAISE_TOKEN_USD_AGGREGATOR — Chainlink AggregatorV3 (USD). Với native (0x0) thường là BNB/USD feed testnet/mainnet.
 *
 * Ví dụ native BSC testnet:
 *   RAISE_TOKEN_ADDRESS=0x0000000000000000000000000000000000000000 \
 *   RAISE_TOKEN_USD_AGGREGATOR=0x... \
 *   npx hardhat run scripts/add-raise-token.js --network bscTestnet
 */
const fs = require("fs");
const path = require("path");
const hre = require("hardhat");

const ZERO = "0x0000000000000000000000000000000000000000";

function loadFactoryAddress(networkName) {
  const fromEnv =
    process.env.FACTORY_ADDRESS || process.env.TOKEN_FACTORY_ADDRESS;
  if (fromEnv) return fromEnv;

  const depPath = path.join(__dirname, "..", "deployments", `${networkName}.json`);
  if (fs.existsSync(depPath)) {
    const dep = JSON.parse(fs.readFileSync(depPath, "utf8"));
    const a = dep.tokenFactory || dep.memeFactory;
    if (a) return a;
  }
  return null;
}

function isZeroAddress(addr) {
  return !addr || addr.toLowerCase() === ZERO.toLowerCase();
}

async function main() {
  const networkName = hre.network.name;
  const factoryAddr = loadFactoryAddress(networkName);
  if (!factoryAddr) {
    throw new Error(
      "Thiếu FACTORY_ADDRESS (hoặc TOKEN_FACTORY_ADDRESS), hoặc file deployments/<network>.json không có tokenFactory."
    );
  }

  const raiseTokenRaw = process.env.RAISE_TOKEN_ADDRESS;
  if (!raiseTokenRaw) {
    throw new Error("Bắt buộc: RAISE_TOKEN_ADDRESS (ERC20 hoặc 0x0 cho native + feed)");
  }

  const allowed = process.env.RAISE_TOKEN_ALLOWED !== "false";
  const aggregator = (process.env.RAISE_TOKEN_USD_AGGREGATOR || "").trim();
  const isNative = isZeroAddress(raiseTokenRaw);

  const [signer] = await hre.ethers.getSigners();
  console.log(`Network: ${networkName}`);
  console.log(`Signer: ${signer.address}`);
  console.log(`TokenFactory: ${factoryAddr}`);

  const factory = await hre.ethers.getContractAt("TokenFactory", factoryAddr, signer);

  const owner = await factory.owner();
  if (owner.toLowerCase() !== signer.address.toLowerCase()) {
    throw new Error(`Signer không phải owner. Owner: ${owner}`);
  }

  const raiseToken = hre.ethers.getAddress(raiseTokenRaw);

  console.log(`setRaiseAllowedToken(${raiseToken}, ${allowed})`);
  const tx1 = await factory.setRaiseAllowedToken(raiseToken, allowed);
  console.log(`  tx: ${tx1.hash}`);
  await tx1.wait();
  console.log("  confirmed");

  if (aggregator) {
    console.log(`setTokenAggregator(${raiseToken}, ${aggregator})`);
    const tx2 = await factory.setTokenAggregator(raiseToken, aggregator);
    console.log(`  tx: ${tx2.hash}`);
    await tx2.wait();
    console.log("  confirmed");
  } else {
    console.log(
      "(Chưa set RAISE_TOKEN_USD_AGGREGATOR — createToken với raise ERC20 này sẽ revert nếu thiếu feed.)"
    );
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
