# Remora

Remora is a **per-user Vault** for agent-managed liquidity provisioning on **Uniswap V4** (no-hook pools only). The Vault holds custody, mints/owns LP position NFTs, and enforces strict on-chain limits while an off-chain Agent performs periodic rebalancing.

> Experimental, not audited. Use at your own risk.

## Key Rules

- **Single pool**: Vault is bound to one `poolKey`.
- **Owner-only withdrawals**: only the user can withdraw.
- **Agent-only ops**: mint/increase/decrease/burn/collect; optional **single-pool exact-in swap** if enabled.
- **Tick bounds**: user defined tick range to provide liquidity.
- **Position cap `K`**: `K=0` unlimited; otherwise Agent can’t exceed `K` positions.
- **Emergency exit**: Owner can pause the Agent and burn all positions back into the Vault.

## Usage (High Level)

1. Deploy a Vault with `poolKey`, initial tick bounds, `agent`, `swapAllowed`, and `K`.
2. Fund the Vault by transferring ERC20/ETH directly.
3. Owner sets **Permit2 allowances** for:
   - PositionManager (required)
   - Universal Router (only if swaps enabled)

## Docs

- `PRD.md` — full specification and references.
