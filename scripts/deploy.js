const fs = require("fs");
const path = require("path");
const hre = require("hardhat");
const { exportFeAbis } = require("./export-fe-abis.js");

function ensureDir(dirPath) {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function writeJson(filePath, data) {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
}

function printEnvGuide({ networkName, chainId, factoryAddress, deployer }) {
  console.log("\n=== ENV cần thêm/cập nhật ===");
  console.log(`Network: ${networkName} (chainId=${chainId})`);
  console.log(`Deployer: ${deployer}`);
  console.log("\n# fe-bonding/.env");
  console.log(`VITE_CHAIN_ID=${chainId}`);
  console.log(`VITE_MEME_FACTORY_ADDRESS=${factoryAddress}`);
  console.log("VITE_BONDING_CURVE_ADDRESS=<sau createToken>");
  console.log("VITE_TOKEN_ADDRESS=<sau createToken>");

  console.log("\n# be-bonding/.env (nếu cần)");
  console.log(`MEME_FACTORY_ADDRESS=${factoryAddress}`);
  console.log(`CHAIN_ID=${chainId}`);

  console.log(
    "\nGhi chú: BondingCurve + Token được deploy qua TokenFactory.createToken (constant-product, virtualTokenReserve = initialSupply)."
  );
}

async function main() {
  const [deployer] = await hre.ethers.getSigners();
  const networkName = hre.network.name;
  const { chainId } = await hre.ethers.provider.getNetwork();

  console.log(`Deploying with: ${deployer.address}`);
  console.log(`Network: ${networkName} (chainId=${chainId})`);

  const Factory = await hre.ethers.getContractFactory("TokenFactory");
  const tokenFactory = await Factory.deploy();
  await tokenFactory.waitForDeployment();
  const factoryAddress = await tokenFactory.getAddress();

  const Deployer = await hre.ethers.getContractFactory("BondingCurveDeployer");
  const curveDeployer = await Deployer.deploy(factoryAddress);
  await curveDeployer.waitForDeployment();
  const curveDeployerAddress = await curveDeployer.getAddress();

  const setTx = await tokenFactory.setCurveDeployer(curveDeployerAddress);
  await setTx.wait();

  const txHash = tokenFactory.deploymentTransaction()?.hash || "";

  console.log(`TokenFactory deployed: ${factoryAddress}`);
  console.log(`BondingCurveDeployer deployed: ${curveDeployerAddress}`);
  console.log(`setCurveDeployer tx: ${setTx.hash}`);
  console.log(`TokenFactory deployment tx: ${txHash}`);

  const deploymentsPath = path.join(__dirname, "..", "deployments", `${networkName}.json`);
  const deploymentRecord = {
    network: networkName,
    chainId: Number(chainId),
    deployer: deployer.address,
    tokenFactory: factoryAddress,
    bondingCurveDeployer: curveDeployerAddress,
    // Giữ memeFactory = tokenFactory (tương thích VITE_MEME_FACTORY_ADDRESS)
    memeFactory: factoryAddress,
    deploymentTx: txHash,
    deployedAt: new Date().toISOString(),
    contracts: {
      TokenFactory: factoryAddress,
      BondingCurveDeployer: curveDeployerAddress,
    },
    notes:
      "BondingCurve được tạo qua BondingCurveDeployer (new BondingCurve) gọi từ TokenFactory.createToken; deploy script đã setCurveDeployer.",
  };

  writeJson(deploymentsPath, deploymentRecord);
  console.log(`Saved deployment: ${deploymentsPath}`);

  const abiDir = exportFeAbis();
  console.log(`Exported ABI to frontend: ${abiDir}`);

  printEnvGuide({
    networkName,
    chainId: Number(chainId),
    factoryAddress,
    deployer: deployer.address,
  });
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
