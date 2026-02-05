// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {V4AgenticVault} from "../src/V4AgenticVault.sol";
import {V4AgenticVaultFactory} from "../src/V4AgenticVaultFactory.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys factory + vault on a mainnet fork (Anvil), funds with 0.5 ETH + 1000 USDC
/// @dev Usage:
///   1. Start Anvil fork:
///        anvil --fork-url $MAINNET_RPC_URL
///   2. Run script (use Anvil default key #0, or set your own PRIVATE_KEY):
///        PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
///        forge script script/DeployVault.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployVault is Script {
    // ── Mainnet addresses ────────────────────────────────────────────
    address constant POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address constant UNIVERSAL_ROUTER = 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af;
    address constant PERMIT2          = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address constant USDC             = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    // ── Pool: ETH/USDC 0.3% ─────────────────────────────────────────
    uint24  constant FEE          = 3000;
    int24   constant TICK_SPACING = 60;
    address constant HOOKS        = address(0);

    // ── Vault parameters ─────────────────────────────────────────────
    int24   constant ALLOWED_TICK_LOWER = -887220; // near min tick, aligned to 60
    int24   constant ALLOWED_TICK_UPPER =  887220; // near max tick, aligned to 60
    bool    constant SWAP_ALLOWED       = true;
    uint256 constant MAX_POSITIONS_K    = 0;       // unlimited

    // ── Funding amounts ──────────────────────────────────────────────
    uint256 constant FUND_ETH  = 0.5 ether;
    uint256 constant FUND_USDC = 1000 * 1e6; // 1000 USDC (6 decimals)

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address agent = vm.envOr("AGENT_ADDRESS", deployer);

        console2.log("Deployer:", deployer);
        console2.log("Agent:   ", agent);

        vm.startBroadcast(deployerKey);

        // 1. Deploy factory
        V4AgenticVaultFactory factory = new V4AgenticVaultFactory(
            POSITION_MANAGER,
            UNIVERSAL_ROUTER,
            PERMIT2
        );
        console2.log("Factory deployed:", address(factory));

        // 2. Create vault
        PoolKey memory poolKey = PoolKey({
            currency0:   Currency.wrap(address(0)), // Native ETH
            currency1:   Currency.wrap(USDC),
            fee:         FEE,
            tickSpacing: TICK_SPACING,
            hooks:       IHooks(HOOKS)
        });

        address vaultAddr = factory.createVault(
            poolKey,
            agent,
            ALLOWED_TICK_LOWER,
            ALLOWED_TICK_UPPER,
            SWAP_ALLOWED,
            MAX_POSITIONS_K
        );
        console2.log("Vault deployed:", vaultAddr);

        // 3. Fund vault with ETH
        (bool ok,) = vaultAddr.call{value: FUND_ETH}("");
        require(ok, "ETH transfer failed");

        // Note: USDC funding is done via shell script (anvil_setStorageAt)

        // 4. Approve USDC via Permit2 for POSM and UniversalRouter
        V4AgenticVault v = V4AgenticVault(payable(vaultAddr));

        v.approveTokenWithPermit2(
            Currency.wrap(USDC),
            POSITION_MANAGER,
            type(uint160).max,
            uint48(block.timestamp + 365 days)
        );
        v.approveTokenWithPermit2(
            Currency.wrap(USDC),
            UNIVERSAL_ROUTER,
            type(uint160).max,
            uint48(block.timestamp + 365 days)
        );

        vm.stopBroadcast();

        // Summary
        console2.log("\n=== Deployment Summary ===");
        console2.log("Factory:      ", address(factory));
        console2.log("Vault:        ", vaultAddr);
        console2.log("Owner:        ", deployer);
        console2.log("Agent:        ", agent);
        console2.log("ETH balance:  ", vaultAddr.balance);
        console2.log("USDC balance: ", IERC20(USDC).balanceOf(vaultAddr));
    }
}
