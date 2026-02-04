// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {V4AgenticVault} from "../src/V4AgenticVault.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Fork test for V4AgenticVault against Ethereum mainnet
/// @dev Run with: forge test --match-contract V4AgenticVaultForkTest --fork-url $MAINNET_RPC_URL -vvv
contract V4AgenticVaultForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // ============================================================
    // Mainnet Addresses
    // ============================================================

    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    // ============================================================
    // Pool Parameters (ETH/USDC 0.3%)
    // ============================================================

    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;
    address constant HOOKS = address(0); // no hooks

    // ============================================================
    // Test State
    // ============================================================

    V4AgenticVault public vault;
    IPoolManager public poolManager;
    IPositionManager public posm;
    IUniversalRouter public universalRouter;
    IPermit2 public permit2;
    IERC20 public usdc;

    PoolKey public poolKey;
    PoolId public poolId;

    address public owner;
    address public agent;

    // Tick bounds for testing (wide range around current price)
    int24 public allowedTickLower;
    int24 public allowedTickUpper;

    // ============================================================
    // Setup
    // ============================================================

    function setUp() public {
        // Try to get fork URL from environment, skip if not set
        string memory forkUrl = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(forkUrl).length == 0) {
            return; // Skip setup if no fork URL
        }

        // Create fork
        vm.createSelectFork(forkUrl);

        // Create test accounts
        owner = makeAddr("owner");
        agent = makeAddr("agent");

        // Get contract instances
        poolManager = IPoolManager(POOL_MANAGER);
        posm = IPositionManager(POSITION_MANAGER);
        universalRouter = IUniversalRouter(UNIVERSAL_ROUTER);
        permit2 = IPermit2(PERMIT2);
        usdc = IERC20(USDC);

        // Set up pool key for ETH/USDC 0.3%
        // Note: currency0 must be < currency1, ETH (address(0)) < USDC
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(USDC),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOKS)
        });
        poolId = poolKey.toId();

        // Get current tick to set reasonable bounds
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // If pool doesn't exist or has no liquidity, skip
        if (sqrtPriceX96 == 0) {
            console2.log("Pool not initialized, skipping test setup");
            return;
        }

        console2.log("Current tick:", currentTick);
        console2.log("Current sqrtPriceX96:", sqrtPriceX96);

        // Set allowed tick range: +/- 10000 ticks from current (wide range)
        // Round to tick spacing
        allowedTickLower = ((currentTick - 10000) / TICK_SPACING) * TICK_SPACING;
        allowedTickUpper = ((currentTick + 10000) / TICK_SPACING) * TICK_SPACING;

        console2.log("Allowed tick lower:", allowedTickLower);
        console2.log("Allowed tick upper:", allowedTickUpper);

        // Deploy vault
        vault = new V4AgenticVault(
            owner,
            agent,
            address(posm),
            address(universalRouter),
            address(permit2),
            poolKey,
            allowedTickLower,
            allowedTickUpper,
            true, // swapAllowed
            0 // maxPositionsK (unlimited)
        );

        // Fund the vault
        vm.deal(address(vault), 100 ether);
        deal(USDC, address(vault), 200_000 * 1e6); // 200k USDC

        // Owner approves tokens via Permit2 for PositionManager
        vm.startPrank(owner);
        vault.approveTokenWithPermit2(
            Currency.wrap(USDC), address(posm), type(uint160).max, uint48(block.timestamp + 365 days)
        );
        vault.approveTokenWithPermit2(
            Currency.wrap(USDC), address(universalRouter), type(uint160).max, uint48(block.timestamp + 365 days)
        );
        vm.stopPrank();

        console2.log("Vault deployed at:", address(vault));
        console2.log("Vault ETH balance:", address(vault).balance);
        console2.log("Vault USDC balance:", usdc.balanceOf(address(vault)));
    }

    // ============================================================
    // Helper Functions
    // ============================================================

    function _getTicksAroundCurrent(int24 tickOffset) internal view returns (int24 tickLower, int24 tickUpper) {
        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        // Round down to tick spacing
        int24 roundedTick = (currentTick / TICK_SPACING) * TICK_SPACING;

        tickLower = roundedTick - tickOffset;
        tickUpper = roundedTick + tickOffset;
    }

    function _skipIfPoolNotInitialized() internal view {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            console2.log("Pool not initialized, skipping test");
            return;
        }
    }

    // ============================================================
    // Fork Tests
    // ============================================================

    function test_Fork_VaultDeployment() public view {
        _skipIfPoolNotInitialized();

        assertEq(vault.owner(), owner);
        assertEq(vault.agent(), agent);
        assertEq(address(vault.posm()), address(posm));
        assertEq(address(vault.universalRouter()), address(universalRouter));
        assertEq(address(vault.permit2()), address(permit2));

        // Check pool key
        PoolKey memory key = vault.getPoolKey();
        assertTrue(key.currency0.isAddressZero());
        assertEq(Currency.unwrap(key.currency1), USDC);
        assertEq(key.fee, FEE);
        assertEq(key.tickSpacing, TICK_SPACING);
    }

    function test_Fork_MintPosition() public {
        _skipIfPoolNotInitialized();

        // Get ticks around current price
        (int24 tickLower, int24 tickUpper) = _getTicksAroundCurrent(600); // +/- 600 ticks

        console2.log("Minting position with tickLower:", int256(tickLower));
        console2.log("Minting position with tickUpper:", int256(tickUpper));

        // Use smaller liquidity - at current tick, ETH is heavily weighted
        uint256 liquidity = 1e15; // Much smaller liquidity unit
        uint128 amount0Max = 10 ether; // More ETH headroom
        uint128 amount1Max = 30000 * 1e6; // ~30000 USDC
        uint256 deadline = block.timestamp + 1 hours;

        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        vm.prank(agent);
        uint256 tokenId = vault.mintPosition(tickLower, tickUpper, liquidity, amount0Max, amount1Max, deadline);

        console2.log("Minted position tokenId:", tokenId);
        console2.log("ETH spent:", ethBefore - address(vault).balance);
        console2.log("USDC spent:", usdcBefore - usdc.balanceOf(address(vault)));

        assertTrue(vault.isManagedPosition(tokenId));
        assertEq(vault.positionsLength(), 1);
        assertEq(vault.positionTickLower(tokenId), tickLower);
        assertEq(vault.positionTickUpper(tokenId), tickUpper);
    }

    function test_Fork_MintAndIncreaseLiquidity() public {
        _skipIfPoolNotInitialized();

        (int24 tickLower, int24 tickUpper) = _getTicksAroundCurrent(600);

        // Mint initial position
        vm.prank(agent);
        uint256 tokenId =
            vault.mintPosition(tickLower, tickUpper, 1e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours);

        console2.log("Initial position minted:", tokenId);

        // Increase liquidity
        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        vm.prank(agent);
        vault.increaseLiquidity(
            tokenId,
            1e15, // additional liquidity
            10 ether,
            30000 * 1e6,
            block.timestamp + 1 hours
        );

        console2.log("Liquidity increased");
        console2.log("Additional ETH spent:", ethBefore - address(vault).balance);
        console2.log("Additional USDC spent:", usdcBefore - usdc.balanceOf(address(vault)));

        assertTrue(vault.isManagedPosition(tokenId));
    }

    function test_Fork_MintAndDecreaseLiquidity() public {
        _skipIfPoolNotInitialized();

        (int24 tickLower, int24 tickUpper) = _getTicksAroundCurrent(600);

        // Mint position
        vm.prank(agent);
        uint256 tokenId =
            vault.mintPosition(tickLower, tickUpper, 1e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours);

        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        // Decrease liquidity
        vm.prank(agent);
        vault.decreaseLiquidityToVault(
            tokenId,
            0.5e15, // remove half
            0, // min amount0
            0, // min amount1
            block.timestamp + 1 hours
        );

        console2.log("Liquidity decreased");
        console2.log("ETH received:", address(vault).balance - ethBefore);
        console2.log("USDC received:", usdc.balanceOf(address(vault)) - usdcBefore);

        assertTrue(vault.isManagedPosition(tokenId));
    }

    function test_Fork_MintAndBurnPosition() public {
        _skipIfPoolNotInitialized();

        (int24 tickLower, int24 tickUpper) = _getTicksAroundCurrent(600);

        // Mint position
        vm.prank(agent);
        uint256 tokenId =
            vault.mintPosition(tickLower, tickUpper, 1e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 1);

        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        // Burn position
        vm.prank(agent);
        vault.burnPositionToVault(
            tokenId,
            0, // min amount0
            0, // min amount1
            block.timestamp + 1 hours
        );

        console2.log("Position burned");
        console2.log("ETH received:", address(vault).balance - ethBefore);
        console2.log("USDC received:", usdc.balanceOf(address(vault)) - usdcBefore);

        assertFalse(vault.isManagedPosition(tokenId));
        assertEq(vault.positionsLength(), 0);
    }

    function test_Fork_SwapExactInputSingle_ETHtoUSDC() public {
        _skipIfPoolNotInitialized();

        uint128 amountIn = 0.1 ether;
        uint128 minAmountOut = 100 * 1e6; // expect at least 100 USDC (very conservative)

        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        vm.prank(agent);
        uint256 amountOut = vault.swapExactInputSingle(
            true, // zeroForOne (ETH -> USDC)
            amountIn,
            minAmountOut,
            block.timestamp + 1 hours
        );

        console2.log("Swapped ETH -> USDC");
        console2.log("ETH in:", amountIn);
        console2.log("USDC out:", amountOut);
        console2.log("Effective price (USDC per ETH):", amountOut * 1e12 / amountIn); // adjust decimals

        assertEq(ethBefore - address(vault).balance, amountIn);
        assertEq(usdc.balanceOf(address(vault)) - usdcBefore, amountOut);
        assertGe(amountOut, minAmountOut);
    }

    function test_Fork_SwapExactInputSingle_USDCtoETH() public {
        _skipIfPoolNotInitialized();

        uint128 amountIn = 1000 * 1e6; // 1000 USDC
        uint128 minAmountOut = 0.1 ether; // expect at least 0.1 ETH (very conservative)

        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        vm.prank(agent);
        uint256 amountOut = vault.swapExactInputSingle(
            false, // oneForZero (USDC -> ETH)
            amountIn,
            minAmountOut,
            block.timestamp + 1 hours
        );

        console2.log("Swapped USDC -> ETH");
        console2.log("USDC in:", amountIn);
        console2.log("ETH out:", amountOut);

        assertEq(usdcBefore - usdc.balanceOf(address(vault)), amountIn);
        assertEq(address(vault).balance - ethBefore, amountOut);
        assertGe(amountOut, minAmountOut);
    }

    function test_Fork_FullLifecycle() public {
        _skipIfPoolNotInitialized();

        console2.log("\n=== Full Lifecycle Test ===\n");

        (int24 tickLower, int24 tickUpper) = _getTicksAroundCurrent(600);

        // 1. Mint position
        console2.log("1. Minting position...");
        vm.prank(agent);
        uint256 tokenId =
            vault.mintPosition(tickLower, tickUpper, 1e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours);
        console2.log("   Position minted:", tokenId);

        // 2. Increase liquidity
        console2.log("2. Increasing liquidity...");
        vm.prank(agent);
        vault.increaseLiquidity(tokenId, 0.5e15, 5 ether, 15000 * 1e6, block.timestamp + 1 hours);
        console2.log("   Liquidity increased");

        // 3. Perform a swap to generate fees
        console2.log("3. Performing swap to generate fees...");
        vm.prank(agent);
        vault.swapExactInputSingle(true, 0.5 ether, 0, block.timestamp + 1 hours);
        console2.log("   Swap completed");

        // 4. Collect fees
        console2.log("4. Collecting fees...");
        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        vm.prank(agent);
        vault.collectFeesToVault(tokenId, 0, 0, block.timestamp + 1 hours);

        console2.log("   ETH fees:", address(vault).balance - ethBefore);
        console2.log("   USDC fees:", usdc.balanceOf(address(vault)) - usdcBefore);

        // 5. Decrease liquidity
        console2.log("5. Decreasing liquidity...");
        vm.prank(agent);
        vault.decreaseLiquidityToVault(tokenId, 0.5e15, 0, 0, block.timestamp + 1 hours);
        console2.log("   Liquidity decreased");

        // 6. Burn position
        console2.log("6. Burning position...");
        vm.prank(agent);
        vault.burnPositionToVault(tokenId, 0, 0, block.timestamp + 1 hours);
        console2.log("   Position burned");

        assertEq(vault.positionsLength(), 0);
        console2.log("\n=== Lifecycle Complete ===\n");
    }

    function test_Fork_OwnerPauseAndExitAll() public {
        _skipIfPoolNotInitialized();

        (int24 tickLower, int24 tickUpper) = _getTicksAroundCurrent(600);

        // Mint multiple positions
        vm.startPrank(agent);
        vault.mintPosition(tickLower, tickUpper, 1e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours);
        vault.mintPosition(tickLower - 600, tickUpper + 600, 0.5e15, 5 ether, 15000 * 1e6, block.timestamp + 1 hours);
        vm.stopPrank();

        assertEq(vault.positionsLength(), 2);
        console2.log("Created 2 positions");

        uint256 ethBefore = address(vault).balance;
        uint256 usdcBefore = usdc.balanceOf(address(vault));

        // Owner emergency exit
        vm.prank(owner);
        vault.pauseAndExitAll(block.timestamp + 1 hours);

        console2.log("Emergency exit completed");
        console2.log("ETH recovered:", address(vault).balance - ethBefore);
        console2.log("USDC recovered:", usdc.balanceOf(address(vault)) - usdcBefore);

        assertTrue(vault.agentPaused());
        assertEq(vault.positionsLength(), 0);
    }

    function test_Fork_MultiplePositions() public {
        _skipIfPoolNotInitialized();

        (int24 tickLower, int24 tickUpper) = _getTicksAroundCurrent(300);

        vm.startPrank(agent);

        // Mint 3 positions at different ranges
        uint256 tokenId1 =
            vault.mintPosition(tickLower, tickUpper, 0.5e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours);

        uint256 tokenId2 = vault.mintPosition(
            tickLower - 600, tickUpper + 600, 0.5e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours
        );

        uint256 tokenId3 = vault.mintPosition(
            tickLower - 1200, tickUpper + 1200, 0.5e15, 10 ether, 30000 * 1e6, block.timestamp + 1 hours
        );

        vm.stopPrank();

        console2.log("Created 3 positions:", tokenId1, tokenId2, tokenId3);
        assertEq(vault.positionsLength(), 3);

        // Burn middle position
        vm.prank(agent);
        vault.burnPositionToVault(tokenId2, 0, 0, block.timestamp + 1 hours);

        assertEq(vault.positionsLength(), 2);
        assertTrue(vault.isManagedPosition(tokenId1));
        assertFalse(vault.isManagedPosition(tokenId2));
        assertTrue(vault.isManagedPosition(tokenId3));
    }
}
