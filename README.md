# DAO Spaces

A governance-agnostic DAO framework — an original, from-scratch on-chain governance protocol where a DAO's treasury and its governance rules are kept as two separate, swappable pieces, rather than locked together.

Every module — proposal lifecycle, voting, quorum/approval math, timelocks, and every one of the ten governance models below — is implemented from scratch, purpose-built for this framework. The companion bot — Telegram, Discord and Slack — lives in [`protean-bot`](https://github.com/replico-labs/protean-bot).

## Why this exists

Most EVM chains handle DAO governance one of two ways today:

- **Snapshot** — off-chain voting. Votes are signed messages, not transactions; nothing is enforced by the chain, and someone still has to execute the result by hand.
- **A custom-built governance system** — hard to get right, and once deployed, usually locked in. Changing the rules means migrating the entire treasury, and a DAO is stuck with whichever decision-making model it launched with.

DAO Spaces executes every governance action fully on-chain, and a DAO isn't locked into one way of deciding. It can start with a small trusted board, grow into token-weighted voting, switch to quadratic voting to reduce whale influence, adopt continuous conviction voting, let a randomly drawn council govern, or let markets decide — all without the treasury moving.

## Architecture

```
┌──────────────┐        controls        ┌──────────────┐
│  Governance   │ ─────────────────────▶ │   Treasury    │
│ (swappable —  │                        │ (stays put —  │
│  any of 10    │ ◀───────────────────── │  holds funds) │
│  models)      │      trusts            └──────────────┘
└──────────────┘
       │
       │ controls (mint rights)
       ▼
┌───────────────────┐        wraps        ┌──────────────────────┐
│  GovernanceToken    │ ◀─────────────────  │ StakedGovernanceToken │
│  (raw, liquid,      │       stake()        │ (voting power lives   │
│   transferable)     │ ─────────────────▶  │  here, lockable when  │
└───────────────────┘                       │  a model requires it) │
                                             └──────────────────────┘
```

`Treasury`'s entire trust model is one question: *"is the caller my registered `governance` address?"* That single design choice is what makes every model a genuine drop-in replacement for any other.

### Clone-based deployment (EIP-1167)

Every factory deploys **minimal proxy clones**, not full contracts. Each contract's implementation is deployed once; each new DAO gets ~45-byte clones pointing at those implementations, initialized via `initialize()` instead of a constructor.

This isn't an optimization — it's what makes deployment possible at all. Factories that `new` their child contracts embed each child's full creation bytecode, which put every factory at 26–99 KB against the EVM's 24,576-byte limit. Deploying implementations from inside a factory's own constructor does **not** help (the bytecode is embedded either way). Implementations are deployed as separate transactions, and each factory receives their addresses as constructor arguments. Factories now sit at 4–8 KB.

The OpenZeppelin-based implementations (every governance model, `GovernanceToken`, `StakedGovernanceToken`, `Treasury`) call `_disableInitializers()` in their constructor, so the implementation itself can never be initialized — only clones can. `ConditionalVault`, `ConditionalToken`, `DecisionMarketPair` and `OpportunityMarket` use a small hand-rolled `_initialized` flag with no constructor lock. That is harmless: clone + initialize happen in one transaction, every clone has its own storage, and none of these contracts use `delegatecall` or `selfdestruct`. Anyone can deploy their own copy of an implementation, so "same ABI" never proves a contract is legitimate — check the factory's registry (e.g. `OpportunityMarketFactory.isMarket`).

## Governance models

| Model | How it decides |
|---|---|
| **Token-weighted** (`Governance.sol`) | Classic one-token-one-vote, snapshot-based |
| **Delegated** | Token holders elect a council; only the council proposes and votes; members can be recalled |
| **Board (Multisig)** | N-of-M designated signers approve directly — no token at all |
| **Quadratic** | Voting weight is the square root of staked balance |
| **Optimistic** | Proposals pass by default after a challenge window, unless disputed and voted down |
| **Conviction** | Continuous support accumulates over time; committed tokens are locked |
| **Sortition** | Council seats filled by a verifiably random draw from an opt-in pool |
| **Liquid** | Direct voting always available, plus revocable, bounded transitive delegation |
| **Sowellian** | A pari-mutuel market on proposal outcomes, resolved by oracle or by a bonded human resolver with optimistic challenge and adjudication |
| **Decision Markets** | Two live trading markets (pass vs. fail) compared by TWAP over a fixed window — no oracle, resolver, or vote |

Plus **Opportunity Markets** — confidential, FHE-encrypted backing of listed opportunities (Zama fhEVM), where which opportunity you back and how much stay encrypted on-chain. Deployed on Ethereum Sepolia, not Monad; see [Opportunity Markets](#opportunity-markets).

## Contracts

| Contract | Responsibility |
|---|---|
| `governance/Governance.sol` + supporting files | Token-weighted orchestration — proposals, voting, quorum/approval, timelocks, execution |
| `governance/{delegate,board,quadratic,optimistic,conviction,sortition,liquid,sowellian,futarchy}/` | The other nine models, each self-contained |
| `governance/futarchy/{ConditionalToken,ConditionalVault,DecisionMarketPair,WMON}.sol` | Decision Markets machinery — split/merge/redeem conditional tokens, constant-product AMM |
| `governance/opportunity-market/` | `OpportunityMarket` + factory (FHE, Sepolia) |
| `token/GovernanceToken.sol` | Raw ERC20 with `ERC20Votes`; minting is governance-controlled |
| `token/StakedGovernanceToken.sol` | Vote-escrow wrapper — stake here to get voting power; optional lock used by Conviction |
| `treasury/Treasury.sol` | Holds funds; acts only on instructions from its registered `governance` |
| `factory/` | One clone-based factory per model, plus the shared `DAOFactoryLib` |
| `distribution/WelcomeDistributor.sol` | Optional capped welcome-token distribution, one claim per address |
| `wrapper/GuardWrapper.sol` | Optional security council: governance proposes an instruction, a signer threshold confirms it before it is forwarded. Signers can never initiate anything |
| `marketplace/NFTMarketplaceWrapper.sol` | Optional EIP-1271 signer for NFT marketplaces — and where a DAO's NFTs live (see [NFTs](#nfts)) |
| `randomness/` | `IRandomnessSource` + Switchboard and Chainlink adapters (used by Sortition) |
| `oracles/` | Switchboard and Chainlink price-feed adapters behind `IMetricOracle` (used by Sowellian) |

## Key design decisions

- **Governance and treasury are decoupled.** A DAO can vote to move to a different model via `transferGovernance()` without funds moving.
- **Voting power requires staking, not just holding**, in every token-based model.
- **Snapshot-based, flash-loan-resistant voting** wherever a discrete vote happens. Where a model has no single voting moment (Conviction), committed tokens are locked instead.
- **Randomness and price data are provider-agnostic.** Sortition and Sowellian depend only on small interfaces; which oracle network sits behind them is a per-deployment choice.
- **One oracle adapter, many feeds.** `IMetricOracle.latestValue(bytes32 selector)` takes a per-proposal selector stored on each Sowellian proposal. `SwitchboardPriceFeedAdapter` treats it as the Switchboard `feedId`, so one deployment serves every feed. `ChainlinkPriceFeedAdapter` ignores it and stays bound to one feed via its constructor — that matches how Chainlink works (each feed is its own contract), so Chainlink needs one adapter per feed.

## Security council (GuardWrapper)

A DAO can put a signer council between its governance and its assets. The DAO passes two proposals — `Treasury.transferGovernance(wrapper)` and, on the raw token, `transferOwnership(wrapper)` — after which Treasury and minting calls only work through the wrapper: governance calls `proposeInstruction(target, value, data)`, and the call is forwarded once enough signers `confirmInstruction`. Signers can confirm, revoke or reject, never initiate. Signer replacement is tenure-gated and needs no signer confirmation — the on-chain timestamp check is the proof — so a council can't entrench itself, and governance can't bypass tenure either. The bot's `/handovertowrapper` computes both handover proposals, and `/proposeaction` automatically routes Treasury and token actions through a linked wrapper after the handover.

## NFTs

`Treasury` has no ERC721/ERC1155 receiver hooks, so `safeTransferFrom` into it reverts — and every ERC1155 transfer is a safe one. Rather than widen the Treasury, **a DAO's NFTs live in its `NFTMarketplaceWrapper`**:

- NFTs are sent to the wrapper, never to the Treasury.
- The wrapper lists them (governance approves the hash the marketplace checks the signature against — for Seaport that is the order's EIP-712 digest, not the raw order hash; the wrapper answers EIP-1271 `isValidSignature`), sends them out (`transferERC721` / `transferERC1155` — which refuse the Treasury as a recipient), or calls a marketplace directly (`execute`).
- Money comes back to the Treasury: `sweepNative` and `sweepERC20` send sale proceeds there.
- Every one of those is `onlyGovernance` — a passed proposal.

## Decision Markets

A proposal's two outcomes — pass and fail — each get a live trading market over a fixed window. Real tokens are split into matched pass/fail conditional tokens; people trade the side they believe in; at the end, whichever market's time-weighted average price is meaningfully higher decides the outcome. Winning-side tokens redeem for real value; losing-side tokens are worthless.

Native currency is wrapped when a proposal is seeded (WMON on Monad; the factory takes the chain's canonical wrapped-native token as `WMON_ADDRESS`, so WETH on Base, WHYPE on HyperEVM). Redemption and liquidity reclaim return the **wrapped** token — call `withdraw()` on it to unwrap.

The constant-product AMM is a derivative of Uniswap V2 core (`github.com/Uniswap/v2-core`), GPL-3.0-or-later; `DecisionMarketPair.sol` carries that license. Everything else in this repository is MIT.

## Opportunity Markets

Uses Zama's fhEVM. `FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig())` resolves the coprocessor by `block.chainid` at construction — no addresses to configure — but it only supports Ethereum mainnet, Sepolia, and local Anvil. On any other chain (including Monad, Base, and HyperEVM) construction reverts with `ZamaProtocolUnsupported()`. This is why Opportunity Markets live on Sepolia.

**Amounts and reward math.** Every amount is encrypted as a 64-bit integer (`euint64`), so a deposit or reward pool above 2^64 - 1 raw units is refused (`AmountTooLarge`) rather than silently truncated. That is ~18 trillion tokens for a 6-decimal stablecoin such as USDC, but only ~18.4 tokens at 18 decimals, so use a low-decimal stablecoin. `computeReward` pays `floor(stakeOnWinner × rewardPool / winningTotal)`, multiplying in 128 bits (`euint128` times the plaintext pool, then divided by the plaintext revealed total), so the product can't overflow; the result always fits back in 64 bits because a backer's stake is part of the winning total. `REWARD_MATH_VERSION()` returns 2 on this implementation. Markets cloned from the earlier implementation multiplied in 64 bits, which wrapped once stake × pool passed ~1.8e19 raw units (e.g. 5,000 USDC × 5,000 USDC paid 1,310 USDC); they keep that behaviour, since a clone's implementation never changes. Only markets from a factory deployed after this fix get the new math.

## Setup

Every import in `remappings.txt` comes from one of two places: a Foundry library in `lib/` or an npm package in `node_modules/`. Versions are the ones pinned in `foundry.lock` and `package-lock.json`.

| Import | Comes from | Version |
|---|---|---|
| `forge-std` | Foundry library (`lib/forge-std`) | v1.16.2 |
| `@openzeppelin/contracts` | Foundry library (`lib/openzeppelin-contracts`) | v5.6.1 |
| `@openzeppelin/contracts-upgradeable` | Foundry library (`lib/openzeppelin-contracts-upgradeable`) | v5.6.1 |
| `forge-fhevm` | Foundry library (`lib/forge-fhevm`) | commit `3ee696f` |
| `@fhevm/solidity` | npm | 0.13.3 |
| `encrypted-types` | npm (also installed as a dependency of `@fhevm/solidity`) | 0.0.4 |
| `@chainlink/contracts` | npm | 1.4.0 |
| `@switchboard-xyz/on-demand-solidity` | npm | 1.1.0 |

**Cloning this repo:** `lib/forge-std` and `lib/openzeppelin-contracts` are committed, and the other two Foundry libraries are submodules. One command gets them all, and `npm ci` installs the exact npm versions from `package-lock.json`:

```bash
git submodule update --init --recursive
npm ci
forge build
```

**Installing each dependency yourself** (a new project, or a missing folder):

```bash
forge install foundry-rs/forge-std@v1.16.2
forge install OpenZeppelin/openzeppelin-contracts@v5.6.1
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1
forge install zama-ai/forge-fhevm@3ee696fba62a32314fde457de28cc29f1191c4cb

npm install @fhevm/solidity@0.13.3
npm install encrypted-types@0.0.4
npm install @chainlink/contracts@1.4.0
npm install @switchboard-xyz/on-demand-solidity@1.1.0
```

Current Foundry doesn't commit on `forge install` by default. Older guides add `--no-commit`, which newer versions reject. `via_ir` and the optimizer are set in `foundry.toml`, so plain `forge build` / `forge test` use them.

`remappings.txt` (committed) maps them:

```
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/
@switchboard-xyz/on-demand-solidity/=node_modules/@switchboard-xyz/on-demand-solidity/
@chainlink/contracts/=node_modules/@chainlink/contracts/
@fhevm/solidity/=node_modules/@fhevm/solidity/
encrypted-types/=node_modules/encrypted-types/
forge-fhevm/=lib/forge-fhevm/src/
```

`openzeppelin-contracts-upgradeable` v5.6.1 does **not** ship `ReentrancyGuardUpgradeable`; `StakedGovernanceToken` uses a small, explicitly initialized guard of its own instead.

### `--via-ir` and contract size

Foundry compiles the whole project together, so the simplest rule is: **always build, test, and deploy with `--via-ir`** — `SortitionDAOFactory` and `DecisionMarketsDAOFactory` hit "stack too deep" in `createDAO()` without it.

Contract size depends on the chain:

| Chain | Size limit | Build with |
|---|---|---|
| Monad (testnet, mainnet) | None in practice — `DelegateGovernance` and `SowellianGovernance` (~29.2 KB unoptimized) are deployed there | the default profile, `--via-ir` |
| Base, Base Sepolia, HyperEVM | EIP-170: 24,576 bytes | `FOUNDRY_PROFILE=size-limited` (via-IR + optimizer, 200 runs). Every contract is under 15 KB; the largest are `DelegateGovernance` 14.6 KB and `SowellianGovernance` 14.5 KB |

With the optimizer on, via-IR caches `block.number`/`block.timestamp` across `vm.roll`/`vm.warp` inside a test, so tests read `vm.getBlockNumber()`/`vm.getBlockTimestamp()` instead. With those test edits the full suite passes under both profiles, which means the exact bytecode you deploy to a size-limited chain is the bytecode the tests ran against.

## Testing

```bash
forge test --via-ir                          # default profile (Monad)
FOUNDRY_PROFILE=size-limited forge test      # optimized, as deployed to Base / HyperEVM
```

Current result: **545 tests passed, 0 failed, 0 skipped** across 32 suites under both (Foundry 1.5.1, solc 0.8.33) — every governance model, every factory, the token/treasury core, GuardWrapper, the NFT wrapper (including against a real `Treasury`), adapters, the futarchy system and Opportunity Markets.

## Deployment

Each model has a deploy script that deploys its implementations, then its factory:

```bash
forge script script/Deploy<Model>DAOFactory.s.sol:Deploy<Model>DAOFactory \
  --rpc-url <RPC_URL> \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --via-ir \
  --verify
```

`<Model>` is one of: *(empty, for token-weighted)*, `Quadratic`, `Liquid`, `Optimistic`, `Delegate`, `Board`, `Sortition`, `Conviction`, `Sowellian`, `DecisionMarkets`. `DeployDecisionMarketsDAOFactory` additionally needs `WMON_ADDRESS` (the chain's canonical wrapped-native token). Opportunity Markets: `DeployOpportunityMarketFactory.s.sol` against a **Sepolia** RPC.

On **Base / Base Sepolia / HyperEVM**, prefix every deploy with `FOUNDRY_PROFILE=size-limited` (see [contract size](#--via-ir-and-contract-size)).

On **HyperEVM**, blocks come in two sizes: small (~1 s, 2M gas) and big (~1 min, 30M gas). Deploying an implementation or factory needs more than 2M gas, so the deploying address must be switched to big blocks first (a HyperCore `evmUserModify` action with `usingBigBlocks: true` — check Hyperliquid's docs for the current method), and switched back afterwards. DAO creation fits in small blocks: the heaviest, `DelegateDAOFactory.createDAO`, measured 1.29M gas.

`GuardWrapper` and `NFTMarketplaceWrapper` have no deploy scripts: they are per-DAO and the bot deploys them on demand (`/deployguardwrapper`, `/deploynftwrapper`).

Oracle and randomness adapters are standalone, one-time deployments:

```bash
# Randomness for Sortition (second arg: minimum settlement delay, seconds)
forge create src/randomness/SwitchboardRandomnessAdapter.sol:SwitchboardRandomnessAdapter \
  --rpc-url <RPC_URL> --private-key $PRIVATE_KEY --broadcast \
  --constructor-args <SWITCHBOARD_PROXY> 60

# Price feeds for Sowellian — one deployment serves every Switchboard feed
forge create src/oracles/SwitchboardPriceFeedAdapter.sol:SwitchboardPriceFeedAdapter \
  --rpc-url <RPC_URL> --private-key $PRIVATE_KEY --broadcast \
  --constructor-args <SWITCHBOARD_PROXY>
```

DAOs are created from a deployed factory with the matching `Create<Model>DAO.s.sol` script (see each script's header for its env vars — e.g. `INITIAL_SIGNERS` for Board, `INITIAL_COUNCIL` for Delegate and Sortition, `RANDOMNESS_SOURCE` for Sortition), or through the bot's `/createdao`.

**Never pass a raw private key inline.** `export PRIVATE_KEY=...` once, reference `$PRIVATE_KEY`. Watch for editors converting `--` into an em dash (`—`) — Foundry silently ignores the mangled flag.

## Deployed addresses

Only factory addresses need to be configured anywhere; implementation addresses are baked into each factory's immutable storage at deployment.

### Monad Testnet

| Contract | Address |
|---|---|
| DAOFactory (token-weighted) | `0x8bB68e835032e58c410125e5219B8Ae7FcAcc056` |
| QuadraticDAOFactory | `0x9d109ba81002B85a48252115Ed5487F6b60C78F9` |
| LiquidDAOFactory | `0x55C89331FA2F6a71E375c6C2aAf9BbE5b9b17fFe` |
| OptimisticDAOFactory | `0x8F5a20c910aEbF287790e04799Ce0DB677705674` |
| DelegateDAOFactory | `0x3fFb77D2A380C52e04b8d22E73EDc7d47e8f975c` |
| BoardDAOFactory | `0x2367d102B71ab6c3c3b69eD7580c3Be3ACb5BE9A` |
| SortitionDAOFactory | `0xBeB038379CD821811ab097308fABF89BcA4bBA7B` |
| ConvictionDAOFactory | `0x14439Fa27258c8fd65F5805eA5617774891f173c` |
| SowellianDAOFactory | `0x075289669Ab8601dd8b15D95551644D511949056` |
| DecisionMarketsDAOFactory | `0x99DeC80E792f9C1fA92F46fe08c6763CBCCfE388` |
| SwitchboardRandomnessAdapter (Sortition) | `0x2Ae2019Ac0e642C6bB9eBabD6F2c06bFFf4B2D1E` |
| SwitchboardPriceFeedAdapter (Sowellian) | `0x4DBe57b8ed392a71C87f1ABCda299036A54F2e14` |


External dependencies on Monad testnet (third-party, verified against official docs):

| Dependency | Address | Source |
|---|---|---|
| WMON (canonical) | `0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541` | docs.monad.xyz — Canonical Contracts |
| Switchboard proxy (feeds + randomness) | `0x6724818814927e057a693f4e3A172b6cC1eA690C` | docs.switchboard.xyz — Monad |


### Ethereum Sepolia (Opportunity Markets)

| Contract | Address |
|---|---|
| OpportunityMarketFactory | `0xe61C9d371D3BEA6ceA5359E745593D8ebB39BEC5` |
| OpportunityMarket implementation | `0xc708729e349ED5F7dDB459Ec1d68b6163125EfE6` |

These are the pre-fix deployment (64-bit reward math, see [Opportunity Markets](#opportunity-markets)). Redeploy with `DeployOpportunityMarketFactory.s.sol` and point the bot's `OPPORTUNITY_MARKET_FACTORY_ADDRESS` at the new factory so new markets get the 128-bit math.

### Base, HyperEVM and Monad mainnet — not yet deployed

The bot supports these networks (see `protean-bot`'s README, "Networks"); each needs its own factories deployed before DAOs can be created there.

| Network | Chain ID | Public RPC | Build profile |
|---|---|---|---|
| Monad mainnet | 143 | `https://rpc.monad.xyz` | default |
| Base | 8453 | `https://mainnet.base.org` | `size-limited` |
| Base Sepolia | 84532 | `https://sepolia.base.org` | `size-limited` |
| HyperEVM | 999 | `https://rpc.hyperliquid.xyz/evm` | `size-limited`, big blocks for deploys |
| HyperEVM testnet | 998 | `https://rpc.hyperliquid-testnet.xyz/evm` | `size-limited`, big blocks for deploys |

Chain IDs and RPCs are from viem's chain definitions. For each network, fill in:

| Contract | Address |
|---|---|
| DAOFactory (token-weighted) | |
| QuadraticDAOFactory | |
| LiquidDAOFactory | |
| OptimisticDAOFactory | |
| DelegateDAOFactory | |
| BoardDAOFactory | |
| SortitionDAOFactory | |
| ConvictionDAOFactory | |
| SowellianDAOFactory | |
| DecisionMarketsDAOFactory | |
| Randomness adapter (Sortition) | |
| Price-feed adapter (Sowellian) | |

Before deploying to any of them, verify against the chain's own docs: the canonical wrapped native token (`WMON_ADDRESS` for Decision Markets — WETH on Base, WHYPE on HyperEVM); whether Switchboard and/or Chainlink run randomness and price feeds there, and their real addresses. Opportunity Markets cannot deploy on any of them (see above).

## Known gaps

- **No audit.** Sowellian, Decision Markets, and Opportunity Markets move real capital based on market or oracle resolution — test adversarially before real funds touch them.
- **Keepers are required for Switchboard.** Both randomness and price feeds are pull-based; someone must submit settlement or feed updates. The bot ships both: a sortition keeper and a price-feed keeper for Sowellian's oracle track (one process per network).
- **Proposals are calldata.** The contracts take raw target/value/calldata. The bot's verified action library covers every native admin function (`/proposeaction`); external protocol actions (DEXs, lending, staking, marketplaces) are not built yet.
- **Resolver incentives.** A correct Sowellian resolver gets their bond back, not an additional reward.
- **Rounding dust.** Pari-mutuel payouts round down; tiny residual balances are recoverable by an ordinary governance proposal.
