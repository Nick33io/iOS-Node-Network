"""Command line for the competition."""

from __future__ import annotations

import argparse
import json
import os
import sys

from robot_billy.competition import (
    Desk,
    LiveDisabled,
    assert_live_enabled,
    bankroll_micro,
    default_limits,
    run_round,
    state_path,
    today_utc,
)
from robot_billy.jupiter import SOL_MINT, USDC_MINT, JupiterClient, JupiterError, sol_price_usdc
from robot_billy.ledger import roll_day
from robot_billy.rpc import SolanaRpc
from robot_billy.wallet import WalletError, load_wallet


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="robot-billy")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status")
    sub.add_parser("agents")
    quote = sub.add_parser("quote")
    quote.add_argument("--amount", type=int, default=10_000_000, help="probe size in SOL lamports")

    rnd = sub.add_parser("round")
    rnd.add_argument("--mode", choices=("paper", "live"), default="paper")

    sub.add_parser("roll-day")
    sub.add_parser("reset")
    pending = sub.add_parser("clear-pending")
    pending.add_argument("--i-confirmed-the-swap-failed", action="store_true")

    serve = sub.add_parser("serve")
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8787)

    wallet = sub.add_parser("wallet")
    args = parser.parse_args(argv)
    try:
        if args.command == "status":
            return _status()
        if args.command == "agents":
            return _agents()
        if args.command == "quote":
            return _quote(args.amount)
        if args.command == "round":
            return _round(args.mode)
        if args.command == "roll-day":
            return _roll()
        if args.command == "reset":
            return _reset()
        if args.command == "clear-pending":
            return _clear_pending(args.i_confirmed_the_swap_failed)
        if args.command == "serve":
            return _serve(args.host, args.port)
        if args.command == "wallet":
            return _wallet()
    except (LiveDisabled, WalletError, JupiterError) as exc:
        print(str(exc), file=sys.stderr)
        return 2
    return 2


def _desk() -> Desk:
    return Desk.open(state_path(), default_limits(), bankroll_micro(), today_utc())


def _jupiter() -> JupiterClient:
    return JupiterClient(
        base_url=os.environ.get("JUPITER_BASE_URL", "https://api.jup.ag/swap/v2"),
        api_key=os.environ.get("JUPITER_API_KEY") or None,
    )


def _status() -> int:
    desk = _desk()
    print(json.dumps(desk.snapshot(), indent=2))
    return 0


def _agents() -> int:
    desk = _desk()
    print(json.dumps(desk.state.agents or {"convened": False}, indent=2))
    return 0


def _quote(amount: int) -> int:
    order = _jupiter().order(SOL_MINT, USDC_MINT, amount, taker=None)
    price = sol_price_usdc(order)
    print(json.dumps({"price_usdc": price, "inAmount": order.get("inAmount"), "outAmount": order.get("outAmount"), "router": order.get("router"), "priceImpact": order.get("priceImpact")}, indent=2))
    return 0


def _round(mode: str) -> int:
    desk = _desk()
    wallet = None
    rpc = None
    if mode == "live":
        assert_live_enabled()
        wallet = load_wallet()
        if wallet is None:
            raise LiveDisabled("live mode needs WALLET_KEYPAIR_PATH or BS58_PRIVATE_KEY")
        rpc = SolanaRpc(url=os.environ.get("SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com"))
    snapshot = run_round(desk, _jupiter(), mode=mode, wallet=wallet, rpc=rpc)
    print(json.dumps(snapshot, indent=2))
    return 0


def _roll() -> int:
    desk = _desk()
    for bot in desk.state.bots:
        roll_day(bot)
    desk.state.day = today_utc()
    desk.save()
    print(json.dumps(desk.snapshot(), indent=2))
    return 0


def _reset() -> int:
    if os.environ.get("ROBOT_BILLY_LIVE") == "1":
        raise LiveDisabled("refusing to reset the ledger while ROBOT_BILLY_LIVE=1")
    path = state_path()
    if path.exists():
        path.unlink()
    desk = _desk()
    desk.save()
    print(json.dumps(desk.snapshot(), indent=2))
    return 0


def _clear_pending(confirmed: bool) -> int:
    if not confirmed:
        raise LiveDisabled("pass --i-confirmed-the-swap-failed after you check the wallet")
    desk = _desk()
    desk.state.pending = None
    desk.save()
    print(json.dumps(desk.snapshot(), indent=2))
    return 0


def _serve(host: str, port: int) -> int:
    from robot_billy.http_api import serve

    if host not in {"127.0.0.1", "localhost"}:
        raise LiveDisabled("the status server binds to localhost only")
    desk = _desk()

    def paper_round() -> dict:
        if os.environ.get("ROBOT_BILLY_LIVE") == "1":
            raise LiveDisabled("this process is marked live; the status page will not trade")
        return run_round(desk, _jupiter(), mode="paper")

    server = serve(desk, paper_round, host=host, port=port)
    print(f"roBot billy status on http://{host}:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        return 0
    return 0


def _wallet() -> int:
    wallet = load_wallet()
    if wallet is None:
        print(json.dumps({"configured": False}))
        return 0
    rpc = SolanaRpc(url=os.environ.get("SOLANA_RPC_URL", "https://api.mainnet-beta.solana.com"))
    payload = {
        "configured": True,
        "public_key": wallet.public_key,
        "sol_lamports": rpc.get_balance_lamports(wallet.public_key),
        "usdc_atoms": rpc.get_token_atoms(wallet.public_key, USDC_MINT),
    }
    print(json.dumps(payload, indent=2))
    return 0
