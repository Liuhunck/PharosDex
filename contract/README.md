npx hardhat compile

npx hardhat ignition deploy ./ignition/modules/DeployDemo.js --network sepolia

npx hardhat test

npx hardhat ignition deploy ./ignition/modules/DeployDexOnly.js --network sepolia --parameters ./ignition/param
eters/sepolia.json