# Notes for Programmable's review

Answers to the findings from Programmable's remote preflight (`node launch/pack.mjs --remote`, 2026-11-20):
**deployable: true, no hard blocks**, disposition `needs_evidence`. These are the items a reviewer checks by hand.
Paste or attach this when the review asks for evidence. Line numbers refer to the packed source.

## Graph

| Target | Contract | Role |
| --- | --- | --- |
| `holder-vault` | HolderVault | Holds the 2% holder escrow; receives the 0.3% holder fee as PoolManager ETH claims |
| `initializer` | GenerativeInitializer | Adapted from ProtectedNativeInitializerV1: initializes the pool, seeds locked one-sided liquidity, starts trading, opening buy |
| `token` | GenerativeToken | Adapted from ProtectedLaunchTokenV1: fixed 1B supply, 2% to HolderVault, rest to the initializer |
| `hook` | GenerativeHook | AutomaticProtectedNative30HookV2 plus a 0.3% holder share |

Fees on every buy and sell, in ETH on the gross native amount: 0.3% Programmable (ceil, auto-paid to
`0x9F5856A3578Faba96A6E8Dfd9C10563A1E598f62` via the reference AutomaticNativeFeeVaultV2), 4% creator, 0.3% holders.
Total 4.6% (`inclusive-selected-total`, 46000). Opening surcharge as in the reference, paid to the same Programmable wallet.

## Findings

**V4_CALLBACK_AUTHENTICATION_MISSING (holder-vault `unlockCallback`, initializer `unlockCallback`)**
Both revert unless `msg.sender == poolManager`, checked in the first statement before any effect, together with a
one-shot payload commitment. `poolManager` is an immutable set to the mainnet PoolManager (the vault and initializer
both require it to have code; the hook requires the canonical PoolManager on chain 1). The initializer's callback is
identical to ProtectedNativeInitializerV1. The vault's only unlock path is `_payNative` (fee payouts to NFT owners).

**V4_CALLBACK_AUTHENTICATION_REVIEW_REQUIRED (hook beforeInitialize / beforeSwap / afterSwap)**
External entry points are OpenZeppelin `BaseHook`'s, all `onlyPoolManager`; the hook is bound to the canonical
PoolManager (`CANONICAL_POOL_MANAGER`, same as the reference hook). beforeInitialize only accepts the graph initializer
and the exact pool key.

**SOURCE_LIQUIDITY_LOCK_OR_CUSTODY_SURFACE**
- initializer `modifyLiquidity` / `take`: one-time seed inside `initialize`, callable only by the Graph Factory once.
  The position is owned by the initializer, which has no owner, no withdraw and no remove-liquidity path: permanently locked.
- hook `mint` (lines ~400-411): mints PoolManager ERC-6909 claims for fees to the fee vault (Programmable + creator)
  and to HolderVault (holders), then the vaults pay out. Same mechanism as the reference hook.
- holder-vault `burn` / `take` / ERC-20 transfer: fee payouts and escrow claims, only to the current owner of each NFT
  (`claimFees`, `claimFeesFor`, `claimEscrow`, `claimEscrowFor`), and `retire` (only the NFT's current holder, to a recipient they name, after vesting). Every
  payout is bounded by what that NFT has accrued; `feeLiability` must stay backed.

**SOURCE_MUTABLE_TAX_OR_FEE_SURFACE**
- holder-vault lines 51-52 (`feeLiability`, `totalFeesIn`): accounting counters, not rates. They only grow from
  `notifyFee` (hook only) and shrink on payouts.
- hook: all fee rates are constants or constructor immutables (30 bps Programmable, 30 bps holders, 400 bps creator);
  `lpFee` is 0 and there is no module (address 0), so there is no fee override. No setter changes any rate.

**SOURCE_MUTABLE_ADMIN_SURFACE (holder-vault, OpenZeppelin Ownable)**
HolderVault has no owner and no admin functions (revision 3): no `Ownable`, no `setLauncher`. Nobody can move fees or
escrow, change rates, pause anything, or retire an NFT other than its current holder.

**SOURCE_EXTERNAL_DEPENDENCY_SURFACE (initializer, Chainlink ETH/USD)**
Used once, at launch, to enforce the USD 15,000 minimum opening FDV, as in the reference initializer: codehash
pinned in the constructor, answer must be positive and updated within 1 hour.

**INITIAL_BUY_NOT_ESTABLISHED (hint)**
The buy is `initializer.initialize(hook, token, startTick, buyer = launch wallet, minTokenOut)` with the Router
transaction value (same ABI as ProtectedNativeInitializerV1). Rehearsal through the real Graph Factory on a mainnet fork:
0.00063 ETH bought 57,534.5 GENV for the launch wallet.

## Evidence

- `forge test --match-path test/GenerativeLaunch.t.sol` on a mainnet fork: 20 tests pass (bundled as `evidence/foundry-mainnet-fork-tests.json`).
- `node launch/pack.mjs`: deploys the packed graph through the real Graph Factory (as the router) at the exact
  predicted addresses, runs both initializers, then 4 buys of 0.5 ETH and 4 sells. Programmable received
  0.0095689 ETH, holders 0.0095689 ETH, creator 0.1275853 ETH: 0.3% / 0.3% / 4%. Runtime hashes in the request match the deployed code.

## Reviewer change request, revision 2 (2026-11-21): holder share after the last NFT retires

Request: buys and sells must still work after the last eligible NFT retires; say where the holder share goes once
the count is zero; keep the 0.3% Programmable payout intact; send buy and sell evidence for that state.

Change, in `src/HolderVault.sol` only:
- New constructor argument and immutable `residualRecipient`: the creator fee wallet (the same fixed address the hook's
  creator share goes to). Checked non-zero at deploy; it cannot be changed afterwards.
- `notifyFee`: when `liveSupply == 0` it no longer divides. The amount is added to `residualFees` (still counted in
  `feeLiability` and still fully backed by the ERC-6909 claims the hook minted). Nothing is paid out inside the swap,
  so the swap path has no new external call and cannot revert because of it.
- `retire`: when it retires the last NFT, the rounding dust left from the per-NFT split (under 1 wei per NFT) is moved
  into `residualFees`, so nothing is stranded.
- `sendResidual()`: anyone can call; pays `residualFees` to `residualRecipient` through `PoolManager.unlock`, the same
  payout path as holder claims. No owner power was added.
- Programmable's 0.3% is untouched: the hook pays it into Programmable's fee vault (pushed to the team wallet in the
  swap); it never passes through HolderVault. The hook did not change.

Evidence:
- Fork test `test_allNftsRetired_buyAndSellStillWork` (in `evidence/foundry-mainnet-fork-tests.json`): retires all 281,
  then a buy and a sell; checks Programmable gets exactly ceil(0.3%) on both, creator 4%, holder 0.3% held as residual,
  `sendResidual` pays the creator wallet and the vault owes nothing afterwards.
- Pack rehearsal on a mainnet fork through the real Graph Factory with the packed bytes: mints all 281, finishes the
  vest, retires all 281, then 4 buys + 4 sells; same checks (see `rehearsal.json`, section `allRetired`).

## Reviewer change request, second (2026-11-21): the holder controls retirement and payout

Request: the current NFT holder must authorize retirement, and accrued ETH and vested GENV must go to that holder or a
recipient they explicitly authorize; the vault left both decisions to an owner-appointed launcher.

Change:
- `HolderVault.retire(tokenId, to)` can now only be called by `nft.ownerOf(tokenId)` (else `NotTokenOwner`), with an
  explicit non-zero `to` chosen by that holder (else `ZeroRecipient`), after the 7-day vest. It pays the NFT's ETH fees
  and vested GENV to `to` and removes it from the split. After a sale only the new holder can retire it.
- The launcher role is gone from the vault, and with it the vault's owner: `Ownable` and `setLauncher` are removed, and
  the constructor is `(nft, poolManager, graphFactory, residualRecipient)`. HolderVault has no privileged caller left
  apart from the graph factory's one-time `bind` and the hook's `notifyFee`.
- `ChildLauncher` (not part of this launch graph; deployed later) no longer calls the vault. Its `launchChild` only
  burns an NFT that its holder has already retired (`NotRetired` otherwise) and that the caller holds.

Evidence:
- Fork tests (`evidence/foundry-mainnet-fork-tests.json`): `test_retire_onlyHolderDecides` (a non-holder, a launcher,
  the team and the deployer all revert; zero recipient reverts; after a transfer the old holder reverts and the new holder
  retires and is paid; no second retire), `test_retire_notBeforeVestDone`, `test_vault_hasNoOwner`,
  `test_childLaunch_retiresAndBurns` (launch reverts until the holder retires to a recipient of their choice; the payout
  goes to that recipient), and `test_allNftsRetired_buyAndSellStillWork` (every holder retires their own NFTs).
- Pack rehearsal with the packed bytes through the real Graph Factory (`rehearsal.json`): a non-holder `retire` reverts;
  the holder retires NFT #1 to a different address they name and that address receives the ETH fees and 71,174 GENV;
  the holder retires the other 280; then 4 buys + 4 sells with zero NFTs left, with the same fee checks as before.
