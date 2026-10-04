// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC7621 } from "./interfaces/IERC7621.sol";
import { IBasketOracle } from "./interfaces/IBasketOracle.sol";

/// @title ERC-7621 Basket Token (Robinhood ETF base)
/// @notice Basket of ERC-20 constituents at target weights. Contract is itself the share token.
/// @dev Valuation is oracle-based and deterministic. Reserves tracked internally (donations ignored).
///      Zero weight is permitted as a retirement state; removal requires zero reserve.
contract BasketToken is ERC20, Ownable, ReentrancyGuard, IERC7621 {
    using SafeERC20 for IERC20;

    uint256 internal constant TOTAL_WEIGHT_BPS = 10_000;
    uint256 internal constant MINIMUM_SHARES = 1000;
    uint256 internal constant MAX_CONSTITUENTS = 32;
    uint8 internal constant SHARE_DECIMALS = 18;
    address internal constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    bytes4 internal constant ERC173_INTERFACE_ID = 0x7f5828d0;

    error BalanceDeltaMismatch(address token);
    error ConstituentNotRemovable(address token);
    error SelfConstituent();
    error EmptyBasket();
    error TooManyConstituents(uint256 count);
    error ZeroShares();
    error ZeroSupply();
    error InvalidBasketValue();
    error NotAContract(address account);
    error InvalidUnitDecimals(uint8 decimals);
    error RenounceDisabled();
    error InvalidReceiver();
    error NoPendingOracle();
    error OracleTimelockPending(uint64 readyAt);

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event OracleProposed(address indexed newOracle, uint64 indexed readyAt);
    event OracleProposalCancelled(address indexed cancelledOracle);

    uint256 internal constant ORACLE_TIMELOCK = 2 days;

    IBasketOracle public oracle;
    address public pendingOracle;
    uint64 public pendingOracleReadyAt;

    address[] private _constituents;
    uint256[] private _weights;
    mapping(address token => uint256 indexPlusOne) private _indexPlusOne;
    mapping(address token => uint256 amount) private _reserves;

    constructor(
        string memory name_,
        string memory symbol_,
        address[] memory tokens,
        uint256[] memory weights,
        address oracle_,
        address initialOwner
    )
        ERC20(name_, symbol_)
        Ownable(initialOwner)
    {
        _setOracle(oracle_);
        _installConstituents(tokens, weights);
    }

    function _installConstituents(address[] memory tokens, uint256[] memory weights) private {
        uint256 count = tokens.length;
        if (count == 0) revert EmptyBasket();
        if (count > MAX_CONSTITUENTS) revert TooManyConstituents(count);
        if (weights.length != count) revert LengthMismatch(count, weights.length);

        uint256 weightSum;
        for (uint256 i; i < count; ++i) {
            address token = tokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (token == address(this)) revert SelfConstituent();
            for (uint256 j; j < i; ++j) {
                if (tokens[j] == token) revert DuplicateConstituent(token);
            }
            weightSum += weights[i];
        }
        if (weightSum != TOTAL_WEIGHT_BPS) revert InvalidWeights(weightSum);
        _validateWeights(tokens, weights);

        address[] memory previous = _constituents;
        for (uint256 i; i < previous.length; ++i) {
            address token = previous[i];
            if (_reserves[token] == 0) continue;
            bool retained;
            for (uint256 j; j < count; ++j) {
                if (tokens[j] == token) {
                    retained = true;
                    break;
                }
            }
            if (!retained) revert ConstituentNotRemovable(token);
        }

        IBasketOracle oracle_ = oracle;
        for (uint256 i; i < count; ++i) {
            oracle_.validateAsset(tokens[i]);
        }

        for (uint256 i; i < previous.length; ++i) {
            delete _indexPlusOne[previous[i]];
        }

        _constituents = tokens;
        _weights = weights;
        for (uint256 i; i < count; ++i) {
            _indexPlusOne[tokens[i]] = i + 1;
        }
    }

    function _setOracle(address newOracle) private {
        if (newOracle == address(0) || newOracle.code.length == 0) revert NotAContract(newOracle);
        uint8 unitDecimals_ = IBasketOracle(newOracle).unitDecimals();
        if (unitDecimals_ > SHARE_DECIMALS) revert InvalidUnitDecimals(unitDecimals_);
        address previous = address(oracle);
        oracle = IBasketOracle(newOracle);
        emit OracleUpdated(previous, newOracle);
    }

    function _validateOracleCandidate(address newOracle) private view {
        if (newOracle == address(0) || newOracle.code.length == 0) revert NotAContract(newOracle);
        uint8 unitDecimals_ = IBasketOracle(newOracle).unitDecimals();
        if (unitDecimals_ > SHARE_DECIMALS) revert InvalidUnitDecimals(unitDecimals_);
        address[] memory tokens = _constituents;
        for (uint256 i; i < tokens.length; ++i) {
            IBasketOracle(newOracle).validateAsset(tokens[i]);
        }
    }

    function proposeOracle(address newOracle) external onlyOwner {
        _validateOracleCandidate(newOracle);
        uint64 readyAt = uint64(block.timestamp + ORACLE_TIMELOCK);
        pendingOracle = newOracle;
        pendingOracleReadyAt = readyAt;
        emit OracleProposed(newOracle, readyAt);
    }

    function cancelOracleProposal() external onlyOwner {
        address cancelled = pendingOracle;
        if (cancelled == address(0)) revert NoPendingOracle();
        delete pendingOracle;
        delete pendingOracleReadyAt;
        emit OracleProposalCancelled(cancelled);
    }

    function commitOracle() external onlyOwner {
        address newOracle = pendingOracle;
        if (newOracle == address(0)) revert NoPendingOracle();
        uint64 readyAt = pendingOracleReadyAt;
        if (block.timestamp < readyAt) revert OracleTimelockPending(readyAt);
        delete pendingOracle;
        delete pendingOracleReadyAt;
        _validateOracleCandidate(newOracle);
        _setOracle(newOracle);
    }

    function getConstituents() external view returns (address[] memory tokens, uint256[] memory weights) {
        return (_constituents, _weights);
    }

    function totalConstituents() external view returns (uint256 count) {
        return _constituents.length;
    }

    function getReserve(address token) external view returns (uint256 balance) {
        return _reserves[token];
    }

    function getWeight(address token) external view returns (uint256 weight) {
        uint256 indexPlusOne = _indexPlusOne[token];
        if (indexPlusOne == 0) revert NotConstituent(token);
        return _weights[indexPlusOne - 1];
    }

    function isConstituent(address token) external view returns (bool) {
        return _indexPlusOne[token] != 0;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC7621).interfaceId
            || interfaceId == ERC173_INTERFACE_ID;
    }

    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function _reserveOf(address token) internal view returns (uint256) {
        return _reserves[token];
    }

    function _increaseReserve(address token, uint256 amount) internal {
        _reserves[token] += amount;
    }

    function _decreaseReserve(address token, uint256 amount) internal {
        _reserves[token] -= amount;
    }

    function _constituentIndex(address token) internal view returns (uint256 indexPlusOne) {
        return _indexPlusOne[token];
    }

    function _weightAt(uint256 index) internal view returns (uint256) {
        return _weights[index];
    }

    function _weightsArray() internal view returns (uint256[] memory) {
        return _weights;
    }

    function _constituentsArray() internal view returns (address[] memory) {
        return _constituents;
    }

    function _requireLength(uint256 actual) private view {
        uint256 expected = _constituents.length;
        if (actual != expected) revert LengthMismatch(expected, actual);
    }

    function _authorizeContribution(address, address) internal view virtual { }
    function _validateWeights(address[] memory, uint256[] memory) internal view virtual { }

    function _authorizeRebalance() internal view virtual {
        _checkOwner();
    }

    function _pull(address token, uint256 amount) private {
        IERC20 erc20 = IERC20(token);
        uint256 selfBefore = erc20.balanceOf(address(this));
        erc20.safeTransferFrom(msg.sender, address(this), amount);
        if (erc20.balanceOf(address(this)) - selfBefore != amount) revert BalanceDeltaMismatch(token);
    }

    function _push(address token, address to, uint256 amount) internal {
        IERC20 erc20 = IERC20(token);
        uint256 selfBefore = erc20.balanceOf(address(this));
        uint256 toBefore = erc20.balanceOf(to);
        erc20.safeTransfer(to, amount);
        if (selfBefore - erc20.balanceOf(address(this)) != amount) revert BalanceDeltaMismatch(token);
        if (erc20.balanceOf(to) - toBefore != amount) revert BalanceDeltaMismatch(token);
    }

    function _basketState() internal view returns (uint256 value, bool funded) {
        address[] memory tokens = _constituents;
        IBasketOracle oracle_ = oracle;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 reserve = _reserves[tokens[i]];
            if (reserve == 0) continue;
            funded = true;
            value += oracle_.quote(tokens[i], reserve);
        }
    }

    function totalBasketValue() public view returns (uint256 value) {
        (value,) = _basketState();
    }

    function _contributionValue(uint256[] calldata amounts) private view returns (uint256 value) {
        address[] memory tokens = _constituents;
        IBasketOracle oracle_ = oracle;
        for (uint256 i; i < tokens.length; ++i) {
            if (amounts[i] == 0) continue;
            value += oracle_.quote(tokens[i], amounts[i]);
        }
    }

    function _sharesForValue(uint256 value) internal view returns (uint256 shares) {
        uint256 supply = totalSupply();
        (uint256 basketValue, bool funded) = _basketState();
        uint256 initialScale = 10 ** uint256(SHARE_DECIMALS - oracle.unitDecimals());
        if (supply == 0) {
            uint256 gross = value * initialScale;
            return gross <= MINIMUM_SHARES ? 0 : gross - MINIMUM_SHARES;
        }
        if (basketValue == 0) {
            if (funded) revert InvalidBasketValue();
            return value * initialScale;
        }
        return Math.mulDiv(value, supply, basketValue);
    }

    function previewContribute(uint256[] calldata amounts) public view returns (uint256 lpAmount) {
        _requireLength(amounts.length);
        uint256 value = _contributionValue(amounts);
        if (value == 0) return 0;
        return _sharesForValue(value);
    }

    function contribute(
        uint256[] calldata amounts,
        address receiver,
        uint256 minShares
    )
        external
        nonReentrant
        returns (uint256 lpAmount)
    {
        _beforeMutate();
        _authorizeContribution(msg.sender, receiver);
        _requireLength(amounts.length);
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidReceiver();

        uint256 value = _contributionValue(amounts);
        if (value == 0) revert ZeroAmount();

        bool firstContribution = totalSupply() == 0;
        lpAmount = _sharesForValue(value);
        if (lpAmount == 0) revert ZeroShares();
        if (lpAmount < minShares) revert InsufficientShares(minShares, lpAmount);

        address[] memory tokens = _constituents;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            _pull(tokens[i], amount);
            _reserves[tokens[i]] += amount;
        }

        if (firstContribution) _mint(DEAD_ADDRESS, MINIMUM_SHARES);
        _mint(receiver, lpAmount);
        emit Contributed(msg.sender, receiver, lpAmount, amounts);
    }

    function previewWithdraw(uint256 lpAmount) public view returns (uint256[] memory amounts) {
        address[] memory tokens = _constituents;
        amounts = new uint256[](tokens.length);
        uint256 supply = totalSupply();
        if (lpAmount == 0 || supply == 0) return amounts;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 reserve = _reserves[tokens[i]];
            amounts[i] = lpAmount == supply ? reserve : Math.mulDiv(reserve, lpAmount, supply);
        }
    }

    function withdraw(
        uint256 lpAmount,
        address receiver,
        uint256[] calldata minAmounts
    )
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        _beforeMutate();
        if (lpAmount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();
        if (receiver == address(this)) revert InvalidReceiver();
        _requireLength(minAmounts.length);
        if (totalSupply() == 0) revert ZeroSupply();

        amounts = previewWithdraw(lpAmount);
        for (uint256 i; i < amounts.length; ++i) {
            if (amounts[i] < minAmounts[i]) revert InsufficientAmount(i, minAmounts[i], amounts[i]);
        }

        _burn(msg.sender, lpAmount);

        address[] memory tokens = _constituents;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            _reserves[tokens[i]] -= amount;
            _push(tokens[i], receiver, amount);
        }

        emit Withdrawn(msg.sender, receiver, lpAmount, amounts);
    }

    function rebalance(address[] calldata newTokens, uint256[] calldata newWeights) external nonReentrant {
        _beforeMutate();
        _authorizeRebalance();
        _installConstituents(newTokens, newWeights);
        emit Rebalanced(newTokens, newWeights);
    }

    /// @dev Hook called at the start of every state-changing entrypoint.
    ///      ETFToken overrides this to accrue streaming fees first.
    function _beforeMutate() internal virtual { }
}
