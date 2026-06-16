# USDR Redemption v2

Atomic, stateless, fixed-rate, first-come-first-served **USDR → USDC** swap on **Polygon**
(chainId 137). v2 is a deliberate clean break from v1: no epochs, no pro-rata rationing, no
per-user accounting, no KYC.

## How it works

A holder approves the contract for USDR and calls `redeem`. In one transaction the contract:

1. computes the USDC payout at the **immutable** fixed rate (rounds down; a zero payout reverts);
2. reverts unless its current USDC balance covers the payout **in full** (all-or-nothing — the
   live balance is the only cap, so redemption is a race for on-hand USDC);
3. **burns** the USDR directly from the holder via the token's allowance-based
   `burn(account, amount)` — the contract never custodies USDR and **no burner role is needed**;
4. transfers the USDC to the holder (or a receiver they specify).

Tangible tops the contract up over time via `fund` as real-estate proceeds convert to USDC.
Once **180 days** pass with no funding, the owner may `sweep` whatever USDC remains; every
funding resets that clock.

### Contract surface (`src/USDRRedemption.sol`)

| Function | Access | Notes |
|---|---|---|
| `redeem(usdrAmount)` / `redeem(usdrAmount, receiver)` | anyone | Burns USDR from caller, pays USDC at the fixed rate. `receiver = address(0)` ⇒ caller. |
| `fund(usdcAmount)` | owner | Pulls USDC from the owner (requires prior approval), stamps `lastFundingTime`, emits `Funded`. Owner-only **by design** so third-party dust deposits can never reset the sweep clock. Raw USDC transfers still work but don't touch the clock. |
| `sweep(to)` | owner | Transfers the whole USDC balance out; reverts with `SweepLocked` until `lastFundingTime + 180 days` (initialized to deployment time). |
| `rescueERC20(token, to)` | owner | Recovers stray tokens; **rejects USDC** so the sweep timelock cannot be bypassed. Stray USDR transfers are recoverable (normal operation never holds USDR). |
| `previewRedeem(usdrAmount)` | view | USDC out for USDR in, floor-rounded. |
| `availableUSDC()` / `maxRedeemableUSDR()` | view | Live capacity, so UIs can size a redeem that won't revert. |
| `sweepUnlockTime()` | view | Earliest timestamp the owner can sweep. |

Ownership is `Ownable2Step` (owner should be a Gnosis Safe). The contract is immutable —
no proxy, no upgrade path, and the rate/token addresses can never change.

### Rate representation

`rate` = USDC raw units (6 decimals) **per 1 whole USDR** (USDR has 9 decimals):

```
usdcOut = usdrAmount * rate / 1e9        // floor
$0.54   → RATE = 540000
$0.5417 → RATE = 541700                  // precision: $0.000001
```

### Deploy-time parameters (pending values)

| Parameter | Status |
|---|---|
| Exact rate (~$0.54) | **TBC** — pass as `RATE` |
| Native USDC (`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`) vs USDC.e (`0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174`) | **TBC** — pass as `USDC` |
| 6 months | fixed at `180 days` |
| Upgradeability | none — immutable deploy |

## Deployment

```bash
RATE=541700 \                                       # USDC units per 1 USDR — confirm final figure first
USDC=0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359 \   # or USDC.e — confirm choice first
OWNER=<gnosis-safe-address> \
forge script script/DeployUSDRRedemption.s.sol \
  --rpc-url "$POLYGON_RPC_URL" --broadcast --verify -i 1 --sender <deployer>
```

**No USDR token setup transaction is required.** USDR's `burn(account, amount)` is
permissionless and allowance-based (not role-gated), so the contract burns straight from
redeemers — there is nothing to grant and no Safe transaction against the USDR token.

Operational dependency: USDR's `burn` is `whenNotPaused`. If Tangible pauses the USDR token,
redemptions revert until it is unpaused.

### Operating from the Safe

- **Fund** (each time proceeds arrive) — batch via the Safe Transaction Builder:
  1. `USDC.approve(redemption, amount)`
  2. `redemption.fund(amount)`

  Always use `fund()`, never a raw USDC transfer, so the funding clock is stamped.
- **Sweep** (wind-down) — after 180 days with no funding (`sweepUnlockTime()`),
  execute `redemption.sweep(treasury)`.
- **Rescue** — `redemption.rescueERC20(token, to)` for anything accidentally sent in
  (except USDC, which only leaves via redemptions or the timelocked sweep).

## Development

```bash
forge build
forge test --no-match-path 'test/fork/*'   # unit tests (mocks)
forge test --match-path 'test/fork/*'      # Polygon fork integration tests
forge coverage --no-match-coverage '(test|script)'
```

The fork tests redeem **real USDR** end to end against the live token by impersonating the
largest EOA holder, parameterized over both native USDC and USDC.e. They use
`POLYGON_RPC_URL` if set and fall back to a public archive endpoint
(`https://polygon.drpc.org`); the fork is pinned to block `88250000`.

Coverage of `src/USDRRedemption.sol` is 100% (lines, statements, branches, functions).
If `forge coverage` ever hits stack-too-deep, re-run with `--ir-minimum`.
