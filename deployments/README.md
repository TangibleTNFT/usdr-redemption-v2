# Deployment registry

`script/DeployUSDRRedemption.s.sol` writes `<chainid>.json` here (e.g. `137.json` for
Polygon) on each deploy, recording the deployed address and its immutable config:

```json
{
  "chainId": 137,
  "owner": "0x…",        // Gnosis Safe multisig
  "usdr": "0x…",
  "usdc": "0x…",         // native USDC
  "rate": 532000,        // USDC units per 1 whole USDR ($0.532, the final deploy value)
  "redemption": "0x…"    // the deployed USDRRedemption
}
```

These files record the deployed address for operational reference, so it need not be scraped
from the broadcast logs. The contract is public and **verified** on Polygonscan (deploy with
`--verify`).
