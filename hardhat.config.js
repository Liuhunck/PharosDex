require("@chainlink/env-enc").config();
require("@nomicfoundation/hardhat-toolbox");

const ETH_SEPOLIA_URL = process.env.ETH_SEPOLIA_URL;
const PHAROS_ATLANTIC_URL = process.env.PHAROS_ATLANTIC_URL;

const TEST_ACCOUNT_0 = process.env.TEST_ACCOUNT_0;

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
    solidity: "0.8.28",
    defaultNetwork: "hardhat",
    networks: {
        eth_sepolia: {
            url: ETH_SEPOLIA_URL,
            accounts: [TEST_ACCOUNT_0],
            chainId: 11155111,
        },
        pharos_atlantic: {
            url: PHAROS_ATLANTIC_URL,
            accounts: [TEST_ACCOUNT_0],
            chainId: 688689,
        },
    },
};
