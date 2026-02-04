// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";

import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";

import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";

/// @notice Per-user vault for agentic Uniswap v4 liquidity management (assume NO HOOK pools).
/// @dev
/// - Owner is the only one who can withdraw funds.
/// - Agent can only manage liquidity positions minted by this vault, and optional constrained swaps.
/// - All positions (ERC-721) are minted to this vault address.
/// - Tick bounds are mutable and apply to future mint/increase only.
/// - Existing out-of-bound positions remain usable for decrease/burn/collect, but cannot be increased.
/// - K limits max number of managed positions; K=0 means unlimited.
/// - This vault never approves position NFTs to the Universal Router.
contract V4AgenticVault is Ownable, ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // ---- immutable wiring ----
    IPositionManager public immutable posm;
    IUniversalRouter public immutable universalRouter;
    IPermit2 public immutable permit2;

    // ---- immutable pool params ----
    Currency public immutable currency0;
    Currency public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    address public immutable hooks;
    PoolId public immutable poolId;

    // ---- mutable risk bounds (Owner-updatable) ----
    int24 public allowedTickLower;
    int24 public allowedTickUpper;

    /// @notice Max number of managed positions. K=0 => unlimited.
    uint256 public maxPositionsK;

    // ---- agent controls ----
    address public agent;
    bool public agentPaused;
    bool public swapAllowed;

    // ---- managed positions ----
    uint256[] public positionIds; // tokenIds minted by this vault
    mapping(uint256 => bool) public isManagedPosition;
    mapping(uint256 => int24) public positionTickLower;
    mapping(uint256 => int24) public positionTickUpper;

    // ---- events ----
    event AgentUpdated(address indexed newAgent);
    event AgentPaused(bool paused);
    event SwapAllowed(bool allowed);

    event AllowedTickRangeUpdated(int24 tickLower, int24 tickUpper);
    event MaxPositionsKUpdated(uint256 k);

    event PositionAdded(uint256 indexed tokenId, int24 tickLower, int24 tickUpper);
    event PositionRemoved(uint256 indexed tokenId);

    modifier onlyAgentActive() {
        require(msg.sender == agent, "not agent");
        require(!agentPaused, "agent paused");
        _;
    }

    constructor(
        address _owner,
        address _agent,
        address _posm,
        address _universalRouter,
        address _permit2,
        PoolKey memory _poolKey,
        int24 _initialAllowedTickLower,
        int24 _initialAllowedTickUpper,
        bool _swapAllowed,
        uint256 _maxPositionsK
    ) Ownable(_owner) {
        require(_posm != address(0) && _universalRouter != address(0) && _permit2 != address(0), "bad addr");
        require(_initialAllowedTickLower < _initialAllowedTickUpper, "bad ticks");

        posm = IPositionManager(_posm);
        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IPermit2(_permit2);

        currency0 = _poolKey.currency0;
        currency1 = _poolKey.currency1;
        fee = _poolKey.fee;
        tickSpacing = _poolKey.tickSpacing;
        hooks = address(_poolKey.hooks);
        poolId = _poolKey.toId();

        agent = _agent;
        swapAllowed = _swapAllowed;

        allowedTickLower = _initialAllowedTickLower;
        allowedTickUpper = _initialAllowedTickUpper;

        maxPositionsK = _maxPositionsK;
    }

    /// @notice Keep receive() for native ETH funding (when pool uses native ETH).
    receive() external payable {}

    // =============================================================
    // Owner: configuration
    // =============================================================

    function setAgent(address newAgent) external onlyOwner {
        agent = newAgent;
        emit AgentUpdated(newAgent);
    }

    function setAgentPaused(bool paused) external onlyOwner {
        agentPaused = paused;
        emit AgentPaused(paused);
    }

    function setSwapAllowed(bool allowed) external onlyOwner {
        swapAllowed = allowed;
        emit SwapAllowed(allowed);
    }

    /// @notice Update allowed tick range. Applies to future mint/increase only.
    function setAllowedTickRange(int24 tickLower, int24 tickUpper) external onlyOwner {
        require(tickLower < tickUpper, "bad ticks");
        allowedTickLower = tickLower;
        allowedTickUpper = tickUpper;
        emit AllowedTickRangeUpdated(tickLower, tickUpper);
    }

    /// @notice Update K. K=0 means unlimited. Lowering below current count is allowed but blocks future mints.
    function setMaxPositionsK(uint256 k) external onlyOwner {
        maxPositionsK = k;
        emit MaxPositionsKUpdated(k);
    }

    /// @notice Set Permit2 allowance for a spender (PositionManager or UniversalRouter).
    /// @dev Must also approve the Permit2 contract at the ERC20 level first.
    function approveTokenWithPermit2(
        Currency currency,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external onlyOwner {
        require(spender == address(posm) || spender == address(universalRouter), "spender not allowed");
        require(!currency.isAddressZero(), "native ETH no permit2");

        address token = Currency.unwrap(currency);

        IERC20(token).forceApprove(address(permit2), type(uint256).max);
        permit2.approve(token, spender, amount, expiration);
    }

    // =============================================================
    // Owner: funds out (no deposit API; users transfer tokens/ETH directly)
    // =============================================================

    function withdraw(Currency currency, uint256 amount, address to) external onlyOwner nonReentrant {
        require(to != address(0), "bad to");
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "eth transfer failed");
        } else {
            IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        }
    }

    /// @notice Owner safety lever: pause agent and burn all managed positions into vault.
    /// @dev Uses 0 for min amounts to guarantee exit succeeds regardless of slippage.
    function pauseAndExitAll(uint256 deadline) external onlyOwner nonReentrant {
        agentPaused = true;
        emit AgentPaused(true);

        for (uint256 i = positionIds.length; i > 0; i--) {
            uint256 tokenId = positionIds[i - 1];
            _burnPositionToVault(tokenId, 0, 0, deadline);
        }
    }

    // =============================================================
    // Agent: liquidity management (NO HOOK)
    // =============================================================

    function mintPosition(
        int24 tickLower,
        int24 tickUpper,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external onlyAgentActive nonReentrant returns (uint256 tokenId) {
        _enforceKForMint();
        _validateTicksForMintOrIncrease(tickLower, tickUpper);

        tokenId = posm.nextTokenId();

        bytes memory actions;
        bytes[] memory params;

        bool useNativeETH = currency0.isAddressZero();

        if (useNativeETH) {
            // MINT_POSITION + SETTLE_PAIR + CLEAR_OR_TAKE (refund excess ETH)
            actions = abi.encodePacked(
                uint8(Actions.MINT_POSITION),
                uint8(Actions.SETTLE_PAIR),
                uint8(Actions.CLEAR_OR_TAKE)
            );
            params = new bytes[](3);
            params[2] = abi.encode(currency0, uint256(0)); // take any excess ETH
        } else {
            // MINT_POSITION + SETTLE_PAIR
            actions = abi.encodePacked(
                uint8(Actions.MINT_POSITION),
                uint8(Actions.SETTLE_PAIR)
            );
            params = new bytes[](2);
        }

        // hookData empty (no-hook pool assumption)
        params[0] = abi.encode(
            getPoolKey(),
            tickLower,
            tickUpper,
            liquidity,
            amount0Max,
            amount1Max,
            address(this),
            bytes("")
        );

        params[1] = abi.encode(currency0, currency1);

        uint256 nativeValue = useNativeETH ? uint256(amount0Max) : 0;

        posm.modifyLiquidities{value: nativeValue}(abi.encode(actions, params), deadline);

        _addManagedPosition(tokenId, tickLower, tickUpper);
    }

    function increaseLiquidity(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        uint256 deadline
    ) external onlyAgentActive nonReentrant {
        require(isManagedPosition[tokenId], "unknown tokenId");

        // New PRD rule: if existing position is out-of-bound under current allowed range, do not allow increase.
        _validateExistingPositionInBounds(tokenId);

        bytes memory actions;
        bytes[] memory params;

        bool useNativeETH = currency0.isAddressZero();

        if (useNativeETH) {
            // INCREASE_LIQUIDITY + SETTLE_PAIR + CLEAR_OR_TAKE (refund excess ETH)
            actions = abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.SETTLE_PAIR),
                uint8(Actions.CLEAR_OR_TAKE)
            );
            params = new bytes[](3);
            params[2] = abi.encode(currency0, uint256(0)); // take any excess ETH
        } else {
            // INCREASE_LIQUIDITY + SETTLE_PAIR
            actions = abi.encodePacked(
                uint8(Actions.INCREASE_LIQUIDITY),
                uint8(Actions.SETTLE_PAIR)
            );
            params = new bytes[](2);
        }

        params[0] = abi.encode(tokenId, liquidity, amount0Max, amount1Max, bytes(""));
        params[1] = abi.encode(currency0, currency1);

        uint256 nativeValue = useNativeETH ? uint256(amount0Max) : 0;

        posm.modifyLiquidities{value: nativeValue}(abi.encode(actions, params), deadline);
    }

    /// @notice Decrease liquidity and take both tokens back into the vault.
    /// @dev Allowed even if the position is currently out-of-bound under updated tick range.
    function decreaseLiquidityToVault(
        uint256 tokenId,
        uint256 liquidity,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external onlyAgentActive nonReentrant {
        require(isManagedPosition[tokenId], "unknown tokenId");

        // DECREASE_LIQUIDITY + TAKE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(tokenId, liquidity, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(currency0, currency1, address(this));

        posm.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @notice Collect fees using the "zero-liquidity decrease" pattern.
    /// @dev Allowed even if the position is currently out-of-bound under updated tick range.
    function collectFeesToVault(
        uint256 tokenId,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external onlyAgentActive nonReentrant {
        require(isManagedPosition[tokenId], "unknown tokenId");

        // DECREASE_LIQUIDITY (liquidity=0) + TAKE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(tokenId, uint256(0), amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(currency0, currency1, address(this));

        posm.modifyLiquidities(abi.encode(actions, params), deadline);
    }

    /// @dev Allowed even if the position is currently out-of-bound under updated tick range.
    function burnPositionToVault(
        uint256 tokenId,
        uint128 amount0Min,
        uint128 amount1Min,
        uint256 deadline
    ) external onlyAgentActive nonReentrant {
        _burnPositionToVault(tokenId, amount0Min, amount1Min, deadline);
    }

    // =============================================================
    // Agent: constrained swap (optional)
    // =============================================================

    /// @notice Swap exact input in this vault's poolKey only (single-hop, exact-in).
    function swapExactInputSingle(
        bool zeroForOne,
        uint128 amountIn,
        uint128 minAmountOut,
        uint256 deadline
    ) external onlyAgentActive nonReentrant returns (uint256 amountOut) {
        require(swapAllowed, "swap disabled");

        Currency inCur = zeroForOne ? currency0 : currency1;
        Currency outCur = zeroForOne ? currency1 : currency0;

        uint256 balBefore = outCur.balanceOf(address(this));

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // SWAP_EXACT_IN_SINGLE -> SETTLE_ALL -> TAKE_ALL
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);

        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: getPoolKey(),
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: bytes("") // no hook
            })
        );

        params[1] = abi.encode(inCur, amountIn);       // settle input
        params[2] = abi.encode(outCur, minAmountOut);  // take output

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

        uint256 nativeValue = inCur.isAddressZero() ? uint256(amountIn) : 0;

        universalRouter.execute{value: nativeValue}(commands, inputs, deadline);

        uint256 balAfter = outCur.balanceOf(address(this));
        amountOut = balAfter - balBefore;
        require(amountOut >= minAmountOut, "insufficient out");
    }

    // =============================================================
    // Views
    // =============================================================

    /// @notice Reconstruct the PoolKey from immutable fields.
    function getPoolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
    }

    function positionsLength() external view returns (uint256) {
        return positionIds.length;
    }

    // =============================================================
    // Internals
    // =============================================================

    function _enforceKForMint() internal view {
        uint256 k = maxPositionsK;
        if (k != 0) {
            require(positionIds.length < k, "max positions reached");
        }
    }

    function _validateTicksForMintOrIncrease(int24 tickLower, int24 tickUpper) internal view {
        require(tickLower < tickUpper, "tick order");
        require(tickLower >= allowedTickLower, "tickLower too low");
        require(tickUpper <= allowedTickUpper, "tickUpper too high");

        require(tickSpacing > 0, "bad tickSpacing");

        require(tickLower % tickSpacing == 0, "tickLower !multiple");
        require(tickUpper % tickSpacing == 0, "tickUpper !multiple");
    }

    function _validateExistingPositionInBounds(uint256 tokenId) internal view {
        int24 tl = positionTickLower[tokenId];
        int24 tu = positionTickUpper[tokenId];
        require(tl >= allowedTickLower && tu <= allowedTickUpper, "position out of bounds");
    }

    function _addManagedPosition(uint256 tokenId, int24 tickLower, int24 tickUpper) internal {
        isManagedPosition[tokenId] = true;
        positionTickLower[tokenId] = tickLower;
        positionTickUpper[tokenId] = tickUpper;
        positionIds.push(tokenId);
        emit PositionAdded(tokenId, tickLower, tickUpper);
    }

    function _removeManagedPosition(uint256 tokenId) internal {
        require(isManagedPosition[tokenId], "not managed");
        isManagedPosition[tokenId] = false;
        delete positionTickLower[tokenId];
        delete positionTickUpper[tokenId];

        uint256 n = positionIds.length;
        for (uint256 i = 0; i < n; i++) {
            if (positionIds[i] == tokenId) {
                if (i != n - 1) positionIds[i] = positionIds[n - 1];
                positionIds.pop();
                break;
            }
        }
        emit PositionRemoved(tokenId);
    }

    function _burnPositionToVault(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, uint256 deadline) internal {
        require(isManagedPosition[tokenId], "unknown tokenId");

        // BURN_POSITION + TAKE_PAIR
        bytes memory actions = abi.encodePacked(uint8(Actions.BURN_POSITION), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(tokenId, amount0Min, amount1Min, bytes(""));
        params[1] = abi.encode(currency0, currency1, address(this));

        posm.modifyLiquidities(abi.encode(actions, params), deadline);

        _removeManagedPosition(tokenId);
    }

    // =============================================================
    // ERC721 receiver
    // =============================================================

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
