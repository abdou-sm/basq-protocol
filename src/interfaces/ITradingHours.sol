// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

/// @title Trading-hours gate for Robinhood stock baskets
/// @notice Mirrors off-chain `tradingCapabilities` (market/extended/overnight) + the
///         Mon 02:00 CET – Sat 02:00 CET tokenization window as onchain checks.
///         Feed staleness alone is insufficient: heartbeats can be long and per-asset
///         sessions differ, so baskets enforce sessions explicitly before pricing.
interface ITradingHours {
    error ZeroAddress();
    error NotAContract(address account);
    error InvalidSchedule();

    event GlobalWindowSet(uint8 openDay, uint32 openTime, uint8 closeDay, uint32 closeTime, uint8 daysBitmap);
    event GlobalPausedSet(bool paused);
    event TokenScheduleSet(address indexed token, uint32 openTime, uint32 closeTime, uint8 daysBitmap, bool useGlobal);
    event TokenPausedSet(address indexed token, bool paused);

    function isTradable(address token) external view returns (bool);
}
