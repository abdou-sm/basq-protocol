// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { FixedPriceOracle } from "../src/oracles/FixedPriceOracle.sol";
import { CashGateway } from "../src/CashGateway.sol";
import { TestnetExecution, DeployTestnet } from "./DeployTestnet.s.sol";

/// @notice Migrates the cash leg from mock test USDG to official Paxos USDG on testnet.
/// @dev Deploys a new CashGateway bound to the real USDG (immutable), prices it at $1,
///      wires adapter pairs, and seeds adapter inventory. Existing baskets are untouched.
///      Env: PRIVATE_KEY, USDG_ADDRESS, SEED_USDG (raw units),
///      STOCK_TOKENS (to rediscover listed stocks).
///      The registry/oracle/adapter addresses come as CLI args (see command below) because
///      they identify an existing deployment, not configuration.
contract MigrateUsdg is DeployTestnet {
    /// @dev Shadows the full deploy; this script only migrates the cash leg.
    /// @param execReg ExecutionRegistry of the live deployment.
    /// @param oracleAddr FixedPriceOracle of the live deployment.
    /// @param adapterAddr TestnetExecution adapter of the live deployment.
    function run(address execReg, address oracleAddr, address adapterAddr) external {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        address usdg = vm.envOr(
            "USDG_ADDRESS", address(0x7E955252E15c84f5768B83c41a71F9eba181802F)
        );
        uint256 seed = vm.envOr("SEED_USDG", uint256(0));

        require(IERC20(usdg).balanceOf(deployer) >= seed, "MigrateUsdg: claim USDG at https://faucet.paxos.com/");

        vm.startBroadcast(key);

        FixedPriceOracle oracle = FixedPriceOracle(oracleAddr);
        oracle.setPrice(usdg, 1_000_000);

        TestnetExecution adapter = TestnetExecution(adapterAddr);
        address[] memory stocks = _listedStocks();
        for (uint256 i; i < stocks.length; ++i) {
            adapter.setPair(usdg, stocks[i], true);
            adapter.setPair(stocks[i], usdg, true);
        }
        if (seed > 0) {
            IERC20(usdg).transfer(adapterAddr, seed);
        }

        CashGateway gateway = new CashGateway(usdg, execReg);

        vm.stopBroadcast();

        console2.log("USDG", usdg);
        console2.log("GATEWAY", address(gateway));
        console2.log("SEEDED", seed);
    }

    /// @dev Rediscovers listed stocks from STOCK_TOKENS env (same format as deploy).
    function _listedStocks() internal returns (address[] memory stocks) {
        stocks = _parseAddresses(vm.envString("STOCK_TOKENS"));
    }
}
