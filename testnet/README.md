# Testnet replica

A self-service copy of the mainnet setup for UI development and testing.

| Role | Mainnet | Testnet |
|---|---|---|
| Hub (USDR, wUSDR lock, redemption) | Polygon, LayerZero ID 109 | Arbitrum Sepolia (421614), LayerZero ID 10231 |
| Side chain (bridged wUSDR) | Base, Optimism, BSC, Arbitrum, Ethereum | Sepolia (11155111), LayerZero ID 10161 |

Addresses: [`deployments/421614.json`](../deployments/421614.json) (hub) and
[`deployments/11155111.json`](../deployments/11155111.json) (side chain).

## What is real and what is not

- `WrappedUSDR` (hub) and `ChildWUSDR` (side chain) are the **live mainnet bytecode**,
  copied from the tangible `usdr` repo's hardhat-deploy files (`artifacts/`, with the
  solc standard input used to verify them). They are deployed without proxies.
- The redemption contract is `TestnetUSDRRedemption.sol`, **generated** from
  `src/USDRRedemption.sol` by `RedemptionCopyGen.sol`. The only change is that
  `SWEEP_DELAY` is a constructor argument. `test/testnet/TestnetCopy.t.sol` fails if the
  copy drifts from the audited source. To regenerate it, run
  `forge script script/testnet/GenerateRedemptionCopy.s.sol`.
- USDR and USDC are `TestTokens.sol`, which anyone can mint. `TestUSDR` has the real
  `burn(account, amount)` and returns mainnet's `liquidityIndex()`, so 1 wUSDR unwraps
  to ~1.0791 USDR just like on Polygon.
- `TestnetRedemptionFactory` creates redemption contracts and owns them. Each tester
  manages their own instances through it (fund, set the rate, sweep), so nobody needs
  test USDC or the Safe.
- The faucets (`Faucets.sol`) give gas plus tokens once per 12 hours. The side-chain
  faucet is the `ChildWUSDR` migrator. Every wUSDR it mints is backed by the 1B USDR
  worth of wUSDR pre-locked in the hub's `WrappedUSDR`, so bridging home always works.

## LayerZero on testnet

Only **Sepolia → Arbitrum Sepolia** is delivered. That is the "bring wUSDR home"
direction, and it was verified end to end on 2026-10-21 (arrival in ~90 s).
LayerZero's testnet executor never delivered the reverse direction, so bridging out to
the side chain is not supported. Side-chain wUSDR comes from the faucet instead.

## Redeploying

```sh
# hub (Arbitrum Sepolia)
forge script script/testnet/DeployHub.s.sol --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
  --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow
# side chain (Sepolia): --skip-simulation is required, because Sepolia charges far more gas
# for new code than forge's local EVM (ChildWUSDR: 26.65M vs ~3.7M simulated)
forge script script/testnet/DeploySide.s.sol --rpc-url https://ethereum-sepolia-rpc.publicnode.com \
  --private-key $DEPLOYER_PRIVATE_KEY --broadcast --slow --skip-simulation
# trust each other (run against both RPCs, Sepolia again with --skip-simulation)
forge script script/testnet/LinkBridge.s.sol --rpc-url <rpc> --private-key $DEPLOYER_PRIVATE_KEY --broadcast
```

`FAUCET_GAS` is read from the project `.env` (default: 1 ETH hub, 2 ETH side chain).
