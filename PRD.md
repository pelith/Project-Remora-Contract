# Agentic Uniswap v4 LP Vault PRD

> Scope: one Vault contract per user (fund isolation). An Agent periodically adjusts Uniswap v4 LP positions based on an off-chain strategy.  
> Assumption: **interact only with “no-hook” Uniswap v4 pools**; do not require atomic rebalancing (the Agent may complete a rebalance via multiple transactions).

---

## 1. Goals and Non-Goals

### 1.1 Goals
- After a user funds their personal Vault, the Agent can, according to an off-chain strategy, operate in the specified v4 pool to:
  - create/adjust multiple LP positions (to produce a desired liquidity distribution)
  - keep part of the funds idle in the Vault (not necessarily fully deployed into LP)
  - (optional) perform swaps for rebalancing (controlled by a user permission toggle)
- The user can set risk boundaries (the pool, the tick range in which liquidity may be provided, whether swaps are allowed, and a maximum number of positions K).
- The user can pause the Agent at any time and force-remove all liquidity to enable withdrawal.

### 1.2 Non-Goals
- **No atomic rebalancing requirement**: the Agent may use multiple transactions (reducing per-tx complexity).
- **No hooks support**: hookData is always empty bytes; only interact with no-hook pools.
- **No multi-hop swaps / cross-pool routing**: swaps are single-pool exact-in only.
- **No explicit deposit API**: users fund the Vault via direct ERC20 `transfer` / `transferFrom` (handled externally) or ETH `transfer`.

---

## 2. User Configuration (Vault Setup / Operation)

### 2.1 Set at deployment (immutable)
| Parameter | Description |
|---|---|
| `poolKey` | The target v4 pool the Vault may provide liquidity to (currency0/currency1/fee/tickSpacing, etc.) |
| `agent` | The Agent address authorized to operate this Vault |
| `K` | Max number of positions the Agent may manage/create; `K = 0` means unlimited |

### 2.2 Adjustable after deployment (updated by Owner; applies to actions **after** the update)
| Parameter | Description |
|---|---|
| `allowedTickLower` / `allowedTickUpper` | The tick range in which the Agent may add/increase liquidity (applies to **mint / increase**) |
| `swapAllowed` | Whether the Agent is allowed to swap for rebalancing |
| `agentPaused` | Whether the Agent’s access is paused |

> Semantics of updating the tick boundaries:  
> - After updating the tick boundary, the Agent **must not** mintPosition / increaseLiquidity outside the new boundary.  
> - Existing positions whose tick ranges exceed the new boundary are **not** immediately affected (they can remain as-is, be decreased, burned, or have fees collected). However, they must not be increased (if an increase would keep it in an out-of-bound range, it must be rejected).

---

## 3. Roles and Permissions

### 3.1 Owner (User)
- The only party who can withdraw assets (`withdraw`).
- Can update `agent`, pause/resume the Agent, toggle `swapAllowed`, update tick boundaries, and set/update K (if K is designed to be adjustable).
- Can trigger emergency exit (`pauseAndExitAll`): pauses the Agent and burns all positions so funds return to the Vault.

### 3.2 Agent
- Can only call restricted Vault methods:
  - LP: mint / increase / decrease / burn / collect fees
  - swaps (only if `swapAllowed=true`)
- **Cannot** withdraw assets, cannot transfer assets out of the Vault, cannot move position NFTs, and cannot modify owner settings.

### 3.3 External contracts
- **PositionManager (v4-periphery)**: manages positions via the command-based `modifyLiquidities()`.
- **Universal Router**: performs swaps via `execute()` + v4 swap actions.
- **Permit2**: manages token spending permissions via allowance + expiration (spenders are PositionManager / UniversalRouter).

---

## 4. Primary User Flows (User Stories)

### 4.1 Create a Vault
- The user (or a Factory) deploys a Vault and sets `poolKey`, `agent`, `K`, and initial tick boundaries and `swapAllowed`.

### 4.2 Fund the Vault (no deposit API)
- Users transfer ERC20 tokens directly into the Vault (`transfer`), or use an external flow that calls `transferFrom`; the Vault provides no deposit function.
- If the pool involves native ETH, the Vault must keep a `receive()` function to accept ETH transfers.
- The user configures Permit2 allowances:
  - at minimum for the PositionManager
  - additionally for the UniversalRouter if swaps are enabled

### 4.3 Agent periodic rebalancing (multi-tx)
Based on the strategy output, the Agent may execute a transaction sequence such as:
1. `collectFeesToVault`
2. `decreaseLiquidityToVault` / `burnPositionToVault` (remove/adjust existing positions)
3. `swapExactInputSingle` (optional, if allowed)
4. `mintPosition` / `increaseLiquidity` (create/adjust multiple positions)
5. leave idle funds in the Vault (by doing nothing)

### 4.4 User exits
- The user calls `pauseAndExitAll` (pause + burn all positions), returning assets to the Vault.
- The user calls `withdraw` to move funds to an external wallet.

---

## 5. Contract Requirements (On-chain Requirements)

### 5.1 Vault (one per user)
#### State
- immutable:
  - `poolKey`
  - `posm` (PositionManager), `universalRouter`, `permit2`
- mutable (updatable by Owner):
  - `agent`
  - `agentPaused`
  - `swapAllowed`
  - `allowedTickLower/allowedTickUpper`
  - `K`
- position tracking:
  - `positionIds[]`
  - `isManagedPosition[tokenId]`
  - `tokenId -> (tickLower, tickUpper)`

#### Functions
- Owner methods:
  - config: `setAgent`, `setAgentPaused`, `setSwapAllowed`, `setAllowedTickRange`, `setMaxPositionsK`
  - funds: `withdraw`
  - approvals: `approveTokenWithPermit2`
  - emergency: `pauseAndExitAll`
  - compatibility: `receive()` (needed only if currency0 or currency1 is native ETH)
- Agent methods (restricted):
  - LP: `mintPosition`, `increaseLiquidity`, `decreaseLiquidityToVault`, `collectFeesToVault`, `burnPositionToVault`
  - swaps (restricted): `swapExactInputSingle` (single-pool exact-in)

#### Constraints and validations
- Tick constraints (for mint / increase):
  - `tickLower >= allowedTickLower`
  - `tickUpper <= allowedTickUpper`
  - `tickLower < tickUpper`
  - ticks must be multiples of `tickSpacing`
- Existing positions after boundary updates:
  - allow `decrease / burn / collect`
  - reject any `mint / increase` that would create or add liquidity outside the new boundary
- Position count limit K:
  - `K = 0`: unlimited
  - `K > 0`: before `mintPosition`, require `positionIds.length < K`
- Swap constraints:
  - only the fixed `poolKey`
  - requires `minAmountOut` + `deadline`
  - `swapAllowed` must be true

### 5.2 Factory (optional)
- Recommended:
  - CREATE2 deterministic addresses (better indexing and UX)
  - `vaultCreated` event (off-chain tracking)

---

## 6. Security and Risk Controls

### 6.1 Do not approve position NFTs to the Universal Router
- The Vault must not approve v4 positions to the Universal Router (to prevent third parties from using the router to remove liquidity).

### 6.2 Principle of least privilege
- The Agent must never be able to `withdraw`, must not be able to transfer NFTs, and must not be able to modify owner settings.
- The Vault should expose only the minimal swap interface to prevent arbitrary calldata injection.

### 6.3 Slippage / deadline
- Swaps must use `minAmountOut` + `deadline` to reduce MEV and adverse price movement risk.

### 6.4 Permit2 expiry
- Use Permit2 `expiration` to limit long-lived approval risk (allowances expire automatically).

### 6.5 Emergency exit
- `pauseAndExitAll` provides a one-click exit: remove all positions, return funds to the Vault, then the Owner withdraws.

---

## 7. References

### 7.1 Uniswap v4 (official docs)
- Position Manager guide (command-based interface)  
  https://docs.uniswap.org/contracts/v4/guides/position-manager
- Manage liquidity quickstarts (mint / increase / burn / collect)  
  https://docs.uniswap.org/contracts/v4/quickstart/manage-liquidity/mint-position  
  https://docs.uniswap.org/contracts/v4/quickstart/manage-liquidity/increase-liquidity  
  https://docs.uniswap.org/contracts/v4/quickstart/manage-liquidity/burn-liquidity  
  https://docs.uniswap.org/contracts/v4/quickstart/manage-liquidity/collect
- Swap quickstart (Universal Router + V4_SWAP)  
  https://docs.uniswap.org/contracts/v4/quickstart/swap
- Swap routing guide (why use the Universal Router)  
  https://docs.uniswap.org/contracts/v4/guides/swap-routing
- SDK v4 single-hop swapping guide  
  https://docs.uniswap.org/sdk/v4/guides/swaps/single-hop-swapping

### 7.2 Permit2 (official docs / resources)
- AllowanceTransfer reference  
  https://docs.uniswap.org/contracts/permit2/reference/allowance-transfer
- Permit2 integration guide (Uniswap blog)  
  https://blog.uniswap.org/permit2-integration-guide
- Permit2 repo  
  https://github.com/Uniswap/permit2
- Permit2 & Universal Router introduction (Uniswap blog)  
  https://blog.uniswap.org/permit2-and-universal-router

### 7.3 Security audits / advisories
- OpenZeppelin: Uniswap v4 periphery + Universal Router audit (position approval risk)  
  https://www.openzeppelin.com/news/uniswap-v4-periphery-and-universal-router-audit
