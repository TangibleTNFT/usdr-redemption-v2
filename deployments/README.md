# Deployment registry

`script/DeployUSDRRedemption.s.sol` writes `<chainid>.json` here (e.g. `137.json` for
Polygon) on each deploy, recording the deployed address and its deploy-time config:

```json
{
  "chainId": 137,
  "owner": "0x…",                       // Gnosis Safe multisig
  "usdr": "0x…",
  "usdc": "0x…",                        // native USDC
  "rate": 532000,                       // initial USDC units per 1 whole USDR ($0.532); owner-raisable
  "totalSupply": 35909552000000000,     // 35,909,552 USDR in 9-decimal raw units; immutable
  "redemption": "0x…"                   // the deployed USDRRedemption
}
```

`rate` is the value at deployment; the live value is `rate()` on the contract, since the
owner may raise it.

The production deployment script hardcodes the Polygon USDR and native-USDC addresses, the initial
rate, and `totalSupply`; only the already-deployed owner Safe is provided at runtime.

These files record the deployed address for operational reference, so it need not be scraped
from the broadcast logs. The contract is public and **verified** on Polygonscan (deploy with
`--verify`).
