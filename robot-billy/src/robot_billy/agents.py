"""Three managers, six competition agents, and the bots that trade for them.

D33P trains a strategy and deploys it onto the six competition agents. Assist
checks that deployment against recorded prices and the spending cap. Operations
runs the round and will not open a trade for an agent Assist suspended.
Each competition agent's bot decides the buy and the sell from the strategy
that was deployed to that agent.
"""

from __future__ import annotations

from dataclasses import dataclass

from robot_billy.gate import Limits
from robot_billy.ledger import Bot, FieldState

D33P = "d33p"
OPERATIONS = "operations"
ASSIST = "assist"
KNOWN_STRATEGIES = ("momentum", "pullback", "range")

STRATEGY_SPEC = {
    "momentum": {"entry_ratio": 1.002, "stop": 0.04, "hold_seconds": 60 * 60},
    "pullback": {"entry_ratio": 0.995, "stop": 0.04, "hold_seconds": 90 * 60},
    "range": {"entry_ratio": 0.99, "stop": 0.03, "hold_seconds": 45 * 60},
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


def blank_agents(state: FieldState | None = None) -> dict:
    roster = []
    if state is not None:
        roster = opening_roster(state)
    return {
        "managers": {
            "research": {"id": D33P, "role": "research"},
            "operations": {"id": OPERATIONS, "role": "operations"},
            "assist": {"id": ASSIST, "role": "assist"},
        },
        "revision": 0,
        "competition_agents": roster,
        "entries_blocked": False,
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
    state.agents.setdefault("managers", blank_agents()["managers"])
    return state.agents


def agent_for_bot(state: FieldState, bot_id: str) -> dict | None:
    agents = state.agents or {}
    for record in agents.get("competition_agents") or []:
        if record.get("bot_id") == bot_id:
            return record
    return None


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


class D33PAgent:
    """Research. Trains a ranking and deploys it onto the six competition agents."""

    name = D33P

    def train(self, state: FieldState, limits: Limits) -> Deployment | None:
        prices = state.prices
        if len(prices) < 2 or prices[-2] <= 0:
            return None
        agents = ensure_agents(state)
        ratio = prices[-1] / prices[-2]
        if ratio >= 1.002:
            ranked = ("momentum", "pullback", "range")
            note = "trained an uptrend book; momentum deploys to the first pair"
        elif ratio <= 0.99:
            ranked = ("range", "pullback", "momentum")
            note = "trained a discount book; range deploys to the first pair"
        elif ratio < 0.995:
            ranked = ("pullback", "momentum", "range")
            note = "trained a pullback book; pullback deploys to the first pair"
        else:
            ranked = ("momentum", "pullback", "range")
            note = "no separation from the last print; redeploy the opening book"
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


class AssistAgent:
    """Assist. Checks a deployment before Operations acts on it."""

    name = ASSIST

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


class OperationsAgent:
    """Operations. Runs the competition inside the deployment Assist left standing."""

    name = OPERATIONS

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
        self.assist = AssistAgent()
        self.operations = OperationsAgent()

    def convene(self, state: FieldState, limits: Limits) -> dict:
        ensure_agents(state)
        deployment = self.d33p.train(state, limits)
        verdict = self.assist.review(state, deployment, limits)
        self.apply(state, deployment, verdict, limits)
        agents = ensure_agents(state)
        suspended = [record["id"] for record in agents["competition_agents"] if record["suspended"]]
        entry = {
            "research": deployment.to_json() if deployment else None,
            "assist": verdict.to_json(),
            "operations": {
                "entries_blocked": bool(agents["entries_blocked"]),
                "suspended_agents": suspended,
            },
        }
        log = list(agents.get("log") or [])
        log.append(entry)
        agents["log"] = log[-20:]
        state.agents = agents
        return agents

    def apply(self, state: FieldState, deployment: Deployment | None, verdict: Verdict, limits: Limits) -> None:
        if verdict.author != ASSIST:
            raise AuthorityError("only Assist can accept a deployment")
        agents = ensure_agents(state)
        if verdict.accepted:
            if deployment is None or deployment.author != D33P:
                raise AuthorityError("Assist cannot accept a deployment D33P did not train")
            if deployment.max_trade_micro > limits.max_trade_micro:
                raise AuthorityError("Assist cannot increase spending limits")
            if not evidence_is_observed(deployment.evidence_prices, state.prices):
                raise AuthorityError("Assist cannot approve a price the desk did not record")
            self._install(state, deployment)
            agents["revision"] = deployment.revision
        self._mark_suspensions(state, limits)
        roster = agents["competition_agents"]
        agents["entries_blocked"] = len(state.prices) < 2 or all(record["suspended"] for record in roster)
        state.agents = agents

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


def evidence_is_observed(cited: tuple[float, ...], observed: list[float]) -> bool:
    if len(cited) < 2:
        return False
    for price in cited:
        if not any(abs(price - item) <= 1e-9 for item in observed):
            return False
    return True
