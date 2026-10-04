// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { Test } from "forge-std/Test.sol";
import { ETFToken } from "src/ETFToken.sol";
import { RebalancingETFToken } from "src/RebalancingETFToken.sol";
import { CashGateway } from "src/CashGateway.sol";
import { RobinhoodAssetRegistry } from "src/RobinhoodAssetRegistry.sol";
import { RobinhoodTradingHours } from "src/RobinhoodTradingHours.sol";
import { ExecutionRegistry } from "src/ExecutionRegistry.sol";
import { ETFFactory } from "src/ETFFactory.sol";
import { BasketTypes } from "src/types/BasketTypes.sol";
import { IERC7621 } from "src/interfaces/IERC7621.sol";
import { MockERC20 } from "tests/mocks/MockERC20.sol";
import { MockBasketOracle } from "tests/mocks/MockBasketOracle.sol";
import { MockBasketExecution } from "tests/mocks/MockBasketExecution.sol";

contract ETFSmokeTest is Test {
    MockBasketOracle oracle;
    MockERC20 nvda;
    MockERC20 aapl;
    MockERC20 usdg;
    RobinhoodAssetRegistry rhRegistry;
    RobinhoodTradingHours tradingHours;
    ExecutionRegistry execRegistry;
    MockBasketExecution adapter;
    CashGateway gateway;

    address owner = address(0xA11CE);
    address creator = address(0xC0EA7);
    address platform = address(0x9A7F0);
    address user = address(0xB0B);

    function setUp() public {
        oracle = new MockBasketOracle(address(0), 6);
        nvda = new MockERC20("NVDA token", "NVDA", 18);
        aapl = new MockERC20("AAPL token", "AAPL", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 18);
        oracle.setPrice(address(nvda), 2_000_000);
        oracle.setPrice(address(aapl), 1_000_000);
        oracle.setPrice(address(usdg), 1_000_000);

        rhRegistry = new RobinhoodAssetRegistry(owner);
        vm.startPrank(owner);
        rhRegistry.addAsset(address(nvda));
        rhRegistry.addAsset(address(aapl));
        vm.stopPrank();

        tradingHours = new RobinhoodTradingHours(owner);
        // Shared 24/5 session lives in the global window; no per-token schedules needed.

        execRegistry = new ExecutionRegistry(owner);
        adapter = new MockBasketExecution(oracle);
        adapter.setPair(address(usdg), address(nvda), true);
        adapter.setPair(address(usdg), address(aapl), true);
        adapter.setPair(address(nvda), address(usdg), true);
        adapter.setPair(address(aapl), address(usdg), true);
        adapter.setPair(address(nvda), address(aapl), true);
        adapter.setPair(address(aapl), address(nvda), true);
        vm.prank(owner);
        execRegistry.addExecutionAdapter(address(adapter));

        gateway = new CashGateway(address(usdg), address(execRegistry));
    }

    function _fee() internal view returns (BasketTypes.FeeConfig memory) {
        return BasketTypes.FeeConfig({
            creator: creator,
            platform: platform,
            creatorRateBpsAnnual: 100,
            platformShareBps: 2000
        });
    }

    function _deploy() internal returns (ETFToken etf) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(aapl);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 6000;
        weights[1] = 4000;
        etf = new ETFToken(
            "AI ETF",
            "AIETF",
            tokens,
            weights,
            address(oracle),
            owner,
            address(rhRegistry),
            address(execRegistry),
            address(tradingHours),
            _fee()
        );
    }

    function _deployRebalancing() internal returns (RebalancingETFToken etf) {
        address[] memory tokens = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(aapl);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        BasketTypes.RiskConfig memory risk = BasketTypes.RiskConfig({
            minTradeValue: 1_000_000,
            maxTradeValue: 100_000_000,
            maxKeeperRewardValue: 1_000_000,
            rebalanceBandBps: 100,
            maxSlippageBps: 100,
            keeperRewardBps: 10
        });
        etf = new RebalancingETFToken(
            "R",
            "R",
            tokens,
            weights,
            address(oracle),
            owner,
            address(rhRegistry),
            address(execRegistry),
            address(tradingHours),
            _fee(),
            risk
        );
    }

    function test_inKindContributeWithdraw() public {
        ETFToken etf = _deploy();
        nvda.mint(user, 1000e18);
        aapl.mint(user, 1000e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 60e18;
        amounts[1] = 40e18;
        uint256 shares = etf.contribute(amounts, user, 0);
        assertGt(shares, 0);
        uint256[] memory mins = new uint256[](2);
        uint256[] memory out = etf.withdraw(shares / 2, user, mins);
        assertGt(out[0], 0);
        vm.stopPrank();
    }

    function test_nonRobinhoodAssetRejected() public {
        MockERC20 fake = new MockERC20("Fake", "FAKE", 18);
        oracle.setPrice(address(fake), 1_000_000);
        address[] memory tokens = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(fake);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        vm.expectRevert(abi.encodeWithSelector(ETFToken.NotRobinhoodAsset.selector, address(fake)));
        new ETFToken(
            "Bad",
            "BAD",
            tokens,
            weights,
            address(oracle),
            owner,
            address(rhRegistry),
            address(execRegistry),
            address(tradingHours),
            _fee()
        );
    }

    function test_usdgGatewayRoundTrip() public {
        ETFToken etf = _deploy();
        nvda.mint(user, 1000e18);
        aapl.mint(user, 1000e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory seed = new uint256[](2);
        seed[0] = 60e18;
        seed[1] = 40e18;
        etf.contribute(seed, user, 0);

        usdg.mint(user, 1000e18);
        usdg.approve(address(gateway), type(uint256).max);
        (uint256 shares,) = gateway.contributeWithUSDG(address(etf), 100e18, user, 0, address(adapter));
        assertGt(shares, 0);
        assertEq(gateway.previewContributeWithUSDG(address(etf), 100e18), shares);

        etf.approve(address(gateway), type(uint256).max);
        uint256 usdgBefore = usdg.balanceOf(user);
        uint256 previewOut = gateway.previewWithdrawToUSDG(address(etf), shares);
        uint256 usdgOut = gateway.withdrawToUSDG(address(etf), shares, user, 0, address(adapter));
        assertEq(usdgOut, previewOut);
        assertGt(usdg.balanceOf(user), usdgBefore);
        vm.stopPrank();
    }

    function test_streamingFeeAccruesToCreatorAndPlatform() public {
        ETFToken etf = _deploy();
        nvda.mint(user, 1000e18);
        aapl.mint(user, 1000e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 60e18;
        amounts[1] = 40e18;
        etf.contribute(amounts, user, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + 365 days);
        (uint256 cShares, uint256 pShares) = etf.previewAccruedFees();
        assertGt(cShares, 0);
        assertGt(pShares, 0);
        etf.accrueFees();
        assertEq(etf.balanceOf(creator), cShares);
        assertEq(etf.balanceOf(platform), pShares);
    }

    function test_feeRecipientChangeNeedsCreator() public {
        ETFToken etf = _deploy();
        BasketTypes.FeeConfig memory hijack = BasketTypes.FeeConfig({
            creator: owner,
            platform: platform,
            creatorRateBpsAnnual: 100,
            platformShareBps: 2000
        });
        vm.prank(owner);
        vm.expectRevert(ETFToken.UnauthorizedFeeUpdate.selector);
        etf.setFeeConfig(hijack);
    }

    function test_factoryCreatesBaskets() public {
        ETFFactory factory = new ETFFactory(platform, 2000);
        address[] memory tokens = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(aapl);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        ETFFactory.ETFParams memory p = ETFFactory.ETFParams({
            name: "AI ETF",
            symbol: "AIETF",
            tokens: tokens,
            weights: weights,
            oracle: address(oracle),
            owner: owner,
            robinhoodRegistry: address(rhRegistry),
            executionRegistry: address(execRegistry),
            tradingHours: address(tradingHours),
            fee: _fee()
        });
        address basket = factory.createETF(p);
        assertTrue(factory.isBasket(basket));
        assertTrue(ETFToken(basket).supportsInterface(type(IERC7621).interfaceId));
        assertEq(factory.platformTreasury(), platform);
    }

    function test_factoryRejectsWrongPlatformTreasury() public {
        ETFFactory factory = new ETFFactory(platform, 2000);
        address[] memory tokens = new address[](2);
        tokens[0] = address(nvda);
        tokens[1] = address(aapl);
        uint256[] memory weights = new uint256[](2);
        weights[0] = 5000;
        weights[1] = 5000;
        ETFFactory.ETFParams memory p = ETFFactory.ETFParams({
            name: "AI ETF",
            symbol: "AIETF",
            tokens: tokens,
            weights: weights,
            oracle: address(oracle),
            owner: owner,
            robinhoodRegistry: address(rhRegistry),
            executionRegistry: address(execRegistry),
            tradingHours: address(tradingHours),
            fee: BasketTypes.FeeConfig({
                creator: creator,
                platform: creator,
                creatorRateBpsAnnual: 100,
                platformShareBps: 2000
            })
        });
        vm.expectRevert(
            abi.encodeWithSelector(ETFFactory.WrongPlatformTreasury.selector, platform, creator)
        );
        factory.createETF(p);
        p.fee.platform = platform;
        p.fee.platformShareBps = 1999;
        vm.expectRevert(abi.encodeWithSelector(ETFFactory.InsufficientPlatformShare.selector, uint16(2000), uint16(1999)));
        factory.createETF(p);
    }

    function test_rebalancingTradeMovesTowardTarget() public {
        RebalancingETFToken etf = _deployRebalancing();
        nvda.mint(user, 10_000e18);
        aapl.mint(user, 10_000e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 900e18;
        amounts[1] = 100e18;
        etf.contribute(amounts, user, 0);
        vm.stopPrank();
        (uint256 amountIn,,) = etf.rebalanceTrade(address(nvda), address(aapl), address(adapter));
        assertGt(amountIn, 0);
    }

    function test_marketClosedBlocksMintsAndTradesButNotWithdraw() public {
        ETFToken etf = _deploy();
        nvda.mint(user, 1000e18);
        aapl.mint(user, 1000e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 60e18;
        amounts[1] = 40e18;
        uint256 shares = etf.contribute(amounts, user, 0);
        vm.stopPrank();

        vm.prank(owner);
        tradingHours.setTokenPaused(address(nvda), true);
        assertFalse(tradingHours.isTradable(address(nvda)));

        uint256[] memory more = new uint256[](2);
        more[0] = 1e18;
        more[1] = 1e18;
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(ETFToken.MarketClosed.selector, address(nvda)));
        etf.contribute(more, user, 0);

        usdg.mint(user, 10e18);
        usdg.approve(address(gateway), type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(CashGateway.MarketClosed.selector, address(nvda)));
        gateway.contributeWithUSDG(address(etf), 10e18, user, 0, address(adapter));

        uint256[] memory mins = new uint256[](2);
        uint256[] memory out = etf.withdraw(shares / 2, user, mins);
        assertGt(out[0], 0);
        vm.stopPrank();
    }

    function test_tradeRevertsWhenClosed() public {
        RebalancingETFToken etf = _deployRebalancing();
        nvda.mint(user, 10_000e18);
        aapl.mint(user, 10_000e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 900e18;
        amounts[1] = 100e18;
        etf.contribute(amounts, user, 0);
        vm.stopPrank();

        assertTrue(etf.previewRebalanceTrade(address(nvda), address(aapl)).executable);
        vm.prank(owner);
        tradingHours.setTokenPaused(address(aapl), true);
        assertTrue(etf.previewRebalanceTrade(address(nvda), address(aapl)).executable);
        vm.expectRevert(abi.encodeWithSelector(ETFToken.MarketClosed.selector, address(aapl)));
        etf.rebalanceTrade(address(nvda), address(aapl), address(adapter));
    }

    function test_weekendClosedWeekdayOpen() public {
        ETFToken etf = _deploy();
        assertTrue(tradingHours.isTradable(address(nvda)));
        vm.warp(2 * 86_400 + 43_200);
        assertFalse(tradingHours.isTradable(address(nvda)));
        assertFalse(tradingHours.isTradable(address(aapl)));
        nvda.mint(user, 10e18);
        aapl.mint(user, 10e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.expectRevert(abi.encodeWithSelector(ETFToken.MarketClosed.selector, address(nvda)));
        etf.contribute(amounts, user, 0);
        vm.stopPrank();
    }

    // --- fuzz ---

    function testFuzz_roundTripNeverReturnsMoreThanContributed(uint96 a, uint96 b) public {
        uint256 amountA = bound(uint256(a), 1e15, 500e18);
        uint256 amountB = bound(uint256(b), 1e15, 500e18);
        ETFToken etf = _deploy();
        nvda.mint(user, amountA);
        aapl.mint(user, amountB);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountA;
        amounts[1] = amountB;
        uint256 shares = etf.contribute(amounts, user, 0);
        uint256[] memory mins = new uint256[](2);
        uint256[] memory out = etf.withdraw(shares, user, mins);
        vm.stopPrank();
        assertLe(out[0], amountA);
        assertLe(out[1], amountB);
    }

    function testFuzz_previewContributeEqualsContribute(uint96 a, uint96 b) public {
        uint256 amountA = bound(uint256(a), 1e15, 500e18);
        uint256 amountB = bound(uint256(b), 1e15, 500e18);
        ETFToken etf = _deploy();
        nvda.mint(user, amountA * 2);
        aapl.mint(user, amountB * 2);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountA;
        amounts[1] = amountB;
        etf.contribute(amounts, user, 0);
        uint256 predicted = etf.previewContribute(amounts);
        assertEq(etf.contribute(amounts, user, 0), predicted);
        vm.stopPrank();
    }

    function testFuzz_gatewayRoundTripPreservesValue(uint96 usdgIn) public {
        uint256 amount = bound(uint256(usdgIn), 10e18, 500e18);
        ETFToken etf = _deploy();
        nvda.mint(user, 1000e18);
        aapl.mint(user, 1000e18);
        vm.startPrank(user);
        nvda.approve(address(etf), type(uint256).max);
        aapl.approve(address(etf), type(uint256).max);
        uint256[] memory seed = new uint256[](2);
        seed[0] = 600e18;
        seed[1] = 400e18;
        etf.contribute(seed, user, 0);
        usdg.mint(user, amount);
        usdg.approve(address(gateway), type(uint256).max);
        (uint256 shares,) = gateway.contributeWithUSDG(address(etf), amount, user, 0, address(adapter));
        etf.approve(address(gateway), type(uint256).max);
        uint256 usdgOut = gateway.withdrawToUSDG(address(etf), shares, user, 0, address(adapter));
        vm.stopPrank();
        assertLe(usdgOut, amount);
        assertGt(usdgOut, 0);
    }
}
