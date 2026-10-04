// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

library BasketTypes {
    struct RiskConfig {
        uint256 minTradeValue;
        uint256 maxTradeValue;
        uint256 maxKeeperRewardValue;
        uint16 rebalanceBandBps;
        uint16 maxSlippageBps;
        uint16 keeperRewardBps;
    }

    struct TradePreview {
        bool executable;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 tradeValue;
        uint256 expectedAmountOut;
        uint256 minAmountOut;
    }

    /// @param creator Recipient of streaming creator fees (usually the ETF creator/owner).
    /// @param platform Recipient of the platform cut taken from creator flow.
    /// @param creatorRateBpsAnnual Annual streaming rate in bps (100 = 1%/yr).
    /// @param platformShareBps Share of each streaming mint routed to platform (2000 = 20%).
    struct FeeConfig {
        address creator;
        address platform;
        uint16 creatorRateBpsAnnual;
        uint16 platformShareBps;
    }
}
