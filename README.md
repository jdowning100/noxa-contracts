# Noxa Launchpad Contracts

Token launchpad for Robinhood Chain (4663), forked from noxa.fi and extended with CTO governance and a buy-and-burn protocol treasury. Launched
tokens trade on the chain's Uniswap V3 fork; LP fees are locked forever and split
between the token's community vault and the protocol.

## Components

| Contract | Role | Mutability |
|---|---|---|
| `LaunchFactory` (`LaunchFactory_flat.sol`) | Deploys tokens + pools, registers launch/DEX configs, wires vaults | Immutable |
| `LaunchToken` | Launched ERC20: anti-snipe limits, election snapshots | Immutable per launch |
| `LauncherLocker` | Holds LP NFTs permanently; permissionless `claimFees` | Immutable |
| `FeeRouter` | Splits collected fees between vault and treasury; unwraps WETH | Immutable |
| `NoxaBuyBurner` | Protocol treasury: accumulates fees, sells inventory to WETH, buys and burns NOXA | Immutable |
| `NoxaCTOFund` | Snapshot-based CTO elections; per-token quorum overrides | Upgradeable (transparent proxy) |
| `CTOFeeVault` | Per-token fee vault (EIP-1167 clone), claimable by the current leader | Immutable |

Fee flow: pool → `LauncherLocker.claimFees` (anyone) → `FeeRouter.distribute` →
N% to the token's `CTOFeeVault` (current CTO leader claims via `NoxaCTOFund`),
N% to `NoxaBuyBurner` (ETH pair fees arrive unwrapped; launched-token shares
arrive raw and are swept to WETH through each token's official pool).

Election mechanics, snapshot semantics, and deployment order are documented in
[`CTO_DEPLOYMENT.md`](./CTO_DEPLOYMENT.md).

## Build and test

Foundry, Solidity 0.8.26, Cancun, via-IR (see `foundry.toml`). OpenZeppelin v5 is
vendored under `lib/`.

```sh
forge build
forge test --no-match-contract ForkTest   # unit/integration suites (self-contained)
forge test                                # + fork suite: needs a Robinhood RPC at 127.0.0.1:8547
```

The `NoxaBuyBurnerForkTest` suite forks the live chain and drives the full fee
path end-to-end (launch → trade → claim → sweep → burn), so it requires a synced
Robinhood node at `http://127.0.0.1:8547`.

`forge build --contracts LaunchFactory_flat.sol --sizes` reports `DeployNoxa`
above the EIP-170 limit — that is the deploy *script* (it embeds all initcode)
and never lands on-chain; every deployable contract is under the limit.

## Deployment

```sh
forge script script/DeployNoxa.s.sol --rpc-url <rpc> --private-key $RH_KEY --broadcast --slow
```

The script deploys FeeRouter → Locker → Factory → CTOFund (proxy) → BuyBurner,
wires everything one-time, points the treasury at the burner, and enables
launches. Post-deploy (see the script header for details):

1. Seed a canonical NOXA/WETH V3 pool and call the pool's permissionless
   `increaseObservationCardinalityNext(>= 8)`; let ~30 min of trades populate
   the oracle (untrusted burns/sweeps require a healthy TWAP — no spot fallback).
2. `burner.setBurnTarget(noxaToken, pool)` — until then fees accumulate and
   `burn()` reverts.
3. Hand ownership off to a multisig


