# USDR Redemption v2

Pro-rata **USDR → USDC** redemption on **Polygon** (chainId 137). Every holder is entitled to
exactly their share of the USDC Tangible has funded so far — no first-come-first-served race, no
epochs, no KYC. The rate can be raised by the owner but never lowered, and nobody receives more or
less for redeeming earlier or later.

> The audit report in `audit/` covers the previous, stateless FCFS design. The pro-rata model
> described here supersedes it and has not been audited yet.

## How it works

The contract is deployed with two numbers:

- `totalUSDRSupply` (**S**) — the USDR population that may ever be redeemed. Tangible's agreed,
  immutable accessible-supply figure (**35,909,552 USDR**), deliberately *not* the token's
  on-chain `totalSupply()`: balances irrecoverably stuck in contracts are excluded.
- `rate` (**R**) — the target rate, initially **$0.532** per USDR. The owner may raise it later.

Together they define `expectedFunding = ceil(S × R / 1e9)` — the USDC needed to redeem everything
(**19,103,881.664 USDC** at the deploy values). Tangible funds towards that figure over time via
`fund`, which rejects anything beyond it; `remainingFunding()` gives the exact top-up.

A holder approves the contract for USDR and calls `redeem(x)`. In one transaction the contract:

1. **burns** `x` USDR directly from the holder via the token's allowance-based `burn(account, amount)`
   (never custodied, no burner role needed) and registers `x` **shares** to the holder;
2. pays the holder everything those shares are owed at the current funding level.

A position with `shares` is entitled, at any moment, to

```
entitled = shares × totalFunded / S        (rounded down)
```

and each `redeem` or `claim` pays `entitled − paid`. **The rate is not in that formula** — a share's
payout is its slice of what has actually been funded; the rate only fixes where "fully funded" sits.
When more USDC is funded later, the holder calls `claim()` (no USDR needed) for the difference.

**Worked example** (S = 35,909,552 USDR, R = $0.532, expected = 19,103,881.664 USDC). Tangible funds
1 % (191,038.81664 USDC). A holder presenting 100,000 USDR receives 100,000 × 191,038.81664 / 35,909,552
= **532 USDC** — 1 % of the 53,200 USDC the position is worth at full funding — and no more, however fast
they are. The rate is then raised to $0.60 (expected becomes 21,545,731.20 USDC); nothing changes until
the difference is funded, after which `claim()` brings the holder's lifetime total to exactly
**60,000 USDC**.

### Timing does not matter

All divisions floor, and `paid` is always reset to the current floor, so:

- **Path independence** — a position receives exactly `⌊shares × F_final / S⌋` in total whether it
  claims after every funding or once at the end (the payouts telescope).
- **Tranche independence** — presenting `x1` then `x2` ends at the same `paid` as presenting `x1 + x2`
  once.
- **Order independence** — entitlement depends only on `(shares, totalFunded)`, never on who went first.
- **Wallet splitting** can never gain; it loses at most 1 raw unit ($0.000001) per extra wallet.
- **Solvency** — `Σ shares ≤ S` and flooring give `Σ entitled ≤ totalFunded`, so the contract can
  always pay every claim without an explicit balance check. Floor dust stays in the contract until
  the final sweep.
- **Full funding pays the rate** — `expectedFunding` rounds *up*, so at full funding every holder gets
  at least `⌊shares × R / 1e9⌋`; Tangible over-funds by strictly less than one raw unit in total.

Security-critical supply assumption: the permissionless contract cannot itself distinguish
accessible from irrecoverably stuck USDR. The `35,909,552 USDR` denominator therefore depends on
Tangible's off-chain reconciliation remaining correct and on no excluded balance becoming
recoverable. USDR is no longer expected to rebase; resuming rebase, mint or bridge-release activity
must be reviewed against this denominator before it happens.

### Wind-down

The 180-day countdown starts when the contract becomes **fully funded** (`totalFunded == expectedFunding`),
not on every funding call. From then on the owner may `sweep`, which takes the **entire** USDC balance and
**permanently closes** the contract. That is the single deadline for everyone: holders who never
presented their USDR and holders who presented it but never claimed the remainder both forfeit what is
left. Raising the rate after full funding un-arms the countdown until the top-up lands.

Consequence to be aware of: **if full funding is never reached, no sweep is ever possible** and
unpresented/unclaimed USDC stays in the contract. There is deliberately no rate-lowering escape hatch.

### Contract surface (`src/USDRRedemption.sol`)

| Function | Access | Notes |
|---|---|---|
| `redeem(usdrAmount)` / `redeem(usdrAmount, receiver)` | anyone | Burns USDR from the caller, registers shares to the caller, pays what they are owed so far (may be 0 before funding). `receiver = address(0)` ⇒ caller. Reverts `ShareCapExceeded` past `totalUSDRSupply`. |
| `claim()` / `claim(receiver)` | anyone | Pays the caller's position whatever has become owed since its last settlement. Reverts `NothingToClaim` at zero. |
| `fund(usdcAmount)` | owner | Pulls exactly `usdcAmount` USDC from the owner (requires prior approval and rejects a mismatched balance delta). Reverts `FundingExceedsExpected(requested, remaining)` past `expectedFunding`. The funding that reaches it stamps `fullyFundedAt` and emits `FullyFunded`. |
| `fundFromBalance(usdcAmount)` | owner | Recognizes an existing, unaccounted USDC balance as funding. Intended to recover an accidental raw transfer; cannot count the reserve already owed to holders or exceed `expectedFunding`. |
| `setRate(newRate)` | owner | Strictly increasing. Raises `expectedFunding`; clears `fullyFundedAt`. Nothing already paid is clawed back. |
| `sweep(to)` | owner | From `fullyFundedAt + 180 days`: transfers the whole balance out and sets `closed`. The first sweep closes even at a zero balance; a later empty sweep reverts. Reverts `SweepLocked(unlockTime)` before (`unlockTime = type(uint256).max` while under-funded). Stays callable after closing for USDC that lands later. |
| `rescueERC20(token, to)` | owner | Recovers stray tokens; **rejects USDC** so the timelock cannot be bypassed. |
| `expectedFunding()` / `remainingFunding()` / `isFullyFunded()` | view | Funding target, exact top-up, and whether it has been reached. |
| `previewRedeem(usdrAmount)` / `previewRedeem(account, usdrAmount)` | view | Payout for fresh USDR / for an account with an existing position. |
| `claimableUSDC(account)` / `outstandingUSDC()` | view | Owed to one account / upper bound on everything owed. |
| `effectiveRate()` | view | `rate × totalFunded / expectedFunding` — display only. |
| `availableUSDC()` / `maxRedeemableUSDR()` / `sweepUnlockTime()` | view | Balance, remaining share capacity (`S − totalShares`), sweep timestamp. |
| `positions(account)` | view | `(shares, paid)`, one packed slot per redeemer. |

Once closed, `redeem`, `claim`, `fund`, `fundFromBalance` and `setRate` revert `ContractClosed`.
Claim, outstanding and redemption-preview views return zero because unpaid entitlements have been
forfeited.

Ownership is `Ownable2Step` (owner should be a Gnosis Safe); `renounceOwnership` is disabled. The
contract is immutable — no proxy, no upgrade path; the token addresses and `totalUSDRSupply` can
never change, and the rate can only go up.

### Units

`rate` = USDC raw units (6 decimals) **per 1 whole USDR** (USDR has 9 decimals):

```
expectedFunding = ceil(totalUSDRSupply * rate / 1e9)
entitled(shares) = shares * totalFunded / totalUSDRSupply   // floor
$0.532  → RATE = 532000                                     // deploy value
$0.5417 → RATE = 541700                                     // precision: $0.000001
```

### Deploy-time parameters

| Parameter | Value |
|---|---|
| Rate — **$0.532** (`RATE = 532000`) | initial; owner-raisable |
| Total supply — **35,909,552 USDR** (`TOTAL_SUPPLY = 35909552000000000`) | immutable |
| USDC token — **native USDC** (`0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359`), not USDC.e | immutable |
| Sweep delay | fixed at `180 days` after full funding |
| Upgradeability | none — immutable deploy |

## Deployment

```bash
OWNER=<already-deployed-gnosis-safe-address> \
forge script script/DeployUSDRRedemption.s.sol \
  --rpc-url "$POLYGON_RPC_URL" --broadcast --verify -i 1 --sender <deployer>
```

The production script is Polygon-only and hardcodes the USDR address, native-USDC address, initial
`$0.532` rate and `35,909,552 USDR` accessible-supply denominator. It accepts only the owner address,
requires that address to contain deployed code, and logs the on-chain `totalSupply()` next to the
accessible figure for the broadcast record. The broadcast signer must independently verify that
`OWNER` is Tangible's approved Safe; bytecode presence alone cannot establish that identity.

**No USDR token setup transaction is required.** USDR's `burn(account, amount)` is
permissionless and allowance-based (not role-gated), so the contract burns straight from
redeemers — there is nothing to grant and no Safe transaction against the USDR token.

Operational dependency: USDR's `burn` is `whenNotPaused`. If Tangible pauses the USDR token,
redemptions revert until it is unpaused (claims of already-registered positions are unaffected).

### Operating from the Safe

- **Fund** (each time proceeds arrive) — batch via the Safe Transaction Builder:
  1. `USDC.approve(redemption, amount)`
  2. `redemption.fund(amount)`

  Read `remainingFunding()` first: `fund` rejects anything beyond it. Always use `fund()`. If USDC
  is accidentally sent by raw transfer, it is not funding automatically; the Safe can deliberately
  recognize the unaccounted balance with `fundFromBalance(amount)` or leave it for the final sweep.
- **Raise the rate** — `redemption.setRate(newRate)`, then fund the new `remainingFunding()`.
- **Sweep** (wind-down) — 180 days after full funding (`sweepUnlockTime()`), execute
  `redemption.sweep(treasury)`. This closes the contract for good.
- **Rescue** — `redemption.rescueERC20(token, to)` for anything accidentally sent in
  (except USDC, which only leaves via redemptions, claims or the sweep).

## Development

```bash
forge build
forge test --no-match-path 'test/fork/*'   # unit + invariant tests (mocks)
forge test --match-path 'test/fork/*'      # Polygon fork integration tests
forge coverage --no-match-coverage '(test|script)'
```

The unit suite includes fuzz tests for every rounding property listed above (path, tranche and
order independence, wallet splitting, full-funding payout, solvency); run them with more iterations
via `FOUNDRY_FUZZ_RUNS=10000`. The invariant suite drives random funding, accidental-transfer
recognition, redemption, claim, rate-change, donation and sweep sequences and checks solvency, the
pro-rata ledger, the caps, rate monotonicity, value conservation, the full-funding clock and
terminal closure.

The fork tests redeem **real USDR** end to end against the live token by impersonating the
largest EOA holder, parameterized over both native USDC and USDC.e, with the production
`35,909,552 USDR` accessible-supply figure as the configured supply. They use `POLYGON_RPC_URL` if
set and fall back to a public archive
endpoint (`https://polygon.drpc.org`); the fork is pinned to block `88250000`.

If `forge coverage` ever hits stack-too-deep, re-run with `--ir-minimum`.
