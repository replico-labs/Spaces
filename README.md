# DAO Spaces

A governance-agnostic DAO framework — an original, from-scratch on-chain governance protocol where a DAO's treasury and its governance rules are kept as two separate, swappable pieces, rather than locked together.

Every module — proposal lifecycle, voting, quorum/approval math, timelocks, and every one of the ten governance models below — is implemented from scratch, purpose-built for this framework. The companion Telegram bot lives in [`protean-bot`](https://github.com/replico-labs/protean-bot).

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

Every implementation's constructor calls `_disableInitializers()`, so implementations themselves can never be initialized — only clones can.

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
| `randomness/` | `IRandomnessSource` + Switchboard and Chainlink adapters (used by Sortition) |
| `oracles/` | Switchboard and Chainlink price-feed adapters behind `IMetricOracle` (used by Sowellian) |

## Key design decisions

- **Governance and treasury are decoupled.** A DAO can vote to move to a different model via `transferGovernance()` without funds moving.
- **Voting power requires staking, not just holding**, in every token-based model.
- **Snapshot-based, flash-loan-resistant voting** wherever a discrete vote happens. Where a model has no single voting moment (Conviction), committed tokens are locked instead.
- **Randomness and price data are provider-agnostic.** Sortition and Sowellian depend only on small interfaces; which oracle network sits behind them is a per-deployment choice.
- **One oracle adapter, many feeds.** `IMetricOracle.latestValue(bytes32 selector)` takes a per-proposal selector stored on each Sowellian proposal. `SwitchboardPriceFeedAdapter` treats it as the Switchboard `feedId`, so one deployment serves every feed. `ChainlinkPriceFeedAdapter` ignores it and stays bound to one feed via its constructor — that matches how Chainlink works (each feed is its own contract), so Chainlink needs one adapter per feed.

## Decision Markets

A proposal's two outcomes — pass and fail — each get a live trading market over a fixed window. Real tokens are split into matched pass/fail conditional tokens; people trade the side they believe in; at the end, whichever market's time-weighted average price is meaningfully higher decides the outcome. Winning-side tokens redeem for real value; losing-side tokens are worthless.

Native MON is wrapped into WMON when a proposal is seeded. Redemption and liquidity reclaim return **WMON, not MON** — call `WMON.withdraw()` to unwrap.

The constant-product AMM is a derivative of Uniswap V2 core (`github.com/Uniswap/v2-core`), GPL-3.0-or-later; `DecisionMarketPair.sol` carries that license. Everything else in this repository is MIT.

## Opportunity Markets

Uses Zama's fhEVM. `FHE.setCoprocessor(ZamaConfig.getEthereumCoprocessorConfig())` resolves the coprocessor by `block.chainid` at construction — no addresses to configure — but it only supports Ethereum mainnet, Sepolia, and local Anvil. On any other chain (including Monad, Base, and HyperEVM) construction reverts with `ZamaProtocolUnsupported()`. This is why Opportunity Markets live on Sepolia.

## Setup

```bash
git submodule update --init --recursive
forge install OpenZeppelin/openzeppelin-contracts-upgradeable@v5.6.1 --no-commit
npm install @switchboard-xyz/on-demand-solidity@1.1.0 @chainlink/contracts@1.4.0
forge build --via-ir
```

`remappings.txt` must include:

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

### `--via-ir` requirements

Foundry compiles the whole project together, so the simplest rule is: **always build, test, and deploy with `--via-ir`.** For reference:

| Contract | Without `--via-ir` | Reason |
|---|---|---|
| `SortitionDAOFactory`, `DecisionMarketsDAOFactory` | Won't compile | "Stack too deep" in `createDAO()` |
| `DelegateGovernance`, `SortitionGovernance`, `SowellianGovernance` | Compiles, but exceeds 24,576 bytes | Won't deploy |
| Everything else | Fine | — |

## Testing

```bash
forge test --via-ir
```

Current result: **468 tests passed, 0 failed, 0 skipped** across 30 suites — every governance model, every factory, the token/treasury core, adapters, and the futarchy system.

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

`<Model>` is one of: *(empty, for token-weighted)*, `Quadratic`, `Liquid`, `Optimistic`, `Delegate`, `Board`, `Sortition`, `Conviction`, `Sowellian`, `DecisionMarkets`. `DeployDecisionMarketsDAOFactory` additionally needs `WMON_ADDRESS`. Opportunity Markets: `DeployOpportunityMarketFactory.s.sol` against a **Sepolia** RPC.

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
| OpportunityMarketFactory | `0xc6d9D3e0be0Bdf4Df84dF90B948C9D2949452dB5` |
| OpportunityMarket implementation | `0x72648d7954877Dadd9B38D71EE3C70e245D29B3a` |

### Hyperliquid (HyperEVM) — not yet deployed

Chain ID: `998` · RPC: `https://rpc.hyperliquid-testnet.xyz/evm`

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

Before deploying here, verify: the chain's canonical wrapped native token (needed as `WMON_ADDRESS` for Decision Markets); whether Switchboard and/or Chainlink have live randomness and feed infrastructure on this network, and their real addresses. Opportunity Markets cannot deploy here (see above).

### Base — not yet deployed

Chain ID: `84532` · RPC: `https://sepolia.base.org`

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

Same checks as Hyperliquid: the canonical wrapped native token for Decision Markets, real Switchboard/Chainlink addresses on this network, and no Opportunity Markets.

## Known gaps

- **No audit.** Sowellian, Decision Markets, and Opportunity Markets move real capital based on market or oracle resolution — test adversarially before real funds touch them.
- **Keepers are required for Switchboard.** Both randomness and price feeds are pull-based; someone must submit settlement or feed updates. The bot ships a sortition keeper; a price-feed updater is not built yet.
- **No transaction compiler.** Proposals take raw target/value/calldata.
- **Resolver incentives.** A correct Sowellian resolver gets their bond back, not an additional reward.
- **Rounding dust.** Pari-mutuel payouts round down; tiny residual balances are recoverable by an ordinary governance proposal.
