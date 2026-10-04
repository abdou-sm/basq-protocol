// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { RobinhoodAssetRegistry } from "../src/RobinhoodAssetRegistry.sol";
import { ExecutionRegistry } from "../src/ExecutionRegistry.sol";
import { RobinhoodTradingHours } from "../src/RobinhoodTradingHours.sol";
import { FixedPriceOracle } from "../src/oracles/FixedPriceOracle.sol";
import { CashGateway } from "../src/CashGateway.sol";
import { ETFFactory } from "../src/ETFFactory.sol";
import { RebalancingETFFactory } from "../src/RebalancingETFFactory.sol";
import { IBasketExecution } from "../src/interfaces/IBasketExecution.sol";
import { IBasketOracle } from "../src/interfaces/IBasketOracle.sol";
import { BasketTypes } from "../src/types/BasketTypes.sol";
import { MockERC20 } from "../tests/mocks/MockERC20.sol";

/// @notice Inventory-backed execution adapter for TESTNET ONLY.
/// @dev Prices at the oracle's fair value from finite inventory (faucet stock tokens +
///      minted test USDG). Never deploy on mainnet: inventory caps trade size and the
///      deployer could drain it. Mainnet needs UniswapV2StyleExecution/RFQ adapters.
contract TestnetExecution is Ownable, IBasketExecution {
    using SafeERC20 for IERC20;

    error PairNotConfigured(address tokenIn, address tokenOut);
    error InsufficientInventory(uint256 have, uint256 need);

    IBasketOracle public immutable oracle;
    mapping(bytes32 pair => bool supported) private _pairs;

    constructor(address oracle_, address initialOwner) Ownable(initialOwner) {
        oracle = IBasketOracle(oracle_);
    }

    function setPair(address tokenIn, address tokenOut, bool supported) external onlyOwner {
        _pairs[keccak256(abi.encode(tokenIn, tokenOut))] = supported;
    }

    function supportsPair(address tokenIn, address tokenOut) external view returns (bool) {
        return _pairs[keccak256(abi.encode(tokenIn, tokenOut))];
    }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    )
        external
        returns (uint256 amountOut)
    {
        if (!this.supportsPair(tokenIn, tokenOut)) revert PairNotConfigured(tokenIn, tokenOut);
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        amountOut = oracle.quoteInverse(tokenOut, oracle.quote(tokenIn, amountIn));
        uint256 have = IERC20(tokenOut).balanceOf(address(this));
        if (have < amountOut) revert InsufficientInventory(have, amountOut);
        if (amountOut < minAmountOut) revert InsufficientInventory(amountOut, minAmountOut);
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
    }
}

/// @notice Full-stack testnet deployment: registries -> oracle/prices -> test USDG ->
///         inventory adapter -> gateway -> factories -> (optional) first ETF.
/// @dev Env: PRIVATE_KEY (via --private-key), OWNER, PLATFORM, STOCK_TOKENS (csv),
///      STOCK_PRICES (csv, 6-dec per whole token), CREATE_FIRST, FIRST_NAME, FIRST_SYMBOL.
contract DeployTestnet is Script {
    function run() external virtual {
        uint256 key = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(key);
        address owner = vm.envOr("OWNER", deployer);
        address platform = vm.envOr("PLATFORM", deployer);
        address[] memory stocks = _parseAddresses(vm.envString("STOCK_TOKENS"));
        uint256[] memory prices = _parseUints(vm.envString("STOCK_PRICES"));
        require(stocks.length > 0 && stocks.length == prices.length, "STOCK_TOKENS/PRICES mismatch");

        vm.startBroadcast(key);

        RobinhoodAssetRegistry assetReg = new RobinhoodAssetRegistry(deployer);
        ExecutionRegistry execReg = new ExecutionRegistry(deployer);
        RobinhoodTradingHours tradingHours = new RobinhoodTradingHours(deployer);
        FixedPriceOracle oracle = new FixedPriceOracle(address(0), 6, deployer);

        for (uint256 i; i < stocks.length; ++i) {
            assetReg.addAsset(stocks[i]);
            oracle.setPrice(stocks[i], prices[i]);
        }

        MockERC20 usdg = new MockERC20("Test USDG", "TUSDG", 18);
        oracle.setPrice(address(usdg), 1_000_000);
        usdg.mint(deployer, 20_000e18);

        TestnetExecution adapter = new TestnetExecution(address(oracle), deployer);
        for (uint256 i; i < stocks.length; ++i) {
            adapter.setPair(address(usdg), stocks[i], true);
            adapter.setPair(stocks[i], address(usdg), true);
            for (uint256 j; j < stocks.length; ++j) {
                if (i != j) adapter.setPair(stocks[i], stocks[j], true);
            }
            IERC20(stocks[i]).transfer(address(adapter), 4e18);
        }
        usdg.transfer(address(adapter), 10_000e18);
        execReg.addExecutionAdapter(address(adapter));

        CashGateway gateway = new CashGateway(address(usdg), address(execReg));
        uint16 minPlatformShare = uint16(vm.envOr("MIN_PLATFORM_SHARE_BPS", uint256(2000)));
        ETFFactory factory = new ETFFactory(platform, minPlatformShare);
        RebalancingETFFactory rFactory = new RebalancingETFFactory(platform, minPlatformShare);

        if (vm.envOr("CREATE_FIRST", false)) {
            uint256[] memory weights = new uint256[](stocks.length);
            uint256 share = 10_000 / stocks.length;
            uint256 acc;
            for (uint256 i; i < weights.length; ++i) {
                weights[i] = share;
                acc += share;
            }
            weights[0] += 10_000 - acc;
            ETFFactory.ETFParams memory p = ETFFactory.ETFParams({
                name: vm.envOr("FIRST_NAME", string("Testnet Basket")),
                symbol: vm.envOr("FIRST_SYMBOL", string("TBKT")),
                tokens: stocks,
                weights: weights,
                oracle: address(oracle),
                owner: owner,
                robinhoodRegistry: address(assetReg),
                executionRegistry: address(execReg),
                tradingHours: address(tradingHours),
                fee: BasketTypes.FeeConfig({
                    creator: deployer,
                    platform: platform,
                    creatorRateBpsAnnual: 100,
                    platformShareBps: 2000
                })
            });
            BasketTypes.RiskConfig memory risk = BasketTypes.RiskConfig({
                minTradeValue: 1_000_000,
                maxTradeValue: 100_000_000,
                maxKeeperRewardValue: 1_000_000,
                rebalanceBandBps: 100,
                maxSlippageBps: 100,
                keeperRewardBps: 10
            });
            address basket = rFactory.createRebalancingETF(p, risk);
            console2.log("FIRST_BASKET", basket);
        }

        assetReg.transferOwnership(owner);
        execReg.transferOwnership(owner);
        tradingHours.transferOwnership(owner);
        oracle.transferOwnership(owner);
        adapter.transferOwnership(owner);

        vm.stopBroadcast();

        console2.log("ASSET_REGISTRY", address(assetReg));
        console2.log("EXEC_REGISTRY", address(execReg));
        console2.log("TRADING_HOURS", address(tradingHours));
        console2.log("ORACLE", address(oracle));
        console2.log("USDG", address(usdg));
        console2.log("ADAPTER", address(adapter));
        console2.log("GATEWAY", address(gateway));
        console2.log("FACTORY", address(factory));
        console2.log("RFACTORY", address(rFactory));
        console2.log("OWNER", owner);
    }

    function _parseAddresses(string memory csv) internal pure returns (address[] memory out) {
        string[] memory parts = _split(csv);
        out = new address[](parts.length);
        for (uint256 i; i < parts.length; ++i) {
            out[i] = _parseAddress(parts[i]);
        }
    }

    function _parseUints(string memory csv) internal pure returns (uint256[] memory out) {
        string[] memory parts = _split(csv);
        out = new uint256[](parts.length);
        for (uint256 i; i < parts.length; ++i) {
            out[i] = _parseUint(parts[i]);
        }
    }

    function _split(string memory csv) internal pure returns (string[] memory parts) {
        bytes memory b = bytes(csv);
        uint256 count = 1;
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == ",") count++;
        }
        parts = new string[](count);
        uint256 idx;
        uint256 start;
        for (uint256 i; i <= b.length; ++i) {
            if (i == b.length || b[i] == ",") {
                bytes memory slice = new bytes(i - start);
                for (uint256 j; j < i - start; ++j) {
                    slice[j] = b[start + j];
                }
                parts[idx++] = string(slice);
                start = i + 1;
            }
        }
    }

    function _parseAddress(string memory s) internal pure returns (address out) {
        bytes memory b = bytes(s);
        uint256 off = (b.length == 42 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) ? 2 : 0;
        require(b.length - off == 40, "bad address");
        uint160 acc;
        for (uint256 i; i < 40; ++i) {
            acc = acc * 16 + uint160(_hexVal(b[off + i]));
        }
        out = address(acc);
    }

    function _hexVal(bytes1 c) internal pure returns (uint8) {
        uint8 v = uint8(c);
        if (v >= 48 && v <= 57) return v - 48;
        if (v >= 97 && v <= 102) return v - 97 + 10;
        if (v >= 65 && v <= 70) return v - 65 + 10;
        revert("bad hex");
    }

    function _parseUint(string memory s) internal pure returns (uint256 out) {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            require(uint8(b[i]) >= 48 && uint8(b[i]) <= 57, "bad uint");
            out = out * 10 + (uint8(b[i]) - 48);
        }
    }
}
