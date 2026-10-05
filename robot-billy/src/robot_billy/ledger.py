"""Per-bot capital. Bots cannot spend another bot's allocation.

Worked example from the competition rules, in dollars:

- A bot with a $1,000 base that realizes a $500 gain can deploy $1,125 that
  day. Same-day buying power returns the closed cost plus 25% of the gain.
- The next day the allowance resets to the base plus 5% of that positive net,
  which is $1,025.
- Losses reduce buying power in full. Open positions stay reserved.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field

USDC_MICRO = 1_000_000


def usd(dollars: float) -> int:
    return int(round(dollars * USDC_MICRO))


@dataclass
class Position:
    mint: str
    atoms: int
    cost_micro: int
    entry_px: float
    high_px: float
    opened_ts: float
    halved: bool
    strategy: str

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, raw: dict) -> "Position":
        return cls(
            mint=str(raw["mint"]),
            atoms=int(raw["atoms"]),
            cost_micro=int(raw["cost_micro"]),
            entry_px=float(raw["entry_px"]),
            high_px=float(raw["high_px"]),
            opened_ts=float(raw["opened_ts"]),
            halved=bool(raw["halved"]),
            strategy=str(raw["strategy"]),
        )


@dataclass
class Bot:
    bot_id: str
    strategy: str
    base_micro: int
    cash_micro: int
    reserved_micro: int = 0
    locked_micro: int = 0
    today_pnl_micro: int = 0
    lifetime_pnl_micro: int = 0
    position: Position | None = None

    def to_json(self) -> dict:
        payload = asdict(self)
        payload["position"] = self.position.to_json() if self.position else None
        return payload

    @classmethod
    def from_json(cls, raw: dict) -> "Bot":
        position = raw.get("position")
        return cls(
            bot_id=str(raw["bot_id"]),
            strategy=str(raw["strategy"]),
            base_micro=int(raw["base_micro"]),
            cash_micro=int(raw["cash_micro"]),
            reserved_micro=int(raw.get("reserved_micro", 0)),
            locked_micro=int(raw.get("locked_micro", 0)),
            today_pnl_micro=int(raw.get("today_pnl_micro", 0)),
            lifetime_pnl_micro=int(raw.get("lifetime_pnl_micro", 0)),
            position=Position.from_json(position) if position else None,
        )


def open_field(bankroll_micro: int, strategies: tuple[str, ...] | None = None) -> list[Bot]:
    names = strategies or ("momentum", "pullback", "range", "momentum", "pullback", "range")
    if len(names) < 1:
        raise ValueError("competition needs at least one bot")
    share = bankroll_micro // len(names)
    if share <= 0:
        raise ValueError("bankroll is too small to split across the field")
    bots: list[Bot] = []
    for index, strategy in enumerate(names, start=1):
        label = f"{strategy}-{index}"
        bots.append(Bot(bot_id=label, strategy=strategy, base_micro=share, cash_micro=share))
    return bots


def buy(bot: Bot, cost_micro: int, mint: str, atoms: int, price: float, now: float) -> None:
    if bot.position is not None:
        raise ValueError(f"{bot.bot_id} already has an open position")
    if cost_micro <= 0 or atoms <= 0:
        raise ValueError("buy size must be positive")
    if cost_micro > bot.cash_micro:
        overshoot = cost_micro - bot.cash_micro
        bot.today_pnl_micro -= overshoot
        bot.lifetime_pnl_micro -= overshoot
        cost_micro = bot.cash_micro
    if cost_micro <= 0:
        raise ValueError(f"{bot.bot_id} cannot spend another bot's allocation")
    bot.cash_micro -= cost_micro
    bot.reserved_micro += cost_micro
    bot.position = Position(
        mint=mint,
        atoms=atoms,
        cost_micro=cost_micro,
        entry_px=price,
        high_px=price,
        opened_ts=now,
        halved=False,
        strategy=bot.strategy,
    )


def sell(bot: Bot, atoms: int, proceeds_micro: int) -> int:
    """Close `atoms` of the position. Returns realized PnL in USDC micro."""
    position = bot.position
    if position is None:
        raise ValueError(f"{bot.bot_id} has no position to sell")
    if atoms <= 0 or atoms > position.atoms:
        raise ValueError("sell size is outside the open position")
    if proceeds_micro < 0:
        raise ValueError("proceeds cannot be negative")
    if atoms == position.atoms:
        cost = position.cost_micro
        close_all = True
    else:
        cost = position.cost_micro * atoms // position.atoms
        close_all = False
    pnl = proceeds_micro - cost
    bot.reserved_micro -= cost
    bot.today_pnl_micro += pnl
    bot.lifetime_pnl_micro += pnl
    if pnl > 0:
        releasable = pnl // 4
        bot.cash_micro += cost + releasable
        bot.locked_micro += pnl - releasable
    else:
        bot.cash_micro += proceeds_micro
    if close_all:
        bot.position = None
    else:
        position.atoms -= atoms
        position.cost_micro -= cost
        position.halved = True
    return pnl


def roll_day(bot: Bot) -> None:
    pnl = bot.today_pnl_micro
    if pnl > 0:
        bot.base_micro = bot.base_micro + pnl // 20
    else:
        bot.base_micro = max(0, bot.base_micro + pnl)
    bot.today_pnl_micro = 0
    bot.locked_micro = 0
    bot.cash_micro = max(0, bot.base_micro - bot.reserved_micro)


@dataclass
class TradeRecord:
    bot_id: str
    side: str
    reason: str
    in_amount: int
    out_amount: int
    input_mint: str
    output_mint: str
    signature: str | None
    paper: bool
    price: float

    def to_json(self) -> dict:
        return asdict(self)

    @classmethod
    def from_json(cls, raw: dict) -> "TradeRecord":
        return cls(
            bot_id=str(raw["bot_id"]),
            side=str(raw["side"]),
            reason=str(raw["reason"]),
            in_amount=int(raw["in_amount"]),
            out_amount=int(raw["out_amount"]),
            input_mint=str(raw["input_mint"]),
            output_mint=str(raw["output_mint"]),
            signature=raw.get("signature"),
            paper=bool(raw["paper"]),
            price=float(raw["price"]),
        )


@dataclass
class FieldState:
    day: str
    bots: list[Bot] = field(default_factory=list)
    prices: list[float] = field(default_factory=list)
    trades: list[TradeRecord] = field(default_factory=list)
    pending: dict | None = None
    last_error: str | None = None
    agents: dict | None = None

    def bot(self, bot_id: str) -> Bot:
        for candidate in self.bots:
            if candidate.bot_id == bot_id:
                return candidate
        raise KeyError(bot_id)

    def to_json(self) -> dict:
        return {
            "version": 1,
            "day": self.day,
            "bots": [bot.to_json() for bot in self.bots],
            "prices": self.prices,
            "trades": [trade.to_json() for trade in self.trades],
            "pending": self.pending,
            "last_error": self.last_error,
            "agents": self.agents,
        }

    @classmethod
    def from_json(cls, raw: dict) -> "FieldState":
        return cls(
            day=str(raw["day"]),
            bots=[Bot.from_json(item) for item in raw["bots"]],
            prices=[float(item) for item in raw.get("prices", [])],
            trades=[TradeRecord.from_json(item) for item in raw.get("trades", [])],
            pending=raw.get("pending"),
            last_error=raw.get("last_error"),
            agents=raw.get("agents"),
        )
