"""D33P proposes. VALUE accepts or rejects. Fleet runs only what VALUE left standing.

D33P cannot approve its own proposal. VALUE cannot raise a spending limit or
treat a price that was never quoted as evidence. Fleet cannot rewrite those
limits or ignore a rejection. Exits still run when a strategy is suspended.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass

from robot_billy.gate import Limits
from robot_billy.ledger import FieldState

D33P = "d33p"
FLEET = "fleet"
VALUE = "value"
KNOWN_STRATEGIES = ("momentum", "pullback", "range")


class AuthorityError(RuntimeError):
    pass


@dataclass(frozen=True)
class Proposal:
    author: str
    revision: int
    enabled: tuple[str, ...]
    note: str
    evidence_prices: tuple[float, ...]
    max_trade_micro: int

    def to_json(self) -> dict:
        payload = asdict(self)
        payload["enabled"] = list(self.enabled)
        payload["evidence_prices"] = list(self.evidence_prices)
        return payload


@dataclass(frozen=True)
class Verdict:
    author: str
    revision: int | None
    accepted: bool
    reason: str

    def to_json(self) -> dict:
        return asdict(self)


def blank_agents() -> dict:
    return {
        "revision": 0,
        "enabled": list(KNOWN_STRATEGIES),
        "suspended": [],
        "entries_blocked": False,
        "log": [],
    }


def ensure_agents(state: FieldState) -> dict:
    if not isinstance(state.agents, dict):
        state.agents = blank_agents()
    return state.agents


class D33PAgent:
    """Research seat. It can propose a versioned strategy and nothing else."""

    name = D33P

    def propose(self, state: FieldState, limits: Limits) -> Proposal | None:
        prices = state.prices
        if len(prices) < 2 or prices[-2] <= 0:
            return None
        agents = ensure_agents(state)
        ratio = prices[-1] / prices[-2]
        if ratio >= 1.002:
            enabled: tuple[str, ...] = ("momentum",)
            note = "price is breaking higher; propose momentum only"
        elif ratio <= 0.99:
            enabled = ("range",)
            note = "price is at a discount to the last print; propose range only"
        elif ratio < 0.995:
            enabled = ("pullback",)
            note = "price is pulling back inside the uptrend band; propose pullback only"
        else:
            enabled = KNOWN_STRATEGIES
            note = "no separation from the last print; keep the full field"
        return Proposal(
            author=self.name,
            revision=int(agents["revision"]) + 1,
            enabled=enabled,
            note=note,
            evidence_prices=(float(prices[-2]), float(prices[-1])),
            max_trade_micro=limits.max_trade_micro,
        )


class ValueAgent:
    """Oversight seat. It judges evidence. It does not manage a position."""

    name = VALUE

    def review(self, state: FieldState, proposal: Proposal | None, limits: Limits) -> Verdict:
        if proposal is None:
            return Verdict(self.name, None, False, "no proposal this round")
        if proposal.author != D33P:
            return Verdict(self.name, proposal.revision, False, "proposal did not come from D33P")
        if proposal.max_trade_micro > limits.max_trade_micro:
            return Verdict(self.name, proposal.revision, False, "proposal raises the spending limit")
        if not evidence_is_observed(proposal.evidence_prices, state.prices):
            return Verdict(self.name, proposal.revision, False, "proposal cites a price the desk did not record")
        if not proposal.enabled or any(item not in KNOWN_STRATEGIES for item in proposal.enabled):
            return Verdict(self.name, proposal.revision, False, "proposal names an unknown strategy")
        return Verdict(self.name, proposal.revision, True, proposal.note)


class FleetAgent:
    """Operations seat. It may run an approved strategy inside the existing limits."""

    name = FLEET

    def allow(self, decision, state: FieldState) -> bool:
        if decision.side != "buy":
            return True
        agents = ensure_agents(state)
        if agents.get("entries_blocked"):
            return False
        strategy = state.bot(decision.bot_id).strategy
        if strategy in set(agents.get("suspended") or []):
            return False
        return strategy in set(agents.get("enabled") or [])


class Board:
    def __init__(self) -> None:
        self.d33p = D33PAgent()
        self.value = ValueAgent()
        self.fleet = FleetAgent()

    def convene(self, state: FieldState, limits: Limits) -> dict:
        agents = ensure_agents(state)
        proposal = self.d33p.propose(state, limits)
        verdict = self.value.review(state, proposal, limits)
        self.apply(state, proposal, verdict, limits)
        agents = ensure_agents(state)
        entry = {
            "d33p": proposal.to_json() if proposal else None,
            "value": verdict.to_json(),
            "fleet": {
                "enabled": list(agents["enabled"]),
                "suspended": list(agents["suspended"]),
                "entries_blocked": bool(agents["entries_blocked"]),
            },
        }
        log = list(agents.get("log") or [])
        log.append(entry)
        agents["log"] = log[-20:]
        state.agents = agents
        return agents

    def apply(self, state: FieldState, proposal: Proposal | None, verdict: Verdict, limits: Limits) -> None:
        if verdict.author != VALUE:
            raise AuthorityError("only VALUE can accept or reject a strategy")
        agents = ensure_agents(state)
        if verdict.accepted:
            if proposal is None or proposal.author != D33P:
                raise AuthorityError("VALUE cannot accept a proposal D33P did not write")
            if proposal.max_trade_micro > limits.max_trade_micro:
                raise AuthorityError("VALUE cannot increase spending limits")
            if not evidence_is_observed(proposal.evidence_prices, state.prices):
                raise AuthorityError("VALUE cannot approve a price the desk did not record")
            agents["enabled"] = list(proposal.enabled)
            agents["revision"] = proposal.revision
        agents["suspended"] = losing_strategies(state, limits)
        enabled = set(agents["enabled"]) - set(agents["suspended"])
        agents["entries_blocked"] = len(state.prices) < 2 or not enabled
        state.agents = agents


def evidence_is_observed(cited: tuple[float, ...], observed: list[float]) -> bool:
    if len(cited) < 2:
        return False
    for price in cited:
        if not any(abs(price - item) <= 1e-9 for item in observed):
            return False
    return True


def losing_strategies(state: FieldState, limits: Limits) -> list[str]:
    suspended = []
    for strategy in KNOWN_STRATEGIES:
        bots = [bot for bot in state.bots if bot.strategy == strategy]
        if not bots:
            continue
        pnl = sum(bot.today_pnl_micro for bot in bots)
        if pnl <= -limits.max_daily_loss_micro:
            suspended.append(strategy)
    return suspended
