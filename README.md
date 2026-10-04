# Basq Protocol — Native ERC-7621 ETF Factory for Robinhood Chain

Weighted baskets of tokenized Robinhood stocks, settled in Paxos USDG. One-click mint, streaming creator fees with a factory-locked protocol cut, 24/5 sessions, permissionless keeper rebalancing.

Live app: **https://basq-protocol.vercel.app** · Contracts below are live on Robinhood Chain Testnet (chain ID `46630`).

## How it works

Each ETF is its own ERC-7621 basket contract — which **is** the share token. Holders own a pro-rata claim on the reserves. Three modules customize the standard:

1. **Cash gateway** (`CashGateway.sol`, stateless router) — `contributeWithUSDG` splits one USDG payment across every constituent at the oracle floor and mints shares; `withdrawToUSDG` burns shares and pays back single USDG. Exact previews included.
2. **Streaming fees** — creators earn per-second on shares outstanding; the platform treasury + minimum cut are immutable in the factories (`WrongPlatformTreasury`/`InsufficientPlatformShare` on violation). Owners can only lower rates; raises need the creator.
3. **Robinhood gates** — `RobinhoodAssetRegistry` (only listed 18-decimal stock tokens can enter), `RobinhoodTradingHours` (shared 24/5 Mon 01:00 UTC → Sat 01:00 UTC window; mints/trades revert `MarketClosed` when shut, proportional exits stay open).

`RebalancingETFToken` adds permissionless keeper trades (`rebalanceTrade`/`retireConstituent`) inside oracle-bounded drift bands with slippage floors and keeper rewards.

## Contracts

| Contract | What it does |
|---|---|
| `src/BasketToken.sol` | ERC-7621 core: oracle-valued `contribute`, pro-rata `withdraw`, owner `rebalance`, timelocked oracle rotation |
| `src/ETFToken.sol` | Basket + asset invariant + streaming fee + hours gate |
| `src/RebalancingETFToken.sol` | + keeper rebalancing with drift bands |
| `src/CashGateway.sol` | Stateless USDG entry/exit router with exact previews |
| `src/ETFFactory.sol` / `src/RebalancingETFFactory.sol` | Permissionless deployment with **fixed** platform fee (`platformTreasury`, `minPlatformShareBps`) |
| `src/RobinhoodAssetRegistry.sol` | Stock-token allowlist (`isRobinhoodAsset`) |
| `src/ExecutionRegistry.sol` | Trade-adapter allowlist |
| `src/RobinhoodTradingHours.sol` | 24/5 session + halts + kill-switch |
| `src/oracles/RobinhoodChainlinkOracle.sol` | Chainlink feeds + sequencer guard + `oraclePaused` fail-closed |
| `src/execution/UniswapV2StyleExecution.sol` | Example V2-shaped execution adapter |
| `script/DeployTestnet.s.sol` | Full-stack testnet deploy (+ `TestnetExecution` inventory adapter) |
| `script/MigrateUsdg.s.sol` | Migrates the cash leg to official Paxos USDG |

## Live testnet deployment (chain 46630)

| Component | Address |
|---|---|
| ETFFactory | `0xE259f0e48dfc3B46F8e08E8b1c2EEdec51c6087D` |
| RebalancingETFFactory | `0xfA1F5230101BC821BF952dEfDF8cC60626FD0ff2` |
| CashGateway (real USDG) | `0x124ebdb96c54a162858c50f81e27b608c8e537f9` |
| USDG (official Paxos testnet) | `0x7E955252E15c84f5768B83c41a71F9eba181802F` |
| Asset registry | `0xa8aedc927be2db9830e705f3c19536956ec4c6ba` |
| Trading hours | `0x8ff52249db402537a0639d4c3a03816b1d80c721` |
| Execution registry | `0x9eec0f657aa3b7665533aa0f99df68cff4b89b7e` |
| Oracle (fixed-price, testnet) | `0xfe5ae45b094ad5dd9f9562af3e05c1f0c8db8232` |
| Test adapter (100 USDG inventory) | `0x33a172dc3cc716751275b20d027631cb14c8cf7e` |
| First basket (Testnet Basket, 5×2000bps) | `0xE3641465Df96abe580D2A12312e69AfB288d19BC` |

Basket tokens: AMD `0x7117…978d`, NFLX `0x3b82…68c93`, PLTR `0x1fbe…98d0`, AMZN `0x5884…09e02`, TSLA `0xc9f9…d4e4`. Faucet: `faucet.testnet.chain.robinhood.com` (ETH + stock tokens) · USDG faucet: `faucet.paxos.com` · Explorer: `explorer.testnet.chain.robinhood.com`.

## Quickstart

```bash
forge build
forge test                        # 14/14 (10 unit + 3 fuzz x1000 + platform-fee guards)
forge build --sizes               # all factories under EIP-170

# Deploy to Robinhood testnet (fill .env from .env.example first)
forge script script/DeployTestnet.s.sol:DeployTestnet \
  --rpc-url robinhood_testnet --broadcast
```

## Security notes

Owner trust is explicit (weights, listings, feeds) — use a multisig in production. Oracle lag enables 1-tx contribute+withdraw arbitrage: add entry/exit fees or same-block guards before mainnet. Proportional `withdraw` never touches the oracle, so exits work even on stale feeds. Testnet adapter is inventory-backed and test-only. Not audited — experimental software, not investment advice. Tokenized stocks unavailable to US/UK/CA/CH persons.

## License

CC0-1.0 — every source file carries the `CC0-1.0` SPDX header. OpenZeppelin contracts remain under their own license.
