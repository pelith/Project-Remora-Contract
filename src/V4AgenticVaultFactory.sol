// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {V4AgenticVault} from "./V4AgenticVault.sol";

/// @notice Factory contract for deploying V4AgenticVault instances
/// @dev Uses CREATE2 for deterministic vault addresses
contract V4AgenticVaultFactory {
    // ============================================================
    // Immutable Protocol Addresses
    // ============================================================

    address public immutable posm;
    address public immutable universalRouter;
    address public immutable permit2;

    // ============================================================
    // Vault Tracking
    // ============================================================

    address[] public vaults;
    mapping(address => address[]) public vaultsCreatedBy;
    mapping(address => bool) public isVault;
    mapping(address => uint256) public creatorNonce;

    // ============================================================
    // Events
    // ============================================================

    event VaultCreated(
        address indexed creator,
        address indexed vault,
        PoolKey poolKey,
        address agent,
        uint256 nonce
    );

    // ============================================================
    // Constructor
    // ============================================================

    constructor(address _posm, address _universalRouter, address _permit2) {
        require(_posm != address(0), "bad posm");
        require(_universalRouter != address(0), "bad universalRouter");
        require(_permit2 != address(0), "bad permit2");

        posm = _posm;
        universalRouter = _universalRouter;
        permit2 = _permit2;
    }

    // ============================================================
    // Vault Creation
    // ============================================================

    /// @notice Deploy a new V4AgenticVault for the caller
    /// @param poolKey The target Uniswap v4 pool
    /// @param agent Address authorized to manage positions
    /// @param allowedTickLower Lower bound of allowed tick range
    /// @param allowedTickUpper Upper bound of allowed tick range
    /// @param swapAllowed Whether agent can perform swaps
    /// @param maxPositionsK Max positions (0 = unlimited)
    /// @return vault The deployed vault address
    function createVault(
        PoolKey calldata poolKey,
        address agent,
        int24 allowedTickLower,
        int24 allowedTickUpper,
        bool swapAllowed,
        uint256 maxPositionsK
    ) external returns (address vault) {
        uint256 nonce = creatorNonce[msg.sender]++;

        bytes32 salt = _computeSalt(msg.sender, poolKey, nonce);

        vault = address(
            new V4AgenticVault{salt: salt}(
                msg.sender,
                agent,
                posm,
                universalRouter,
                permit2,
                poolKey,
                allowedTickLower,
                allowedTickUpper,
                swapAllowed,
                maxPositionsK
            )
        );

        vaults.push(vault);
        vaultsCreatedBy[msg.sender].push(vault);
        isVault[vault] = true;

        emit VaultCreated(msg.sender, vault, poolKey, agent, nonce);
    }

    // ============================================================
    // View Functions
    // ============================================================

    /// @notice Compute the vault address without deploying
    /// @dev All parameters must match what will be passed to createVault
    /// @param creator The address that would create the vault
    /// @param poolKey The target pool key
    /// @param nonce The creator's nonce at time of creation
    /// @param agent Address that will be authorized to manage positions
    /// @param allowedTickLower Lower bound of allowed tick range
    /// @param allowedTickUpper Upper bound of allowed tick range
    /// @param swapAllowed Whether agent can perform swaps
    /// @param maxPositionsK Max positions (0 = unlimited)
    /// @return The deterministic vault address
    function computeVaultAddress(
        address creator,
        PoolKey calldata poolKey,
        uint256 nonce,
        address agent,
        int24 allowedTickLower,
        int24 allowedTickUpper,
        bool swapAllowed,
        uint256 maxPositionsK
    ) external view returns (address) {
        bytes32 salt = _computeSalt(creator, poolKey, nonce);

        bytes memory bytecode = abi.encodePacked(
            type(V4AgenticVault).creationCode,
            abi.encode(
                creator,
                agent,
                posm,
                universalRouter,
                permit2,
                poolKey,
                allowedTickLower,
                allowedTickUpper,
                swapAllowed,
                maxPositionsK
            )
        );

        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode))
        );

        return address(uint160(uint256(hash)));
    }

    /// @notice Get all vaults created by an address
    /// @param creator The creator address
    /// @return Array of vault addresses
    function getVaultsCreatedBy(address creator) external view returns (address[] memory) {
        return vaultsCreatedBy[creator];
    }

    /// @notice Get all vaults created by this factory
    /// @return Array of all vault addresses
    function getAllVaults() external view returns (address[] memory) {
        return vaults;
    }

    /// @notice Get total number of vaults created
    /// @return Total vault count
    function totalVaults() external view returns (uint256) {
        return vaults.length;
    }

    /// @notice Get the next nonce for a creator
    /// @param creator The creator address
    /// @return The next nonce that will be used
    function getNextNonce(address creator) external view returns (uint256) {
        return creatorNonce[creator];
    }

    // ============================================================
    // Internal Functions
    // ============================================================

    function _computeSalt(
        address creator,
        PoolKey calldata poolKey,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(creator, poolKey, nonce));
    }
}
