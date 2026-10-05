# roBot billy

Six-bot competition that prices SOL/USDC on Jupiter Swap V2 and, only when you explicitly arm it, signs with your Solana wallet and submits the swap to Jupiter `/execute`.

The Launch Desk tree on the Mac (`~/Desktop/Completion Coder/Launch Desk`) is not in this repository. This package is the competition runtime: capital rules, Jupiter orders, and wallet signing.

## Run a paper round

```bash
python -m pip install -r robot-billy/requirements.txt
export PYTHONPATH=robot-billy/src
python -m robot_billy quote
python -m robot_billy round --mode paper
python -m robot_billy status
python -m robot_billy serve
```

The status page is http://127.0.0.1:8787. It can run another paper round. It has no live-trade route.

Paper mode starts from a $6,000 virtual book, $1,000 per bot. It uses Jupiter's quoted `outAmount` and does not sign. State is stored in `robot-billy/var/state.json`.

`JUPITER_API_KEY` is optional for a keyless quote and required once Jupiter rate-limits you. Create one at https://developers.jup.ag/portal.

## Arm a real wallet

Put a Solana CLI keypair path in the environment. Do not commit the file.

```bash
export WALLET_KEYPAIR_PATH="$HOME/.config/solana/id.json"
export SOLANA_RPC_URL="https://api.mainnet-beta.solana.com"
export JUPITER_API_KEY="your-key"
python -m robot_billy wallet
```

`wallet` prints the public key and the SOL and USDC balances. It does not print the secret.

Live swaps stay off until both of these are set:

```bash
export ROBOT_BILLY_LIVE=1
export ROBOT_BILLY_LIVE_CONFIRM=I_UNDERSTAND_THIS_CAN_LOSE_FUNDS
python -m robot_billy round --mode live
```

That command can spend USDC from the wallet. A failed landing leaves a pending flag so the next round will not send a second transaction. Clear it only after you have checked the wallet:

```bash
python -m robot_billy clear-pending --i-confirmed-the-swap-failed
```

## Agents

Three managers sit over six competition agents. Each competition agent has one bot.

- **D33P** trains a strategy ranking from the last two recorded prices and deploys one strategy onto each of the six competition agents.
- **Assist** accepts that deployment only when it covers all six agents, the prices were actually quoted, and the spending cap does not rise. It suspends a competition agent that is down by the daily-loss limit. It cannot invent a price.
- **Operations** runs the round. It opens new trades only for agents Assist left active, and it cannot rewrite the cap. Exits still run for a suspended agent.
- **Bots** decide the buy and the sell from the strategy deployed to their agent: momentum, pullback, or range, with that strategy's entry, stop, and time limit.

`python -m robot_billy agents` prints the managers, the six deployments, and the latest round. The status page shows the same stack.

## Rules the field actually enforces

- Six bots: two momentum, two pullback, two range. Each can spend only its own cash.
- A $1,000 bot that realizes a $500 gain can deploy $1,125 that day. The next UTC day its allowance is $1,025 (base plus 5% of the positive net).
- Losses reduce buying power in full. Open positions stay reserved.
- New entries default to SOL and USDC, at most $50, and they stop for the day after a $100 loss. Set `ROBOT_BILLY_ALLOW_MINTS` to add mints. Entries above 1% price impact are rejected.
- Exits use Jupiter's quote: 4% stop (3% for range), half off at +10% when price is still rising, otherwise all of it, then a 4% trail. Time stops are 60, 90, and 45 minutes.

This can lose the entire balance you leave on the wallet. A paper hour of the earlier desk did not show a profitable strategy. Nothing here manufactures a fill when Jupiter has no route.
