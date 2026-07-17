# Noxa CTO elections and fee claims

New launches use snapshot-backed, raw-balance voting and a dedicated EIP-1167 fee vault. The V3 LP NFT remains in `LauncherLocker`; anyone can collect fees, but the creator/community share is sent to the token's vault. The current CTO leader claims that vault through `NoxaCTOFund`.

## Deployment order

1. Deploy `FeeRouter` and `LauncherLocker`. The router remains unusable until its recipients are configured.
2. Call `FeeRouter.setLocker(locker)` exactly once.
3. Deploy `LaunchFactory(locker, launchFee, launchEnabled)`. Its constructor deploys the shared, initializer-locked `CTOFeeVault` implementation.
4. Call `LauncherLocker.setFactory(factory)` exactly once.
5. Deploy the `NoxaCTOFund` implementation.
6. Deploy a standard transparent proxy with atomic initialization data:

   ```solidity
   abi.encodeCall(NoxaCTOFund.initialize, (address(factory), functionalOwner))
   ```

7. Call `LaunchFactory.setCTOFund(proxy)` exactly once. The factory rejects the uninitialized implementation because its `factory()` value is not this factory.
8. Deploy the burner and, if required, a `FeeSplitter` bound to the FeeRouter and owned by the intended multisig.
   Atomically configure `FeeRouter` recipients/shares, put the owners and proxy admin behind multisigs, configure
   launch/DEX settings, and enable launches.

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
  fixed protocol/burner recipient used by that token without an unbounded loop. Ordinary transfers outside an opening boundary
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
  preventing excluded-balance parking and anti-snipe limit bypass. Pair-token fees remain ERC20s, including WETH;
  the router never unwraps them.
- An optional `FeeSplitter` may be used as the protocol router recipient. The burner slot remains a direct
  recipient because it also receives the separate launch fee; `FeeRouter` rejects a bound splitter there.
  The splitter receives the same restriction exemption and voting exclusion as an ordinary fixed protocol
  recipient, but the factory does not inspect its binding or grant it fee-vault privileges: `feeDepositSource`
  remains unset and `feeSenderExempt` remains false. Direct launched-token transfers are therefore possible but
  unallocated, and claims that would exceed the temporary max-wallet limit must wait until restrictions expire.
  Successful claims become ordinary circulating, vote-eligible balances.
- The splitter owner (intended to be a multisig) may call `setConfig` to change recipients and shares. That closes
  the current epoch and opens a new one for subsequent FeeRouter deposits; prior epoch recipients, shares,
  deposits, and entitlements remain fixed, and each recipient can claim independently through
  `release(epoch, token)`. A configuration applies when the router deposits collected fees, not when those fees
  originally accrued in the V3 position. Collect pending fees immediately before an update if governance wants
  that update to be a clean economic boundary.
- A closed epoch's integer-division remainder is claimable by its last listed recipient. Direct ERC20 transfers to
  the splitter are permitted but deliberately unallocated and create no recipient entitlement.

The legacy `LaunchedToken.feeWallet` field remains the initial leader for ABI/indexer compatibility. `LaunchFactory.ctoVaultOf(token)` and `LauncherLocker.feeWalletOf(token)` identify the actual fee vault.

If either fixed FeeRouter recipient changes, `LauncherLocker.claimFees` automatically invokes the factory's
permissionless `syncFeeRecipientExemptions(token)` before distributing. It can also be called directly. Voting
exclusion is deliberately synchronized by `ctoSnapshot` at the next round boundary, never midway through an active
round. Prior protocol and burner recipients remain excluded, and callers cannot select an arbitrary address.

## Build and test

From this directory:

```sh
forge test -vv
forge build --contracts LaunchFactory_flat.sol --sizes
```

The Foundry profile pins Solidity 0.8.26, Cancun, optimizer runs 200, and `via_ir`. The incompatible, pre-existing `src/LaunchLocker.sol` draft is skipped; `src/LauncherLocker.sol` is the locker used by the factory.
