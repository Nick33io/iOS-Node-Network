"""Checks that run before any swap is signed or booked."""

from __future__ import annotations

from dataclasses import dataclass

from robot_billy.jupiter import SOL_MINT, USDC_MINT
from robot_billy.ledger import Bot

DEFAULT_ALLOW = (SOL_MINT, USDC_MINT)


class GateError(RuntimeError):
    pass


@dataclass(frozen=True)
class Limits:
    max_trade_micro: int
    max_daily_loss_micro: int
    max_price_impact: float = 0.01
    allow_mints: tuple[str, ...] = DEFAULT_ALLOW


def price_impact(order: dict) -> float:
    raw = order.get("priceImpact")
    if raw is None:
        raw = order.get("priceImpactPct")
    if raw is None:
        return 0.0
    try:
        value = abs(float(raw))
    except (TypeError, ValueError):
        raise GateError("Jupiter price impact was not a number") from None
    if value > 1:
        value = value / 100.0
    return value


def check_order(order: dict, bot: Bot, limits: Limits, *, live: bool, spend_micro: int, entry: bool) -> None:
    input_mint = str(order.get("inputMint", ""))
    output_mint = str(order.get("outputMint", ""))
    if input_mint not in limits.allow_mints or output_mint not in limits.allow_mints:
        raise GateError("mint is not on the competition allowlist")
    if entry:
        if bot.today_pnl_micro <= -limits.max_daily_loss_micro:
            raise GateError(f"{bot.bot_id} is halted for the day")
        if spend_micro <= 0:
            raise GateError("trade size must be positive")
        if spend_micro > limits.max_trade_micro:
            raise GateError("trade is above the max trade size")
        if spend_micro > bot.cash_micro:
            raise GateError(f"{bot.bot_id} cannot spend another bot's allocation")
        impact = price_impact(order)
        if impact > limits.max_price_impact:
            raise GateError(f"price impact {impact:.4f} is above the cap")
    try:
        in_amount = int(order["inAmount"])
        out_amount = int(order["outAmount"])
    except (KeyError, TypeError, ValueError):
        raise GateError("Jupiter order was missing inAmount or outAmount") from None
    if in_amount <= 0 or out_amount <= 0:
        raise GateError("Jupiter order had an empty amount")
    transaction = order.get("transaction")
    if live:
        if not isinstance(transaction, str) or transaction == "":
            code = order.get("errorCode")
            message = order.get("errorMessage") or "no transaction"
            raise GateError(f"Jupiter could not build a transaction ({code}: {message})")
        if not order.get("requestId"):
            raise GateError("Jupiter order was missing requestId")
