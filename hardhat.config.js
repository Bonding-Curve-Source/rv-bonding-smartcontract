require("@nomicfoundation/hardhat-toolbox");
require('@openzeppelin/hardhat-upgrades');
require('dotenv').config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    networks: {
      hardhat: {
        allowUnlimitedContractSize: true,
      },
      bscTestnet: {
        url: `${process.env.BSC_TESTNET_RPC}`,
        chainId: 97,
        gasPrice: 'auto',
        accounts: [`${process.env.BSC_PRIVATEKEY}`],
      },
      bscMainnet: {
        url: `${process.env.BSC_MAINNET_RPC}`,
        chainId: 56,
        gasPrice: 'auto',
        accounts: [`${process.env.BSC_PRIVATEKEY}`],
      },
    },
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 1,
      },
      // IR pipeline thường giảm đáng kể kích thước bytecode (tránh EIP-170 trên BSC)
      viaIR: true,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts"
  },
  mocha: {
    timeout: 40000000000
  },
  etherscan: {
    apiKey: {
      bsc: `${process.env.BSCSCAN_API_KEY}`,
      bscTestnet: `${process.env.BSCSCAN_API_KEY}`
    },
    customChains: [
      {
        network: "bscTestnet",
        chainId: 97,
        urls: {
          apiURL: "https://api-testnet.bscscan.com/api",
          browserURL: "https://testnet.bscscan.com"
        }
      },
      {
        network: "bscMainnet",
        chainId: 56,
        urls: {
          apiURL: "https://api.bscscan.com/api",
          browserURL: "https://bscscan.com"
        }
      }
    ]
  },
  sourcify: {
    enabled: true
  },
  gasReporter: {
    enabled: false,
    currency: 'USD',
    coinmarketcap: `${process.env.Coinmarketcap}`
  }
};
