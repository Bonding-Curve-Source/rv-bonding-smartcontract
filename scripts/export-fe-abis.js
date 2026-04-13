/**
 * Đồng bộ ABI từ artifacts → fe-bonding/src/abis (chạy sau `npx hardhat compile`).
 */
const fs = require("fs");
const path = require("path");

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function writeAbiTs(filePath, headerLine, exportName, abi) {
  ensureDir(path.dirname(filePath));
  const content =
    (headerLine ? headerLine + "\n" : "") +
    `export const ${exportName} = ${JSON.stringify(abi, null, 2)} as const;\n`;
  fs.writeFileSync(filePath, content);
}

function exportFeAbis() {
  const root = path.join(__dirname, "..");
  const tf = require(path.join(root, "artifacts/contracts/TokenFactory.sol/TokenFactory.json"));
  const bc = require(path.join(root, "artifacts/contracts/BondingCurve.sol/BondingCurve.json"));
  const tok = require(path.join(root, "artifacts/contracts/Token.sol/Token.json"));
  const bcd = require(path.join(root, "artifacts/contracts/BondingCurveDeployer.sol/BondingCurveDeployer.json"));

  const feAbi = path.join(root, "..", "fe-bonding", "src", "abis");

  writeAbiTs(
    path.join(feAbi, "memeCoinFactory.ts"),
    "/** TokenFactory — đồng bộ contract-bonding (chạy `npm run export:fe-abis` trong contract-bonding). */",
    "memeCoinFactoryAbi",
    tf.abi
  );
  writeAbiTs(
    path.join(feAbi, "bondingCurve.ts"),
    "/** BondingCurve — đồng bộ contract-bonding. */",
    "bondingCurveAbi",
    bc.abi
  );
  writeAbiTs(
    path.join(feAbi, "bondingCurveDeployer.ts"),
    "/** BondingCurveDeployer — đồng bộ contract-bonding (deploy script gọi setCurveDeployer). */",
    "bondingCurveDeployerAbi",
    bcd.abi
  );

  const gen = path.join(feAbi, "generated");
  writeAbiTs(path.join(gen, "memeCoinFactory.ts"), null, "memeCoinFactoryGeneratedAbi", tf.abi);
  writeAbiTs(path.join(gen, "bondingCurve.ts"), null, "bondingCurveGeneratedAbi", bc.abi);
  writeAbiTs(path.join(gen, "bondingCurveDeployer.ts"), null, "bondingCurveDeployerGeneratedAbi", bcd.abi);
  writeAbiTs(path.join(gen, "memeCoin.ts"), null, "memeCoinGeneratedAbi", tok.abi);

  return feAbi;
}

module.exports = { exportFeAbis };

if (require.main === module) {
  const dir = exportFeAbis();
  console.log(`Exported ABI → ${dir}`);
}
