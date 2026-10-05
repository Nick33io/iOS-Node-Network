"""One round of the six-bot competition.

Paper mode books Jupiter's quoted amounts and does not sign.
Live mode signs the /order transaction and submits it to /execute.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, replace
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Callable

from robot_billy.gate import GateError, Limits, check_order
from robot_billy.jupiter import (
    SOL_DECIMALS,
    SOL_MINT,
    USDC_DECIMALS,
    USDC_MINT,
    JupiterClient,
    JupiterError,
    sol_price_usdc,
)
from robot_billy.ledger import USDC_MICRO, Bot, FieldState, TradeRecord, buy, open_field, roll_day, sell, usd
from robot_billy.rpc import SolanaRpc
from robot_billy.wallet import Wallet

LIVE_CONFIRM = "I_UNDERSTAND_THIS_CAN_LOSE_FUNDS"
PROBE_LAMPORTS = 10_000_000  # 0.01 SOL, quote only
MIN_TRADE_MICRO = usd(5)
PRICE_HISTORY = 8
STOPS = {"momentum": 0.04, "pullback": 0.04, "range": 0.03}
HOLD_SECONDS = {"momentum": 60 * 60, "pullback": 90 * 60, "range": 45 * 60}


class LiveDisabled(RuntimeError):
    pass


@dataclass(frozen=True)
class Decision:
    bot_id: str
    side: str
    reason: str
    input_mint: str
    output_mint: str
    amount_atoms: int
    spend_micro: int


def assert_live_enabled(env: dict[str, str] | None = None) -> None:
    values = os.environ if env is None else env
    if values.get("ROBOT_BILLY_LIVE") != "1" or values.get("ROBOT_BILLY_LIVE_CONFIRM") != LIVE_CONFIRM:
        raise LiveDisabled(
            "live swaps are off. Set ROBOT_BILLY_LIVE=1 and "
            f"ROBOT_BILLY_LIVE_CONFIRM={LIVE_CONFIRM} to sign and submit."
        )


def default_limits(env: dict[str, str] | None = None) -> Limits:
    values = os.environ if env is None else env
    allow = values.get("ROBOT_BILLY_ALLOW_MINTS", "").strip()
    mints = tuple(item.strip() for item in allow.split(",") if item.strip()) or (SOL_MINT, USDC_MINT)
    return Limits(
        max_trade_micro=usd(float(values.get("ROBOT_BILLY_MAX_TRADE_USDC", "50"))),
        max_daily_loss_micro=usd(float(values.get("ROBOT_BILLY_MAX_DAILY_LOSS_USDC", "100"))),
        max_price_impact=float(values.get("ROBOT_BILLY_MAX_PRICE_IMPACT", "0.01")),
        allow_mints=mints,
    )


class Desk:
    def __init__(self, state: FieldState, limits: Limits, path: Path | None = None):
        self.state = state
        self.limits = limits
        self.path = path

    @classmethod
    def open(cls, path: Path, limits: Limits, bankroll_micro: int, today: str) -> "Desk":
        if path.exists():
            state = FieldState.from_json(json.loads(path.read_text()))
        else:
            state = FieldState(day=today, bots=open_field(bankroll_micro))
        return cls(state, limits, path)

    def save(self) -> None:
        if self.path is None:
            return
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(".json.tmp")
        temporary.write_text(json.dumps(self.state.to_json(), indent=2))
        temporary.replace(self.path)

    def roll_if_needed(self, today: str) -> bool:
        if self.state.day == today:
            return False
        for bot in self.state.bots:
            roll_day(bot)
        self.state.day = today
        self.save()
        return True

    def note_price(self, price: float) -> None:
        self.state.prices.append(price)
        del self.state.prices[:-PRICE_HISTORY]

    @property
    def last_price(self) -> float | None:
        return self.state.prices[-1] if self.state.prices else None

    @property
    def previous_price(self) -> float | None:
        if len(self.state.prices) < 2:
            return None
        return self.state.prices[-2]

    def plan(self, price: float, now: float) -> list[Decision]:
        decisions: list[Decision] = []
        for bot in self.state.bots:
            exit_decision = plan_exit(bot, price, self.previous_price, self.state.prices, now)
            if exit_decision is not None:
                decisions.append(exit_decision)
                continue
            if bot.today_pnl_micro <= -self.limits.max_daily_loss_micro:
                continue
            entry = plan_entry(bot, price, self.previous_price, self.limits)
            if entry is not None:
                decisions.append(entry)
        return decisions

    def apply_buy(self, bot: Bot, decision: Decision, out_atoms: int, price: float, now: float, trade: TradeRecord) -> None:
        buy(bot, decision.spend_micro, decision.output_mint, out_atoms, price, now)
        self.state.trades.append(trade)
        del self.state.trades[:-50]

    def apply_sell(self, bot: Bot, decision: Decision, proceeds_micro: int, trade: TradeRecord) -> None:
        sell(bot, decision.amount_atoms, proceeds_micro)
        self.state.trades.append(trade)
        del self.state.trades[:-50]

    def snapshot(self) -> dict:
        price = self.last_price
        bots = []
        for bot in self.state.bots:
            sol_atoms = bot.position.atoms if bot.position and bot.position.mint == SOL_MINT else 0
            sol_value = int(sol_atoms / 10**SOL_DECIMALS * price * USDC_MICRO) if price else 0
            bots.append(
                {
                    "bot_id": bot.bot_id,
                    "strategy": bot.strategy,
                    "cash_usdc": bot.cash_micro / USDC_MICRO,
                    "reserved_usdc": bot.reserved_micro / USDC_MICRO,
                    "locked_usdc": bot.locked_micro / USDC_MICRO,
                    "today_pnl_usdc": bot.today_pnl_micro / USDC_MICRO,
                    "lifetime_pnl_usdc": bot.lifetime_pnl_micro / USDC_MICRO,
                    "equity_usdc": (bot.cash_micro + bot.locked_micro + sol_value) / USDC_MICRO,
                    "position_atoms": bot.position.atoms if bot.position else 0,
                    "halted": bot.today_pnl_micro <= -self.limits.max_daily_loss_micro,
                }
            )
        return {
            "day": self.state.day,
            "last_price": price,
            "pending": self.state.pending,
            "last_error": self.state.last_error,
            "bots": bots,
            "trades": [trade.to_json() for trade in self.state.trades[-20:]],
        }


def plan_exit(bot: Bot, price: float, previous: float | None, history: list[float], now: float) -> Decision | None:
    position = bot.position
    if position is None or position.mint != SOL_MINT or position.entry_px <= 0:
        return None
    position.high_px = max(position.high_px, price)
    stop = STOPS.get(bot.strategy, 0.04)
    hold = HOLD_SECONDS.get(bot.strategy, 60 * 60)
    change = price / position.entry_px - 1
    rising = previous is not None and price >= previous
    if price <= position.entry_px * (1 - stop):
        return _sell_decision(bot, position.atoms, "protective stop")
    if now - position.opened_ts >= hold:
        return _sell_decision(bot, position.atoms, "time limit")
    if position.halved and price <= position.high_px * 0.96:
        return _sell_decision(bot, position.atoms, "trail after partial")
    if not position.halved and change >= 0.10:
        if rising:
            half = max(1, position.atoms // 2)
            return _sell_decision(bot, half, "take half at +10%")
        return _sell_decision(bot, position.atoms, "take full at +10%")
    if bot.strategy == "range" and history:
        average = sum(history) / len(history)
        if price >= average and price > position.entry_px:
            return _sell_decision(bot, position.atoms, "back to average")
    return None


def plan_entry(bot: Bot, price: float, previous: float | None, limits: Limits) -> Decision | None:
    if bot.position is not None or previous is None or previous <= 0:
        return None
    ratio = price / previous
    reason = None
    if bot.strategy == "momentum" and ratio >= 1.002:
        reason = "momentum break"
    elif bot.strategy == "pullback" and 0.98 < ratio < 0.995:
        reason = "pullback reclaim"
    elif bot.strategy == "range" and ratio <= 0.99:
        reason = "range discount"
    if reason is None:
        return None
    spend = min(bot.cash_micro, limits.max_trade_micro)
    if spend < MIN_TRADE_MICRO:
        return None
    return Decision(
        bot_id=bot.bot_id,
        side="buy",
        reason=reason,
        input_mint=USDC_MINT,
        output_mint=SOL_MINT,
        amount_atoms=spend,
        spend_micro=spend,
    )


def _sell_decision(bot: Bot, atoms: int, reason: str) -> Decision:
    assert bot.position is not None
    return Decision(
        bot_id=bot.bot_id,
        side="sell",
        reason=reason,
        input_mint=SOL_MINT,
        output_mint=USDC_MINT,
        amount_atoms=atoms,
        spend_micro=0,
    )


def run_round(
    desk: Desk,
    jupiter: JupiterClient,
    *,
    mode: str,
    wallet: Wallet | None = None,
    rpc: SolanaRpc | None = None,
    now: float | None = None,
    today: str | None = None,
    clock: Callable[[], float] | None = None,
) -> dict:
    if mode not in {"paper", "live"}:
        raise ValueError("mode must be paper or live")
    if mode == "live":
        assert_live_enabled()
        if wallet is None:
            raise LiveDisabled("live mode needs WALLET_KEYPAIR_PATH or BS58_PRIVATE_KEY")
        if desk.state.pending:
            raise LiveDisabled("a live swap is still pending; clear it only after you confirm it failed")
    moment = now if now is not None else (clock or _now)()
    day = today or datetime.fromtimestamp(moment, timezone.utc).date().isoformat()
    desk.roll_if_needed(day)
    probe = jupiter.order(SOL_MINT, USDC_MINT, PROBE_LAMPORTS, taker=None)
    price = sol_price_usdc(probe)
    if price is None:
        raise JupiterError("probe quote did not contain a SOL/USDC price")
    desk.note_price(price)
    decisions = desk.plan(price, moment)
    wallet_usdc = None
    if mode == "live":
        assert wallet is not None
        if rpc is None:
            raise LiveDisabled("live mode needs a Solana RPC client")
        wallet_usdc = rpc.get_token_atoms(wallet.public_key, USDC_MINT)
    results = []
    for decision in decisions:
        outcome = _act(desk, jupiter, decision, price, moment, mode, wallet, wallet_usdc)
        results.append(outcome)
        if mode == "live" and desk.state.pending:
            break
        if mode == "live" and decision.side == "buy" and outcome.get("status") == "filled":
            assert wallet_usdc is not None
            wallet_usdc -= int(outcome["in_amount"])
    skipped = [item for item in results if item.get("status") == "skipped"]
    if desk.state.pending is None and skipped:
        desk.state.last_error = str(skipped[-1].get("reason") or "order skipped")
    elif desk.state.pending is None:
        desk.state.last_error = None
    desk.save()
    snapshot = desk.snapshot()
    snapshot["mode"] = mode
    snapshot["results"] = results
    return snapshot


def _act(
    desk: Desk,
    jupiter: JupiterClient,
    decision: Decision,
    price: float,
    now: float,
    mode: str,
    wallet: Wallet | None,
    wallet_usdc: int | None,
) -> dict:
    bot = desk.state.bot(decision.bot_id)
    if mode == "live" and decision.side == "buy" and wallet_usdc is not None:
        if decision.spend_micro > wallet_usdc:
            return _skip(decision, "wallet USDC is below this order")
    taker = wallet.public_key if mode == "live" and wallet is not None else None
    try:
        order = jupiter.order(decision.input_mint, decision.output_mint, decision.amount_atoms, taker=taker)
        check_order(
            order,
            bot,
            desk.limits,
            live=mode == "live",
            spend_micro=decision.spend_micro,
            entry=decision.side == "buy",
        )
    except (GateError, JupiterError) as exc:
        return _skip(decision, str(exc))
    if mode == "paper":
        in_amount = int(order["inAmount"])
        out_amount = int(order["outAmount"])
        _book(desk, bot, decision, in_amount, out_amount, price, now, signature=None, paper=True)
        return {"bot_id": decision.bot_id, "status": "filled", "side": decision.side, "paper": True, "in_amount": in_amount, "out_amount": out_amount}
    assert wallet is not None
    try:
        signed = wallet.sign_transaction(str(order["transaction"]))
    except Exception as exc:
        return _skip(decision, str(exc))
    desk.state.pending = {"bot_id": decision.bot_id, "request_id": order.get("requestId"), "side": decision.side}
    desk.save()
    try:
        result = jupiter.execute(signed, str(order["requestId"]))
    except JupiterError as exc:
        desk.state.last_error = str(exc)
        desk.save()
        return _skip(decision, str(exc))
    if result.get("status") != "Success":
        desk.state.pending = None
        message = str(result.get("error") or result.get("code") or "swap failed")
        desk.state.last_error = message
        desk.save()
        return _skip(decision, message)
    in_amount = int(result.get("totalInputAmount") or order["inAmount"])
    out_amount = int(result.get("totalOutputAmount") or order["outAmount"])
    signature = result.get("signature")
    _book(desk, bot, decision, in_amount, out_amount, price, now, signature=signature, paper=False)
    desk.state.pending = None
    desk.save()
    return {
        "bot_id": decision.bot_id,
        "status": "filled",
        "side": decision.side,
        "paper": False,
        "signature": signature,
        "in_amount": in_amount,
        "out_amount": out_amount,
    }


def _book(
    desk: Desk,
    bot: Bot,
    decision: Decision,
    in_amount: int,
    out_amount: int,
    price: float,
    now: float,
    signature: str | None,
    paper: bool,
) -> None:
    trade = TradeRecord(
        bot_id=bot.bot_id,
        side=decision.side,
        reason=decision.reason,
        in_amount=in_amount,
        out_amount=out_amount,
        input_mint=decision.input_mint,
        output_mint=decision.output_mint,
        signature=signature,
        paper=paper,
        price=price,
    )
    if decision.side == "buy":
        desk.apply_buy(bot, replace(decision, spend_micro=in_amount), out_amount, price, now, trade)
    else:
        desk.apply_sell(bot, decision, out_amount, trade)


def _skip(decision: Decision, reason: str) -> dict:
    return {"bot_id": decision.bot_id, "status": "skipped", "side": decision.side, "reason": reason}


def _now() -> float:
    return datetime.now(timezone.utc).timestamp()


def state_path() -> Path:
    override = os.environ.get("ROBOT_BILLY_STATE")
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[2] / "var" / "state.json"


def bankroll_micro(env: dict[str, str] | None = None) -> int:
    values = os.environ if env is None else env
    return usd(float(values.get("ROBOT_BILLY_BANKROLL_USDC", "6000")))


def today_utc(moment: date | None = None) -> str:
    return (moment or datetime.now(timezone.utc).date()).isoformat()
