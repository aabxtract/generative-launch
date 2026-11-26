# Generative (GENV) launch contracts

The exact source, compiler input, tests and review evidence for the Generative launch on Ethereum mainnet through
[Programmable](https://programmable.market) Custom Launch (API V3, profile 3.6.0). The launch request points at this
repository and the commit that contains these bytes.

## What is here

| Path | What |
| --- | --- |
| `src/HolderVault.sol` | 0.3% holder fee (ETH) + the 2% GENV escrow for the 281 Generative NFTs, keyed by token ID. No owner. |
| `src/GenerativeToken.sol` | GENV, fixed 1,000,000,000 supply: 98% to the locked pool, 2% to HolderVault. No owner, no mint. |
| `src/GenerativeInitializer.sol` | Seeds and permanently locks the one-sided liquidity and makes the opening buy, in the launch transaction. |
| `src/GenerativeHook.sol` | Uniswap v4 hook: 4.6% fee on gross ETH (0.3% Programmable, 4% creator, 0.3% holders), launch protection. |
| `src/programmable/` | Programmable's reference fee vault and launch-protection contracts, used unmodified. |
| `src/ChildLauncher.sol`, `src/AbilityRegistry.sol` | Compiled in the same bundle; **not** deployed by this launch. |
| `lib/` | Only the dependency files the build uses (OpenZeppelin, Uniswap v4, forge-std), byte-identical, with their own licenses. |
| `build/standard-json-input.json` | The exact solc Standard JSON input in the launch request (sha256 `9e05b45b38f2ed29d55efe6db35da8094c20cec2379a7b908b89b0021eeebe5d`). |
| `build/artifacts/` | The four deployed contracts' artifacts as submitted. |
| `test/GenerativeLaunch.t.sol` | Mainnet-fork tests (23). |
| `script/LocalTrades.s.sol` | Test trades used by the pack rehearsal on a local fork. |
| `evidence/` | The attestation evidence files whose hashes are in the launch request (below). |
| `REVIEW-NOTES.md` | Answers to every review finding, and the change log for each reviewer request. |

## Evidence files (hashes as in the launch request)

| File | sha256 |
| --- | --- |
| `evidence/foundry-mainnet-fork-tests.json` | `b16558b93e71367ca28a654100c3eab4ed9de0c9b2363104a0a6eab6996d2ec1` |
| `evidence/generative-preflight.json` | `c0faca074c9907813c04e81f26699690a06019c068559e7fd99fe530ef5dfc39` |

**Buy, sell and platform-fee payout results for the current request: [`evidence/TRADE-RESULTS.md`](evidence/TRADE-RESULTS.md)**
(raw: [`evidence/rehearsal.json`](evidence/rehearsal.json), which names the request's sha256). Both are linked from the
launch request's project metadata. They are the full rehearsal of the request on a mainnet fork through Programmable's
real Graph Factory: addresses, graph gas, opening buy, fee payouts on buys and sells, and the "every NFT retired"
scenario. They are produced by packing, after the source commit, so they are not hashed in the request.
`evidence/rehearsal-f25b9821.json` is the same report for the earlier request f25b9821.

## Reproduce

```sh
node verify.mjs      # sources == repo files; solc 0.8.26 output == submitted artifacts (creation + runtime)
forge test           # 23 mainnet-fork tests (FORK_RPC_URL overrides the default public RPC)
```

`forge build` gives the same code; only the metadata hash can differ, because forge records the remappings it finds.
`verify.mjs` compiles the exact submitted input and must match byte for byte.

## Fixed addresses

PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` · Chainlink ETH/USD `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` ·
Programmable Graph Factory `0xB012e4A8F2c5FC4E8E4faCA9D5Ad6FfF13FBA887` · Programmable team wallet
`0x9F5856A3578Faba96A6E8Dfd9C10563A1E598f62` · Generative NFT `0x437876AF69553CD9c31046f96DC1DfE4C76278C6`

## License

Our contracts are MIT (see each file's SPDX header). Files under `lib/` and `src/programmable/` keep their own licenses.
