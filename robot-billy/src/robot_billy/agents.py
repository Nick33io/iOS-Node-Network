"""DEEPF#CKINGVALUE.

D33P proposes a deployment. VALUE evaluates it. F#CKING operates only the
version VALUE accepted. VALUE audits the round and reports it to the owner.

D33P cannot approve itself. F#CKING cannot rewrite a risk limit, bypass a
rejection, or grade the round. VALUE cannot raise the spending cap or cite a
price the desk did not record.

The six competition agents trade spot SOL/USDC. Specialist seats that need
EMA, funding, shorts, or liquidation prints stay marked untested.
"""

from __future__ import annotations

from dataclasses import dataclass

from robot_billy.gate import Limits
from robot_billy.ledger import Bot, FieldState

TEAM = "DEEPF#CKINGVALUE"
D33P = "d33p"
FUCKING = "fucking"
VALUE = "value"
KNOWN_STRATEGIES = ("momentum", "pullback", "range")

STRATEGY_SPEC = {
    "momentum": {"entry_ratio": 1.002, "stop": 0.04, "hold_seconds": 60 * 60},
    "pullback": {"entry_ratio": 0.995, "stop": 0.04, "hold_seconds": 90 * 60},
    "range": {"entry_ratio": 0.99, "stop": 0.03, "hold_seconds": 45 * 60},
}

SPECIALISTS = (
    {
        "id": "ares",
        "name": "Ares",
        "role": "bidirectional momentum",
        "status": "untested",
        "gap": "no EMA, RSI, or ATR series, and no short venue",
    },
    {
        "id": "cronos",
        "name": "Cronos",
        "role": "delta-neutral funding carry",
        "status": "untested",
        "gap": "no funding feed and no perp book",
    },
    {
        "id": "hermes",
        "name": "Hermes",
        "role": "spot router",
        "status": "spot-only",
        "gap": "Jupiter SOL/USDC quotes only; Pyth is not consulted",
    },
    {
        "id": "cro",
        "name": "CRO",
        "role": "hard drawdown veto",
        "status": "active",
        "gap": "",
    },
    {
        "id": "cascade",
        "name": "Cascade",
        "role": "liquidation sniping",
        "status": "untested",
        "gap": "no liquidation feed",
    },
)

LEVERAGE = {
    "armed": False,
    "venue": "spot",
    "note": (
        "Charter perp caps stay off. This desk does not open shorts, "
        "funding carries, or liquidation snipes."
    ),
}


class AuthorityError(RuntimeError):
    pass


@dataclass(frozen=True)
class Deployment:
    author: str
    revision: int
    note: str
    evidence_prices: tuple[float, ...]
    max_trade_micro: int
    assignments: tuple[tuple[str, str], ...]

    def to_json(self) -> dict:
        return {
            "author": self.author,
            "revision": self.revision,
            "note": self.note,
            "evidence_prices": list(self.evidence_prices),
            "max_trade_micro": self.max_trade_micro,
            "assignments": [
                {"agent_id": agent_id, "strategy": strategy}
                for agent_id, strategy in self.assignments
            ],
        }


@dataclass(frozen=True)
class Verdict:
    author: str
    revision: int | None
    accepted: bool
    reason: str

    def to_json(self) -> dict:
        return {
            "author": self.author,
            "revision": self.revision,
            "accepted": self.accepted,
            "reason": self.reason,
        }


@dataclass(frozen=True)
class Audit:
    author: str
    revision: int | None
    fills: int
    book_today_pnl_micro: int
    cro_veto: bool
    note: str

    def to_json(self) -> dict:
        return {
            "author": self.author,
            "revision": self.revision,
            "fills": self.fills,
            "book_today_pnl_micro": self.book_today_pnl_micro,
            "cro_veto": self.cro_veto,
            "note": self.note,
        }


def manager_seats() -> dict:
    return {
        "d33p": {"id": D33P, "name": "D33P", "role": "propose"},
        "value": {"id": VALUE, "name": "VALUE", "role": "evaluate"},
        "fucking": {"id": FUCKING, "name": "F#CKING", "role": "operate"},
    }


def blank_agents(state: FieldState | None = None) -> dict:
    roster = []
    if state is not None:
        roster = opening_roster(state)
    return {
        "team": TEAM,
        "managers": manager_seats(),
        "specialists": [dict(item) for item in SPECIALISTS],
        "leverage": dict(LEVERAGE),
        "revision": 0,
        "competition_agents": roster,
        "entries_blocked": False,
        "cro": {"id": "cro", "veto": False, "book_today_pnl_micro": 0},
        "log": [],
    }


def opening_roster(state: FieldState) -> list[dict]:
    roster = []
    for index, bot in enumerate(state.bots, start=1):
        spec = STRATEGY_SPEC[bot.strategy]
        roster.append(
            {
                "id": f"agent-{index}",
                "bot_id": bot.bot_id,
                "strategy": bot.strategy,
                "entry_ratio": spec["entry_ratio"],
                "stop": spec["stop"],
                "hold_seconds": spec["hold_seconds"],
                "revision": 0,
                "suspended": False,
            }
        )
    return roster


def ensure_agents(state: FieldState) -> dict:
    if not isinstance(state.agents, dict) or "competition_agents" not in state.agents:
        state.agents = blank_agents(state)
    elif not state.agents.get("competition_agents"):
        state.agents["competition_agents"] = opening_roster(state)
    agents = state.agents
    agents["team"] = TEAM
    agents["managers"] = manager_seats()
    agents["specialists"] = [dict(item) for item in SPECIALISTS]
    agents["leverage"] = dict(LEVERAGE)
    agents.setdefault("revision", 0)
    agents.setdefault("entries_blocked", False)
    agents.setdefault("log", [])
    agents.setdefault("cro", {"id": "cro", "veto": False, "book_today_pnl_micro": 0})
    return agents


def agent_for_bot(state: FieldState, bot_id: str) -> dict | None:
    agents = state.agents or {}
    for record in agents.get("competition_agents") or []:
        if record.get("bot_id") == bot_id:
            return record
    return None


def strategy_version(state: FieldState, bot_id: str) -> str | None:
    record = agent_for_bot(state, bot_id)
    if record is None:
        return None
    return f"{record['strategy']}@{record['revision']}"


def bot_execution_spec(state: FieldState, bot: Bot) -> dict:
    record = agent_for_bot(state, bot.bot_id)
    if record is None:
        spec = STRATEGY_SPEC[bot.strategy]
        return {"strategy": bot.strategy, **spec}
    return {
        "strategy": record["strategy"],
        "entry_ratio": float(record["entry_ratio"]),
        "stop": float(record["stop"]),
        "hold_seconds": int(record["hold_seconds"]),
    }


def book_today_pnl(state: FieldState) -> int:
    return sum(bot.today_pnl_micro for bot in state.bots)


class D33PAgent:
    """Proposes a ranking and a deployment. Does not accept it."""

    name = D33P

    def train(self, state: FieldState, limits: Limits) -> Deployment | None:
        prices = state.prices
        if len(prices) < 2 or prices[-2] <= 0:
            return None
        agents = ensure_agents(state)
        ratio = prices[-1] / prices[-2]
        if ratio >= 1.002:
            ranked = ("momentum", "pullback", "range")
            note = "proposed an uptrend book; momentum deploys to the first pair"
        elif ratio <= 0.99:
            ranked = ("range", "pullback", "momentum")
            note = "proposed a discount book; range deploys to the first pair"
        elif ratio < 0.995:
            ranked = ("pullback", "momentum", "range")
            note = "proposed a pullback book; pullback deploys to the first pair"
        else:
            ranked = ("momentum", "pullback", "range")
            note = "no separation from the last print; restate the opening book"
        assignments = []
        for index, record in enumerate(agents["competition_agents"]):
            assignments.append((record["id"], ranked[index // 2]))
        return Deployment(
            author=self.name,
            revision=int(agents["revision"]) + 1,
            note=note,
            evidence_prices=(float(prices[-2]), float(prices[-1])),
            max_trade_micro=limits.max_trade_micro,
            assignments=tuple(assignments),
        )


class ValueAgent:
    """Evaluates a proposal and later audits the round for the owner."""

    name = VALUE

    def review(self, state: FieldState, deployment: Deployment | None, limits: Limits) -> Verdict:
        if deployment is None:
            return Verdict(self.name, None, False, "no deployment this round")
        if deployment.author != D33P:
            return Verdict(self.name, deployment.revision, False, "deployment did not come from D33P")
        if deployment.max_trade_micro > limits.max_trade_micro:
            return Verdict(self.name, deployment.revision, False, "deployment raises the spending limit")
        if not evidence_is_observed(deployment.evidence_prices, state.prices):
            return Verdict(self.name, deployment.revision, False, "deployment cites a price the desk did not record")
        roster = ensure_agents(state)["competition_agents"]
        expected = [record["id"] for record in roster]
        got = [agent_id for agent_id, _strategy in deployment.assignments]
        if got != expected:
            return Verdict(self.name, deployment.revision, False, "deployment does not cover the six competition agents")
        if any(strategy not in KNOWN_STRATEGIES for _agent_id, strategy in deployment.assignments):
            return Verdict(self.name, deployment.revision, False, "deployment names an unknown strategy")
        return Verdict(self.name, deployment.revision, True, deployment.note)

    def audit(self, state: FieldState, fills: int) -> Audit:
        agents = ensure_agents(state)
        pnl = book_today_pnl(state)
        veto = bool((agents.get("cro") or {}).get("veto"))
        revision = agents.get("revision")
        note = f"{fills} fill(s) booked on revision {revision}; book today pnl is {pnl} micro USDC"
        return Audit(
            author=self.name,
            revision=int(revision) if revision is not None else None,
            fills=int(fills),
            book_today_pnl_micro=pnl,
            cro_veto=veto,
            note=note,
        )


class FuckingAgent:
    """Operates the accepted deployment. Does not approve it or audit it."""

    name = FUCKING
    display = "F#CKING"

    def operate(
        self,
        state: FieldState,
        deployment: Deployment | None,
        verdict: Verdict,
        limits: Limits,
    ) -> bool:
        if verdict.author != VALUE or not verdict.accepted:
            return False
        if deployment is None or deployment.author != D33P:
            raise AuthorityError("F#CKING cannot install a deployment D33P did not propose")
        if deployment.revision != verdict.revision:
            raise AuthorityError("F#CKING cannot operate a revision VALUE did not accept")
        if deployment.max_trade_micro > limits.max_trade_micro:
            raise AuthorityError("F#CKING cannot rewrite the spending limit")
        if not evidence_is_observed(deployment.evidence_prices, state.prices):
            raise AuthorityError("F#CKING cannot operate on a price the desk did not record")
        return True

    def audit(self, state: FieldState, fills: int) -> Audit:
        raise AuthorityError("F#CKING cannot grade its own performance")

    def allow(self, decision, state: FieldState) -> bool:
        if decision.side != "buy":
            return True
        agents = ensure_agents(state)
        if agents.get("entries_blocked"):
            return False
        record = agent_for_bot(state, decision.bot_id)
        if record is None or record.get("suspended"):
            return False
        return record.get("strategy") == state.bot(decision.bot_id).strategy


class Board:
    def __init__(self) -> None:
        self.d33p = D33PAgent()
        self.value = ValueAgent()
        self.fucking = FuckingAgent()

    def convene(self, state: FieldState, limits: Limits) -> dict:
        ensure_agents(state)
        deployment = self.d33p.train(state, limits)
        verdict = self.value.review(state, deployment, limits)
        operated = self.apply(state, deployment, verdict, limits)
        agents = ensure_agents(state)
        suspended = [record["id"] for record in agents["competition_agents"] if record["suspended"]]
        entry = {
            "d33p": deployment.to_json() if deployment else None,
            "value": verdict.to_json(),
            "fucking": {
                "author": FUCKING,
                "name": "F#CKING",
                "operated": operated,
                "entries_blocked": bool(agents["entries_blocked"]),
                "suspended_agents": suspended,
            },
        }
        log = list(agents.get("log") or [])
        log.append(entry)
        agents["log"] = log[-20:]
        state.agents = agents
        return agents

    def apply(self, state: FieldState, deployment: Deployment | None, verdict: Verdict, limits: Limits) -> bool:
        if verdict.author == D33P:
            raise AuthorityError("D33P cannot accept its own deployment")
        if verdict.author == FUCKING:
            raise AuthorityError("F#CKING cannot approve a deployment")
        if verdict.author != VALUE:
            raise AuthorityError("only VALUE can accept a deployment")
        agents = ensure_agents(state)
        operated = False
        if verdict.accepted:
            if deployment is None or deployment.author != D33P:
                raise AuthorityError("VALUE cannot accept a deployment D33P did not propose")
            if deployment.max_trade_micro > limits.max_trade_micro:
                raise AuthorityError("VALUE cannot increase spending limits")
            if not evidence_is_observed(deployment.evidence_prices, state.prices):
                raise AuthorityError("VALUE cannot approve a price the desk did not record")
            operated = self.fucking.operate(state, deployment, verdict, limits)
            if operated:
                self._install(state, deployment)
                agents["revision"] = deployment.revision
        self._mark_suspensions(state, limits)
        self._apply_cro(state, limits)
        state.agents = agents
        return operated

    def record_audit(self, state: FieldState, fills: int) -> Audit:
        audit = self.value.audit(state, fills)
        return self.submit_audit(state, audit)

    def submit_audit(self, state: FieldState, audit: Audit) -> Audit:
        if audit.author == FUCKING:
            raise AuthorityError("F#CKING cannot grade its own performance")
        if audit.author != VALUE:
            raise AuthorityError("only VALUE reports the round to the owner")
        agents = ensure_agents(state)
        payload = audit.to_json()
        log = list(agents.get("log") or [])
        if log:
            last = dict(log[-1])
            last["audit"] = payload
            log[-1] = last
        else:
            log.append({"audit": payload})
        agents["log"] = log[-20:]
        agents["last_audit"] = payload
        state.agents = agents
        return audit

    def _install(self, state: FieldState, deployment: Deployment) -> None:
        agents = ensure_agents(state)
        by_id = {record["id"]: record for record in agents["competition_agents"]}
        bots = {bot.bot_id: bot for bot in state.bots}
        for agent_id, strategy in deployment.assignments:
            record = by_id[agent_id]
            spec = STRATEGY_SPEC[strategy]
            record["strategy"] = strategy
            record["entry_ratio"] = spec["entry_ratio"]
            record["stop"] = spec["stop"]
            record["hold_seconds"] = spec["hold_seconds"]
            record["revision"] = deployment.revision
            bots[record["bot_id"]].strategy = strategy

    def _mark_suspensions(self, state: FieldState, limits: Limits) -> None:
        agents = ensure_agents(state)
        bots = {bot.bot_id: bot for bot in state.bots}
        for record in agents["competition_agents"]:
            bot = bots[record["bot_id"]]
            record["suspended"] = bot.today_pnl_micro <= -limits.max_daily_loss_micro

    def _apply_cro(self, state: FieldState, limits: Limits) -> None:
        agents = ensure_agents(state)
        pnl = book_today_pnl(state)
        veto = pnl <= -limits.max_daily_loss_micro
        agents["cro"] = {"id": "cro", "veto": veto, "book_today_pnl_micro": pnl}
        roster = agents["competition_agents"]
        agents["entries_blocked"] = (
            len(state.prices) < 2
            or all(record["suspended"] for record in roster)
            or veto
        )


def evidence_is_observed(cited: tuple[float, ...], observed: list[float]) -> bool:
    if len(cited) < 2:
        return False
    for price in cited:
        if not any(abs(price - item) <= 1e-9 for item in observed):
            return False
    return True
