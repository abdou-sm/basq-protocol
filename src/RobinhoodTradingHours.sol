// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ITradingHours } from "./interfaces/ITradingHours.sol";

/// @title Robinhood trading-hours registry
/// @notice Single shared 24/5 session for all stock/ETF tokens (Mon–Fri, UTC) plus the
///         tokenization window. Per-token schedules remain only as an escape hatch for
///         single-name halts; unconfigured tokens follow the global window.
///         A keeper bot pushes `setTokenPaused` from `GET /rhj/assets` for halts.
/// @dev Weekday: Mon=1..Sun=7 (UTC). daysBitmap bit0=Mon..bit6=Sun.
contract RobinhoodTradingHours is Ownable, ITradingHours {
    struct Schedule {
        uint32 openTime;
        uint32 closeTime;
        uint8 daysBitmap;
        bool useGlobal;
        bool configured;
    }

    struct Window {
        uint8 openDay;
        uint32 openTime;
        uint8 closeDay;
        uint32 closeTime;
        uint8 daysBitmap;
    }

    bool public globalPaused;
    Window private _global;
    mapping(address token => Schedule schedule) private _schedules;
    mapping(address token => bool paused) private _tokenPaused;

    constructor(address initialOwner) Ownable(initialOwner) {
        // Default mirrors the primary tokenization window Mon 02:00 CET – Sat 02:00 CET
        // as Mon 01:00 UTC – Sat 01:00 UTC (CET = UTC+1). In CEST (UTC+2) the owner shifts
        // both times to 00:00 UTC via `setGlobalWindow` at the DST boundary.
        _global = Window({ openDay: 1, openTime: 3600, closeDay: 6, closeTime: 3600, daysBitmap: 0x3F });
    }

    function setGlobalWindow(
        uint8 openDay,
        uint32 openTime,
        uint8 closeDay,
        uint32 closeTime,
        uint8 daysBitmap
    )
        external
        onlyOwner
    {
        _validateDay(openDay);
        _validateDay(closeDay);
        _validateTime(openTime);
        _validateTime(closeTime);
        if (daysBitmap == 0) revert InvalidSchedule();
        _global = Window(openDay, openTime, closeDay, closeTime, daysBitmap);
        emit GlobalWindowSet(openDay, openTime, closeDay, closeTime, daysBitmap);
    }

    function setGlobalPaused(bool paused_) external onlyOwner {
        globalPaused = paused_;
        emit GlobalPausedSet(paused_);
    }

    function setTokenSchedule(
        address token,
        uint32 openTime,
        uint32 closeTime,
        uint8 daysBitmap,
        bool useGlobal
    )
        external
        onlyOwner
    {
        if (token == address(0)) revert ZeroAddress();
        _validateTime(openTime);
        _validateTime(closeTime);
        if (!useGlobal && daysBitmap == 0) revert InvalidSchedule();
        _schedules[token] = Schedule({
            openTime: openTime,
            closeTime: closeTime,
            daysBitmap: daysBitmap,
            useGlobal: useGlobal,
            configured: true
        });
        emit TokenScheduleSet(token, openTime, closeTime, daysBitmap, useGlobal);
    }

    function setTokenPaused(address token, bool paused_) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        _tokenPaused[token] = paused_;
        emit TokenPausedSet(token, paused_);
    }

    function isTradable(address token) external view returns (bool) {
        if (globalPaused) return false;
        if (_tokenPaused[token]) return false;
        Schedule memory s = _schedules[token];
        if (!s.configured) return _inGlobalWindow();
        if (s.useGlobal) return _inGlobalWindow();
        return _inSchedule(s.openTime, s.closeTime, s.daysBitmap);
    }

    function _inGlobalWindow() private view returns (bool) {
        Window memory w = _global;
        uint8 day = _weekday();
        uint32 tod = _timeOfDay();
        if (((w.daysBitmap >> (day - 1)) & 1) == 0) return false;
        if (w.openDay == w.closeDay) return tod >= w.openTime && tod <= w.closeTime;
        if (day == w.openDay) return tod >= w.openTime;
        if (day == w.closeDay) return tod <= w.closeTime;
        return _dayInRange(day, w.openDay, w.closeDay);
    }

    function _inSchedule(uint32 openTime, uint32 closeTime, uint8 daysBitmap) private view returns (bool) {
        uint8 day = _weekday();
        if (((daysBitmap >> (day - 1)) & 1) == 0) return false;
        uint32 tod = _timeOfDay();
        if (openTime <= closeTime) return tod >= openTime && tod <= closeTime;
        return tod >= openTime || tod <= closeTime;
    }

    function _dayInRange(uint8 day, uint8 openDay, uint8 closeDay) private pure returns (bool) {
        if (openDay <= closeDay) return day >= openDay && day <= closeDay;
        return day >= openDay || day <= closeDay;
    }

    function _weekday() private view returns (uint8) {
        // 1970-01-01 was Thursday (4). Mon=1..Sun=7.
        uint256 dayIndex = (block.timestamp / 86_400 + 3) % 7;
        return uint8(dayIndex + 1);
    }

    function _timeOfDay() private view returns (uint32) {
        return uint32(block.timestamp % 86_400);
    }

    function _validateDay(uint8 day) private pure {
        if (day < 1 || day > 7) revert InvalidSchedule();
    }

    function _validateTime(uint32 t) private pure {
        if (t > 86_400) revert InvalidSchedule();
    }
}
