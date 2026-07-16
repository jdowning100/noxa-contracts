# Noxa CTO elections and fee claims

New launches use snapshot-backed, raw-balance voting and a dedicated EIP-1167 fee vault. The V3 LP NFT remains in `LauncherLocker`; anyone can collect fees, but the creator/community share is sent to the token's vault. The current CTO leader claims that vault through `NoxaCTOFund`.

## Deployment order

1. Deploy `FeeRouter` and `LauncherLocker`.
2. Call `FeeRouter.setLocker(locker)` exactly once.
3. Deploy `LaunchFactory(locker, launchFee, launchEnabled)`. Its constructor deploys the shared, initializer-locked `CTOFeeVault` implementation.
4. Call `LauncherLocker.setFactory(factory)` exactly once.
5. Deploy the `NoxaCTOFund` implementation.
6. Deploy a standard transparent proxy with atomic initialization data:

   ```solidity
   abi.encodeCall(NoxaCTOFund.initialize, (address(factory), functionalOwner))
   ```

7. Call `LaunchFactory.setCTOFund(proxy)` exactly once. The factory rejects the uninitialized implementation because its `factory()` value is not this factory.
8. Put the proxy admin behind a timelocked multisig, configure launch/DEX settings, and enable launches.

Every fee vault stores the proxy address as its permanent `ctoFund`. Upgrading the proxy therefore preserves vault authorization. The proxy admin controls a protocol-wide fee-authorization boundary and should be operationally separate from the functional owner that changes election parameters.

## Election behavior

- `devWallet` is the initial leader and may claim immediately.
- Anyone can open the first round. A round has no automatic expiry: it remains votable until a candidate reaches
  quorum or someone explicitly supersedes it with a fresh round. Quorum closes voting immediately. Once the pinned
  `roundReopenAt` (`roundStart + reopenCooldown`, one day by default) has passed, anyone may open a fresh round
  whether or not the prior round reached quorum.
- Voting starts after the opening timestamp plus `voteHoldSeconds` is finalized.
- Voting power is the lower of the exact opening snapshot balance and the holder's end-of-opening-timestamp balance.
- Circulation is finalized after the opening timestamp. It uses the larger of exact-open circulation and
  end-of-opening-timestamp circulation, so temporary V3 liquidity changes cannot lower takeover quorum. The
  quorum basis points, vote start, earliest reopen time, and replacement claim delay are all pinned for that round.
  This is deliberately safety-biased: a temporary pool withdrawal can raise quorum and delay takeover for one
  round, but cannot make fee control cheaper to capture. Preventing both directions would require a delayed or
  multi-sample oracle/commit design rather than an atomic permissionless snapshot.
- `LaunchToken` records exact and end-of-opening-timestamp round boundaries for its aggregate
  one-way nonvoting supply, covering the factory, canonical pool, dead address, fee router, CTO vault, and every
  treasury address used by that token without an unbounded loop. Ordinary transfers outside an opening boundary
  do not append historical checkpoints; state growth is tied to election rounds, not trading timestamps. The token
  enforces at most one snapshot per timestamp so each round has one unambiguous final boundary.
- Each account may vote once per round; votes cannot be changed or withdrawn. Snapshot capping prevents transferred
  tokens from creating additional voting power in another account during that round.
- The first candidate to reach quorum closes the round. If that candidate differs from the incumbent, leadership
  changes immediately and the replacement waits the pinned `leaderClaimDelay` (four hours by default) before
  claiming. An incumbent confirmed by quorum closes the round without resetting an existing claim timestamp.
- Reopen spacing and voting warmup remain coupled so every round has a voting window before it can be superseded.
  Claim delay is independently configurable; the four-hour default is intentionally shorter than the default
  one-day interval between round openings.
- Votes are irrevocable within their round, but a split or stale electorate cannot deadlock governance permanently:
  after `roundReopenAt`, anyone may replace the unresolved round with a fresh snapshot and empty tallies.
- `claimTo` lets a nonpayable leader direct payment to a payable recipient.
- Unclaimed fees follow the current leader, including fees accrued before a leadership change.
- A vault accepts launched-token deposits only from the canonical `FeeRouter`. Direct holder deposits revert,
  preventing excluded-balance parking and anti-snipe limit bypass; pair-token and native fee receipts are unchanged.

The legacy `LaunchedToken.feeWallet` field remains the initial leader for ABI/indexer compatibility. `LaunchFactory.ctoVaultOf(token)` and `LauncherLocker.feeWalletOf(token)` identify the actual fee vault.

If `FeeRouter.treasury` changes, call the permissionless `LaunchFactory.syncFeeTreasuryExemption(token)` to make
the current treasury restriction-exempt immediately. Voting exclusion is deliberately synchronized by
`ctoSnapshot` at the next round boundary, never midway through an active round. Prior treasuries remain excluded,
and callers cannot select an arbitrary address.

## Build and test

From this directory:

```sh
forge test -vv
forge build --contracts LaunchFactory_flat.sol --sizes
```

The Foundry profile pins Solidity 0.8.26, Cancun, optimizer runs 200, and `via_ir`. The incompatible, pre-existing `src/LaunchLocker.sol` draft is skipped; `src/LauncherLocker.sol` is the locker used by the factory.
