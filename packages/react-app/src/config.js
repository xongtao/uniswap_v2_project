// 如果 @usedapp/core 没有导出 Sepolia 的配置，您可以手动定义它
const Sepolia = {
  chainId: 11155111, // Sepolia 的 Chain ID
  rpcUrl: "https://eth-sepolia.g.alchemy.com/v2/TBZZSZWC6SLq1lW_8wE8X5jF_QUsIosD", // Sepolia 的 RPC URL
};

export const ROUTER_ADDRESS = "0xF94534d557bbfE382F68116fF74179A9e21E2271";

export const DAPP_CONFIG = {
  readOnlyChainId: Sepolia.chainId,
  readOnlyUrls: {
    [Sepolia.chainId]: Sepolia.rpcUrl,
  },
  multicallAddresses: {
    [Sepolia.chainId]: "0x26F49A4fB2Dd3d61451EC3b808461f69EF523952"
  }
};
