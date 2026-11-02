---
name: megabull
description: |
  Use when the user wants to claim MegaBull (MBULL) on BNB Chain: mint the free
  agent token (1,000 MBULL per mint, max 10 mints per wallet, 0.0005 BNB mint
  fee per mint, gas separate), check mint status, or trade it after launch.
  Only AI agents with a .ai Agent ID can mint.
triggers: megabull, MBULL, bull, mega bull
metadata:
  version: '0.1.0'
  requires:
    bins: [baw, curl]
---

# MegaBull (MBULL) skill — LIVE ON BNB SMART CHAIN

Status: DEPLOYED and verified on-chain 2026-11-02. Contract
0x544aC5e9F1e853800116eFFf1CB9f8fb0B6E8f10, deploy tx
0x6f339b7fe55dc2ec7773f6c77c8f80009b7bc32b86bd69b820e5d0892cdb258f,
block 131201360, creator and owner 0x9F3b8528bc2EbD30C49A6E809DE3E90f2C236df2.
Mint is open, launched is false. Source verification on BscScan is pending;
do not claim it is verified until BscScan shows it. This token is unaudited.
Website: https://mbull-two.vercel.app/

## Token facts (confirmed on-chain at deploy)
- Name: MegaBull, Symbol: MBULL, Decimals: 18
- Chain: BNB Smart Chain, chain 56
- Total supply: 20,000,000 MBULL
  - 16,000,000 mintable by agents
  - 4,000,000 LP reserve held by the contract for PancakeSwap liquidity
- Mint: 1,000 MBULL per mint, max 10 mints per wallet = 10,000 MBULL per wallet
- Mint fee: 0.0005 BNB per mint, sent straight to the creator/deployer
  address in the same transaction (user clarification 2026-11-02).
  Token price is 0 — the fee is not a token price, and network gas is
  paid separately to BNB Chain on top of it. Exception, 2026-11-02:
  the creator/deployer mints free, value 0, still capped at 10 mints
  per wallet and by the 16,000,000 mintable supply.
- Gate: wallet must hold a Binance .ai Agent ID (registry
  0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F). Verify the registry ABI
  before deploy — do not deploy with an untested gate.
- Tax: 2% buy, 2% sell, only on PancakeSwap pair trades, only after launch.
  Tax tokens: 50% to the creator, 50% retained in the contract (liquidity fund).
  The creator's tax share is used for token buybacks (manual, by the
  creator. The contract does not auto buyback).
  Mint claims are tax-free. Transfers are locked until launch.
- Liquidity: after mint ends, the creator adds liquidity on PancakeSwap
  V2, pairing the 4,000,000 LP reserve with BNB collected from mint
  fees (fees went to the creator at mint time), LP tokens burned to
  0xdead. No pool before that = no trading.

## Contracts
- MBULL token: 0x544aC5e9F1e853800116eFFf1CB9f8fb0B6E8f10
- PancakeSwap pair: not set yet, set only at addLiquidity after mint ends
- PancakeSwap router: 0x10ED43C718714eb63d5aA57B78B54704E256024E

## Rules for you, the agent
- Only act when the user asks. Never mint, buy, sell, or end mint on your own.
- Every `requestId` needs the user's explicit "yes" before `baw contract-call execute`.
  Tell them the function, contract, chain, and exact BNB amount first.
- Never ask for a private key or seed phrase.
- MBULL is speculative and unaudited. Never promise profit, a price, or a return.
  "Free" means token price 0, not that it has value, and the 0.0005 BNB mint
  fee is not refunded if the token never trades.
- Before any mint, read the chain and tell the user: mint open?, mints left
  for their wallet, total minted / 16,000,000, and their BNB balance vs
  mint fee + gas. If they cannot afford fee + gas, stop and tell them.

## 0. Preflight
```bash
baw wallet status --json
baw wallet address --json   # address with binanceChainId 56 as $ME
```

## 1. Reading the chain (RPC: https://bsc-dataseed.bnbchain.org)
Use plain JSON-RPC eth_call. Function selectors must be taken from the
verified deployed contract ABI on BscScan — do not guess selectors in a
live preview. At minimum check, before minting:
- mintOpen(), totalMinted(), mintsByWallet($ME), balanceOf($ME),
  launched(), pair()

## 2. Mint (while mintOpen)
```bash
baw contract-call preview --binanceChainId 56 --from $ME --to $MBULL --value 500000000000000 --inputData 0x1249c58b --json
# Creator mint only: --value 0, same inputData
# After the user's explicit yes:
baw contract-call execute --requestId <id> --json
```
Expected: +1,000 MBULL to $ME, 0.0005 BNB fee to the creator, gas separate.
Repeat up to 10 times per wallet total, never more. After each transaction,
wait for the receipt, confirm status 1, and confirm the balance change
on-chain before reporting a mint as done.

## 3. Launch / trading (after mint ends)
- Owner only: endMint() if supply is not fully minted, then addLiquidity().
- After launch, MBULL trades on PancakeSwap V2 with 2% buy / 2% sell tax.
  Wallet-to-wallet transfers after launch are tax-free in this design only
  when neither side is the pair — confirm the deployed contract's tax
  logic on BscScan before telling a user a transfer is tax-free.
- Before launch, a transfer or sell reverts / is blocked: tell the user
  to wait for the pool.

## 4. Agent claim prompt (paste to an agent that controls a .ai wallet)
> Use my Binance Agentic Wallet on BNB Smart Chain (chain 56) to mint
> MegaBull (MBULL). First check mint status and my mints left, show me
> the preview with the exact 0.0005 BNB mint fee plus gas, and only
> execute after I say yes. Never approve any other spender, never swap,
> and never mint more than 10 times in total for my wallet.
> Contract address: 0x544aC5e9F1e853800116eFFf1CB9f8fb0B6E8f10
