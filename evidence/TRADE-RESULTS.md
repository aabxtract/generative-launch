# Buy, sell and platform-fee payout results

For the launch request with **requestSha256 `sha256:37c20656745a22e24180a9da40937bb2d3d98e913acd6846b1c60ef5ff091ead`**, source commit
[`ab4fd7b`](https://github.com/aabxtract/generative-launch/tree/ab4fd7bf32feb1e5dfddddc5809bfe7295c4fc36).
Raw report: [`rehearsal.json`](rehearsal.json). All 32 checks passed, 0 failed.

How: a local fork of Ethereum mainnet at block 26501330. The exact request bytes go through Programmable's real Graph Factory
`deployGraph` (impersonating the router), then trades run through the Uniswap v4 pool. Nothing was sent to mainnet.

## Deployed graph (same addresses as the request)

| Target | Address |
| --- | --- |
| holder-vault | `0x204129d18f505C6F98C95D4EC7799702cfFcB590` |
| initializer | `0xDEdC9D4487b39be071Aa2c16f1bE28d2bf233B03` |
| token (GENV) | `0x80aEfb43a28024bCeBDE585243C1372E3A1146C4` |
| hook | `0x0bd886B68B37A5b59b1Cfb8AE3C8C32d12a7A0Cc` |

The graph deploys and initializes in one transaction (gas 9626752). All four runtime code hashes in the request match the deployed code.

## Opening buy (in the launch transaction)

| | |
| --- | --- |
| ETH in | 0.00063 |
| GENV out to the launch wallet | 57534.503330759220816203 |
| Programmable 0.3% paid in ETH to the team wallet `0x9F5856A3578Faba96A6E8Dfd9C10563A1E598f62` | 0.00000189 ETH |

## Buys and sells after the protection window (4 buys of 0.5 ETH + 4 sells)

| Fee (on gross ETH) | Paid (ETH) | Where |
| --- | --- | --- |
| Programmable 0.3% | 0.009568901104905136 | paid automatically in ETH to the team wallet inside each swap |
| NFT holders 0.3% | 0.009568901104905132 | HolderVault (equals Programmable's share) |
| Creator 4% | 0.127585348065401784 | creator fee wallet |

## Every NFT retired (no holder left), then 4 buys + 4 sells

| Fee (on gross ETH) | Paid (ETH) | Where |
| --- | --- | --- |
| Programmable 0.3% | 0.01139839203545757 | still paid automatically in ETH to the team wallet |
| NFT holders 0.3% | 0.011398392035457566 | held as residual; `sendResidual` paid 0.011398392035457692 (incl. 126 wei rounding dust) only to the creator fee wallet |
| Creator 4% | 0.15197856047276757 | creator fee wallet |

Buys and sells keep working with zero NFTs left, and the vault owes nothing afterwards.

## All checks

- PASS Graph Factory deploys and initializes the whole graph in one transaction: gas 9626752
- PASS holder-vault deployed at its predicted address: 0x204129d18f505C6F98C95D4EC7799702cfFcB590
- PASS initializer deployed at its predicted address: 0xDEdC9D4487b39be071Aa2c16f1bE28d2bf233B03
- PASS token deployed at its predicted address: 0x80aEfb43a28024bCeBDE585243C1372E3A1146C4
- PASS hook deployed at its predicted address: 0x0bd886B68B37A5b59b1Cfb8AE3C8C32d12a7A0Cc
- PASS Opening buy delivered GENV to the launch wallet: 57534.503330759220816203 GENV for 0.00063 ETH
- PASS Programmable team wallet paid in ETH on the opening buy: 0.00000189 ETH
- PASS HolderVault bound to the hook
- PASS HolderVault holds the 2% holder escrow
- PASS Buys and sells through the pool after the protection window: 4 buys of 0.5 ETH + 4 sells
- PASS Programmable 0.3% paid automatically in ETH to the team wallet on trades: 0.009568901104905136 ETH
- PASS Holder share equals Programmable's share (both 0.3%): 0.009568901104905132 ETH
- PASS Creator share is 4% (400/30 of Programmable's): 0.127585348065401784 ETH
- PASS All 281 NFTs minted on the fork
- PASS 7-day escrow vest done
- PASS A non-holder cannot retire an NFT (reverts)
- PASS Holder retires NFT #1 and the ETH fees + vested GENV go to the recipient the holder named: 0.000034059754821726 ETH + 71174 GENV
- PASS All 281 NFTs retired by their holder: liveSupply is 0: 0 reverts
- PASS Rounding dust from the per-NFT split moved to the residual: 126 wei
- PASS Residual recipient is the fixed creator fee wallet: 0x078A2ee79c8b197C4eB488700ec476f12AdDbF26
- PASS Buys and sells work with zero NFTs left: 4 buys of 0.5 ETH + 4 sells
- PASS Programmable 0.3% still paid in ETH in the swap (equal to the holder 0.3%): 0.01139839203545757 ETH
- PASS Holder 0.3% held as residual (no NFT left to share it): 0.011398392035457566 ETH
- PASS Creator 4% unchanged: 0.15197856047276757 ETH
- PASS Anyone can trigger sendResidual; ETH goes only to the creator fee wallet: 0.011398392035457692 ETH
- PASS Vault owes nothing afterwards
- PASS holder-vault runtime hash in the request matches the deployed code
- PASS initializer runtime hash in the request matches the deployed code
- PASS token runtime hash in the request matches the deployed code
- PASS hook runtime hash in the request matches the deployed code
- PASS programmable-launch validate (local) passes
- PASS Programmable remote preflight accepts the request
