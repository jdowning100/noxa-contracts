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
| `FeeRouter` | Splits both collected ERC20 assets among protocol, burner, and CTO vault | Non-upgradeable; owner-configurable |
| `FeeSplitter` | Optionally subdivides one FeeRouter leg through owner-configurable, per-epoch ERC20 claims | Non-upgradeable; future epochs owner-configurable |
| `NoxaBuyBurner` | Accumulates WETH + launched-token fees, sells inventory, buys and burns NOXA | Immutable |
| `NoxaCTOFund` | Snapshot-based CTO elections; per-token quorum overrides | Upgradeable (transparent proxy) |
| `CTOFeeVault` | Per-token fee vault (EIP-1167 clone), claimable by the current leader | Immutable |

Fee flow: pool → `LauncherLocker.claimFees` (anyone) → `FeeRouter.distribute` →
33.33% to the protocol recipient, 33.33% to `NoxaBuyBurner`, and the 33.34%
remainder to the token's `CTOFeeVault` (current CTO leader claims through
`NoxaCTOFund`). WETH remains WETH throughout this path; launched-token shares
sent to the burner are swept to WETH through each token's official pool. The
multisig owner can atomically update both fixed recipients and all three shares.

For more than three ultimate destinations, keep the three top-level legs in
`FeeRouter` and point its `protocolRecipient` leg at a `FeeSplitter`. The
`burnerRecipient` must remain a direct recipient because the separate launch
fee is sent there as WETH; the router rejects a bound splitter in that slot.
Its owner (intended to be a multisig) calls `setConfig` to replace the recipients
and basis-point shares. Each successful update closes the current epoch and opens
a new one for future FeeRouter deposits. A closed epoch's recipients, shares, and
recorded deposits cannot be changed, so accrued claims are not reassigned by a
later configuration. Recipients manually call `release(epoch, token)` for each
asset and epoch in which they participated. This avoids an unbounded recipient
loop or downstream claim failure in the core LP-fee collection path.

The epoch boundary is **receipt time**, when `FeeRouter` calls
`FeeSplitter.deposit`, not the earlier time at which fees accrue inside the V3
position. Therefore fees that accrued before a configuration update but are
collected afterward use the new epoch. If governance needs a clean operational
boundary, collect all pending LP fees immediately before changing the splitter
configuration.

Active-epoch claims use monotonic pro-rata accounting. Integer division can
temporarily leave at most `recipientCount - 1` smallest token units unclaimable.
When a configuration update closes that epoch, its final remainder is assigned
to the epoch's last listed recipient so every router-recorded unit can be
claimed. Raw tokens transferred directly to the splitter are unallocated and do
not increase anyone's claim.

Each `FeeSplitter` is immutably bound to its intended FeeRouter even though its
recipient configuration is mutable. When used as `protocolRecipient`, it gets
the same restriction exemption and voting exclusion as any other fixed protocol
recipient; the factory does not inspect its router binding or configure it as a
trusted fee vault. Consequently, its `feeDepositSource` remains unset and it
does not receive the `feeSenderExempt` max-wallet bypass. Direct launched-token
transfers to the splitter are permitted but remain unallocated, and a recipient
claim that would exceed the temporary max-wallet limit reverts until the launch
restrictions expire. Successful claims enter ordinary circulating,
vote-eligible balances; WETH claims remain standard ERC20 transfers.

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

## Deployed addresses

### Robinhood mainnet (chain 4663)

| Contract | Address |
| --- | --- |
| LaunchFactory | [`0xA24D48D50Fd7985c6dE816EaF77C1A17D3593BBE`](https://robinhoodchain.blockscout.com/address/0xA24D48D50Fd7985c6dE816EaF77C1A17D3593BBE) |
| FeeRouter | [`0x28A5328B61E00dD75F1d0C8A1831A65890E42d36`](https://robinhoodchain.blockscout.com/address/0x28A5328B61E00dD75F1d0C8A1831A65890E42d36) |
| FeeSplitter | [`0xA2dA74831c34D396Be9a42FbeCc54C561184BCb1`](https://robinhoodchain.blockscout.com/address/0xA2dA74831c34D396Be9a42FbeCc54C561184BCb1) |
| LauncherLocker | [`0x90331A631123bD2493Ba962c4304dcb49f3A5d4A`](https://robinhoodchain.blockscout.com/address/0x90331A631123bD2493Ba962c4304dcb49f3A5d4A) |
| NoxaBuyBurner | [`0xeE0a9B71E3DeF2A5c4d141AD1B97CE0Dd1E87748`](https://robinhoodchain.blockscout.com/address/0xeE0a9B71E3DeF2A5c4d141AD1B97CE0Dd1E87748) |
| NoxaCTOFund (proxy) | [`0xF12e70ffd97CD60cDFae04E37064aF4bD9C526D1`](https://robinhoodchain.blockscout.com/address/0xF12e70ffd97CD60cDFae04E37064aF4bD9C526D1) |
| NoxaCTOFund (implementation) | [`0x3921cF21812611Db64572f11436F4Ac72541fd63`](https://robinhoodchain.blockscout.com/address/0x3921cF21812611Db64572f11436F4Ac72541fd63) |
| CTO ProxyAdmin | [`0x6b9acEa23a2011E20712189b210f4519816574cc`](https://robinhoodchain.blockscout.com/address/0x6b9acEa23a2011E20712189b210f4519816574cc) |

The CTO fee vault for a launched token is a per-token minimal-proxy clone; read
its address from `LaunchFactory.ctoVaultOf(token)`. The burn target starts unset.

## Deployment

```sh
forge script script/DeployNoxa.s.sol --rpc-url <rpc> --private-key $RH_KEY --broadcast --slow
```

The script deploys FeeRouter → Locker → Factory → CTOFund (proxy) → BuyBurner,
wires the three-way fee configuration, and enables launches. The launch fee
remains separate from the LP-fee split, but is wrapped into WETH and sent
directly to the burner. Post-deploy (see the script header for details):

1. Seed a canonical NOXA/WETH V3 pool with liquidity.
2. `burner.setBurnTarget(noxaToken, pool)` — until then fees accumulate and
   `burn()` reverts. Untrusted (non-owner) burns/sweeps additionally require a
   matured `recordAnchor(pool)` snapshot: the burner prices them off a forward
   TWAP — the pool's `tickCumulative` delta between recording and execution —
   so atomic spot manipulation carries zero time weight (record, wait
   `anchorDelay`, execute — no spot path for untrusted callers).
3. If using a `FeeSplitter`, deploy it with the FeeRouter address, multisig owner,
   and initial recipients/shares, then point one FeeRouter leg at it.
4. Hand every functional owner, including the splitter owner, off to a multisig.
