// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {V4AgenticVaultFactory} from "../src/V4AgenticVaultFactory.sol";
import {V4AgenticVault} from "../src/V4AgenticVault.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract V4AgenticVaultFactoryTest is Test {
    V4AgenticVaultFactory public factory;

    address public posm = makeAddr("posm");
    address public universalRouter = makeAddr("universalRouter");
    address public permit2 = makeAddr("permit2");

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public agent = makeAddr("agent");

    address public token0;
    address public token1;
    PoolKey public poolKey;

    int24 constant TICK_SPACING = 60;
    uint24 constant FEE = 3000;
    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;

    event VaultCreated(
        address indexed creator,
        address indexed vault,
        PoolKey poolKey,
        address agent,
        uint256 nonce
    );

    function setUp() public {
        factory = new V4AgenticVaultFactory(posm, universalRouter, permit2);

        // Create mock tokens with proper ordering
        token0 = makeAddr("token0");
        token1 = makeAddr("token1");
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    // ============================================================
    // Constructor Tests
    // ============================================================

    function test_Constructor() public view {
        assertEq(factory.posm(), posm);
        assertEq(factory.universalRouter(), universalRouter);
        assertEq(factory.permit2(), permit2);
        assertEq(factory.totalVaults(), 0);
    }

    function test_Constructor_RevertBadPosm() public {
        vm.expectRevert("bad posm");
        new V4AgenticVaultFactory(address(0), universalRouter, permit2);
    }

    function test_Constructor_RevertBadUniversalRouter() public {
        vm.expectRevert("bad universalRouter");
        new V4AgenticVaultFactory(posm, address(0), permit2);
    }

    function test_Constructor_RevertBadPermit2() public {
        vm.expectRevert("bad permit2");
        new V4AgenticVaultFactory(posm, universalRouter, address(0));
    }

    // ============================================================
    // createVault Tests
    // ============================================================

    function test_CreateVault() public {
        vm.prank(user1);
        address vault = factory.createVault(
            poolKey,
            agent,
            TICK_LOWER,
            TICK_UPPER,
            true,
            0
        );

        // Verify vault is tracked
        assertTrue(factory.isVault(vault));
        assertEq(factory.totalVaults(), 1);
        assertEq(factory.vaults(0), vault);

        // Verify creator tracking
        address[] memory user1Vaults = factory.getVaultsCreatedBy(user1);
        assertEq(user1Vaults.length, 1);
        assertEq(user1Vaults[0], vault);

        // Verify nonce incremented
        assertEq(factory.getNextNonce(user1), 1);

        // Verify vault configuration
        V4AgenticVault v = V4AgenticVault(payable(vault));
        assertEq(v.owner(), user1);
        assertEq(v.agent(), agent);
        assertEq(address(v.posm()), posm);
        assertEq(address(v.universalRouter()), universalRouter);
        assertEq(address(v.permit2()), permit2);
        assertEq(v.allowedTickLower(), TICK_LOWER);
        assertEq(v.allowedTickUpper(), TICK_UPPER);
        assertEq(v.swapAllowed(), true);
        assertEq(v.maxPositionsK(), 0);
    }

    function test_CreateVault_EmitsEvent() public {
        uint256 expectedNonce = factory.getNextNonce(user1);

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit VaultCreated(user1, address(0), poolKey, agent, expectedNonce); // address checked separately

        factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
    }

    function test_CreateVault_MultipleByOneUser() public {
        vm.startPrank(user1);

        address vault1 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        address vault2 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, false, 5);
        address vault3 = factory.createVault(poolKey, agent, -1000, 1000, true, 10);

        vm.stopPrank();

        // All vaults are different
        assertTrue(vault1 != vault2);
        assertTrue(vault2 != vault3);
        assertTrue(vault1 != vault3);

        // All tracked
        assertEq(factory.totalVaults(), 3);
        assertTrue(factory.isVault(vault1));
        assertTrue(factory.isVault(vault2));
        assertTrue(factory.isVault(vault3));

        // Creator tracking
        address[] memory user1Vaults = factory.getVaultsCreatedBy(user1);
        assertEq(user1Vaults.length, 3);
        assertEq(user1Vaults[0], vault1);
        assertEq(user1Vaults[1], vault2);
        assertEq(user1Vaults[2], vault3);

        // Nonce
        assertEq(factory.getNextNonce(user1), 3);
    }

    function test_CreateVault_MultipleUsers() public {
        vm.prank(user1);
        address vault1 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);

        vm.prank(user2);
        address vault2 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);

        // Different addresses (different creators = different salt)
        assertTrue(vault1 != vault2);

        // Both tracked
        assertEq(factory.totalVaults(), 2);

        // Separate creator tracking
        assertEq(factory.getVaultsCreatedBy(user1).length, 1);
        assertEq(factory.getVaultsCreatedBy(user2).length, 1);
        assertEq(factory.getVaultsCreatedBy(user1)[0], vault1);
        assertEq(factory.getVaultsCreatedBy(user2)[0], vault2);

        // Separate nonces
        assertEq(factory.getNextNonce(user1), 1);
        assertEq(factory.getNextNonce(user2), 1);
    }

    function test_CreateVault_DifferentPoolKeys() public {
        PoolKey memory poolKey2 = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 500, // Different fee
            tickSpacing: 10,
            hooks: IHooks(address(0))
        });

        vm.startPrank(user1);
        address vault1 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        address vault2 = factory.createVault(poolKey2, agent, -887270, 887270, true, 0);
        vm.stopPrank();

        assertTrue(vault1 != vault2);
        assertEq(factory.totalVaults(), 2);
    }

    function test_CreateVault_WithZeroAgent() public {
        vm.prank(user1);
        address vault = factory.createVault(
            poolKey,
            address(0),
            TICK_LOWER,
            TICK_UPPER,
            true,
            0
        );

        V4AgenticVault v = V4AgenticVault(payable(vault));
        assertEq(v.agent(), address(0));
    }

    function test_CreateVault_SwapDisabled() public {
        vm.prank(user1);
        address vault = factory.createVault(
            poolKey,
            agent,
            TICK_LOWER,
            TICK_UPPER,
            false,
            0
        );

        V4AgenticVault v = V4AgenticVault(payable(vault));
        assertEq(v.swapAllowed(), false);
    }

    function test_CreateVault_WithMaxPositionsK() public {
        vm.prank(user1);
        address vault = factory.createVault(
            poolKey,
            agent,
            TICK_LOWER,
            TICK_UPPER,
            true,
            5
        );

        V4AgenticVault v = V4AgenticVault(payable(vault));
        assertEq(v.maxPositionsK(), 5);
    }

    // ============================================================
    // computeVaultAddress Tests
    // ============================================================

    function test_ComputeVaultAddress_MatchesActual() public {
        uint256 nonce = factory.getNextNonce(user1);

        address predicted = factory.computeVaultAddress(
            user1,
            poolKey,
            nonce,
            agent,
            TICK_LOWER,
            TICK_UPPER,
            true,
            0
        );

        vm.prank(user1);
        address actual = factory.createVault(
            poolKey,
            agent,
            TICK_LOWER,
            TICK_UPPER,
            true,
            0
        );

        assertEq(predicted, actual);
    }

    function test_ComputeVaultAddress_DifferentParams() public {
        uint256 nonce = factory.getNextNonce(user1);

        address addr1 = factory.computeVaultAddress(
            user1, poolKey, nonce, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        address addr2 = factory.computeVaultAddress(
            user1, poolKey, nonce, agent, TICK_LOWER, TICK_UPPER, false, 0
        );

        address addr3 = factory.computeVaultAddress(
            user1, poolKey, nonce, agent, -1000, 1000, true, 0
        );

        address addr4 = factory.computeVaultAddress(
            user1, poolKey, nonce, makeAddr("differentAgent"), TICK_LOWER, TICK_UPPER, true, 0
        );

        // All different because constructor args are part of init code hash
        assertTrue(addr1 != addr2);
        assertTrue(addr1 != addr3);
        assertTrue(addr1 != addr4);
    }

    function test_ComputeVaultAddress_DifferentNonces() public {
        address addr0 = factory.computeVaultAddress(
            user1, poolKey, 0, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        address addr1 = factory.computeVaultAddress(
            user1, poolKey, 1, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        address addr2 = factory.computeVaultAddress(
            user1, poolKey, 2, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        assertTrue(addr0 != addr1);
        assertTrue(addr1 != addr2);
        assertTrue(addr0 != addr2);
    }

    function test_ComputeVaultAddress_DifferentCreators() public {
        address addr1 = factory.computeVaultAddress(
            user1, poolKey, 0, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        address addr2 = factory.computeVaultAddress(
            user2, poolKey, 0, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        assertTrue(addr1 != addr2);
    }

    function test_ComputeVaultAddress_MultipleVaults() public {
        // Predict first 3 vault addresses
        address predicted0 = factory.computeVaultAddress(
            user1, poolKey, 0, agent, TICK_LOWER, TICK_UPPER, true, 0
        );
        address predicted1 = factory.computeVaultAddress(
            user1, poolKey, 1, agent, TICK_LOWER, TICK_UPPER, true, 0
        );
        address predicted2 = factory.computeVaultAddress(
            user1, poolKey, 2, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        // Create them
        vm.startPrank(user1);
        address actual0 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        address actual1 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        address actual2 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        vm.stopPrank();

        assertEq(predicted0, actual0);
        assertEq(predicted1, actual1);
        assertEq(predicted2, actual2);
    }

    // ============================================================
    // View Function Tests
    // ============================================================

    function test_GetVaultsCreatedBy_Empty() public view {
        address[] memory vaults = factory.getVaultsCreatedBy(user1);
        assertEq(vaults.length, 0);
    }

    function test_GetAllVaults_Empty() public view {
        address[] memory vaults = factory.getAllVaults();
        assertEq(vaults.length, 0);
    }

    function test_GetAllVaults() public {
        vm.prank(user1);
        address vault1 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);

        vm.prank(user2);
        address vault2 = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);

        address[] memory allVaults = factory.getAllVaults();
        assertEq(allVaults.length, 2);
        assertEq(allVaults[0], vault1);
        assertEq(allVaults[1], vault2);
    }

    function test_TotalVaults() public {
        assertEq(factory.totalVaults(), 0);

        vm.prank(user1);
        factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        assertEq(factory.totalVaults(), 1);

        vm.prank(user1);
        factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        assertEq(factory.totalVaults(), 2);

        vm.prank(user2);
        factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        assertEq(factory.totalVaults(), 3);
    }

    function test_GetNextNonce() public {
        assertEq(factory.getNextNonce(user1), 0);
        assertEq(factory.getNextNonce(user2), 0);

        vm.prank(user1);
        factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);

        assertEq(factory.getNextNonce(user1), 1);
        assertEq(factory.getNextNonce(user2), 0);

        vm.prank(user1);
        factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);

        assertEq(factory.getNextNonce(user1), 2);
    }

    function test_IsVault() public {
        assertFalse(factory.isVault(user1));
        assertFalse(factory.isVault(address(factory)));

        vm.prank(user1);
        address vault = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);

        assertTrue(factory.isVault(vault));
        assertFalse(factory.isVault(user1));
    }

    // ============================================================
    // Edge Cases
    // ============================================================

    function test_CreateVault_RevertBadTicks() public {
        vm.prank(user1);
        vm.expectRevert("bad ticks");
        factory.createVault(poolKey, agent, 100, 100, true, 0); // tickLower == tickUpper
    }

    function test_CreateVault_RevertTickLowerGreaterThanUpper() public {
        vm.prank(user1);
        vm.expectRevert("bad ticks");
        factory.createVault(poolKey, agent, 100, -100, true, 0);
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    function testFuzz_CreateVault(
        int24 tickLower,
        int24 tickUpper,
        bool swapAllowed,
        uint256 maxPositionsK
    ) public {
        // Bound ticks to valid range
        tickLower = int24(bound(tickLower, -887220, 887219));
        tickUpper = int24(bound(tickUpper, tickLower + 1, 887220));

        vm.prank(user1);
        address vault = factory.createVault(
            poolKey,
            agent,
            tickLower,
            tickUpper,
            swapAllowed,
            maxPositionsK
        );

        assertTrue(factory.isVault(vault));

        V4AgenticVault v = V4AgenticVault(payable(vault));
        assertEq(v.allowedTickLower(), tickLower);
        assertEq(v.allowedTickUpper(), tickUpper);
        assertEq(v.swapAllowed(), swapAllowed);
        assertEq(v.maxPositionsK(), maxPositionsK);
    }

    function testFuzz_ComputeVaultAddress(uint256 nonce) public {
        nonce = bound(nonce, 0, 100);

        // Create vaults up to nonce
        vm.startPrank(user1);
        for (uint256 i = 0; i < nonce; i++) {
            factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        }

        // Predict and create the next one
        address predicted = factory.computeVaultAddress(
            user1, poolKey, nonce, agent, TICK_LOWER, TICK_UPPER, true, 0
        );

        address actual = factory.createVault(poolKey, agent, TICK_LOWER, TICK_UPPER, true, 0);
        vm.stopPrank();

        assertEq(predicted, actual);
    }
}
