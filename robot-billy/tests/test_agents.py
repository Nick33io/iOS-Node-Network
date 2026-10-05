import unittest

from robot_billy.agents import (
    FUCKING,
    VALUE,
    Audit,
    AuthorityError,
    Board,
    Deployment,
    FuckingAgent,
    ValueAgent,
    evidence_is_observed,
)
from robot_billy.competition import Decision, Desk, run_round
from robot_billy.gate import Limits
from robot_billy.jupiter import SOL_MINT, USDC_MINT
from robot_billy.ledger import FieldState, buy, open_field, usd
from fakes import FakeJupiter


def limits() -> Limits:
    return Limits(max_trade_micro=usd(50), max_daily_loss_micro=usd(100))


def state() -> FieldState:
    book = FieldState(day="2026-10-05", bots=open_field(usd(6000)))
    book.prices = [100.0, 100.3]
    return book


def deployment(**overrides) -> Deployment:
    payload = dict(
        author="d33p",
        revision=2,
        note="train",
        evidence_prices=(100.0, 100.3),
        max_trade_micro=usd(50),
        assignments=tuple((f"agent-{index}", "momentum") for index in range(1, 7)),
    )
    payload.update(overrides)
    return Deployment(**payload)


class AgentLayerTests(unittest.TestCase):
    def test_d33p_proposes_and_value_accepts_six_agents(self):
        book = state()
        cap = limits()
        agents = Board().convene(book, cap)
        roster = agents["competition_agents"]
        self.assertEqual(agents["team"], "DEEPF#CKINGVALUE")
        self.assertEqual([record["id"] for record in roster], [f"agent-{index}" for index in range(1, 7)])
        self.assertEqual(
            [record["strategy"] for record in roster],
            ["momentum", "momentum", "pullback", "pullback", "range", "range"],
        )
        self.assertEqual(agents["revision"], 1)
        self.assertEqual(agents["managers"]["d33p"]["name"], "D33P")
        self.assertEqual(agents["managers"]["value"]["name"], "VALUE")
        self.assertEqual(agents["managers"]["fucking"]["name"], "F#CKING")
        last = agents["log"][-1]
        self.assertTrue(last["value"]["accepted"])
        self.assertTrue(last["fucking"]["operated"])
        self.assertEqual(cap.max_trade_micro, usd(50))
        self.assertEqual(book.bot("pullback-2").strategy, "momentum")
        by_id = {item["id"]: item for item in agents["specialists"]}
        self.assertEqual(by_id["ares"]["status"], "untested")
        self.assertEqual(by_id["cronos"]["status"], "untested")
        self.assertEqual(by_id["cascade"]["status"], "untested")
        self.assertEqual(by_id["hermes"]["status"], "spot-only")
        self.assertEqual(by_id["cro"]["status"], "active")
        self.assertFalse(agents["leverage"]["armed"])

    def test_value_rejects_a_raise_and_neither_d33p_nor_fucking_can_accept(self):
        book = state()
        cap = limits()
        Board().convene(book, cap)
        raised = deployment(max_trade_micro=usd(500))
        from robot_billy.agents import Verdict

        verdict = ValueAgent().review(book, raised, cap)
        self.assertFalse(verdict.accepted)
        self.assertIn("spending limit", verdict.reason)
        with self.assertRaises(AuthorityError):
            Board().apply(book, raised, Verdict("d33p", 2, True, "self approval"), cap)
        with self.assertRaises(AuthorityError):
            Board().apply(book, raised, Verdict(FUCKING, 2, True, "operated anyway"), cap)
        with self.assertRaises(AuthorityError):
            Board().apply(book, raised, Verdict(VALUE, 2, True, "approved anyway"), cap)
        self.assertEqual(book.agents["revision"], 1)
        rejected = ValueAgent().review(book, raised, cap)
        self.assertFalse(FuckingAgent().operate(book, raised, rejected, cap))
        with self.assertRaises(AuthorityError):
            FuckingAgent().audit(book, 0)
        with self.assertRaises(AuthorityError):
            Board().submit_audit(
                book,
                Audit(FUCKING, 1, 0, 0, False, "self grade"),
            )

    def test_value_rejects_a_price_the_desk_did_not_record(self):
        book = state()
        Board().convene(book, limits())
        invented = deployment(evidence_prices=(100.0, 999.0))
        verdict = ValueAgent().review(book, invented, limits())
        self.assertFalse(verdict.accepted)
        self.assertFalse(evidence_is_observed((100.0, 999.0), book.prices))

    def test_fucking_blocks_a_suspended_agent_and_still_exits(self):
        book = state()
        book.bot("momentum-1").today_pnl_micro = usd(-100)
        agents = Board().convene(book, limits())
        suspended = [record["id"] for record in agents["competition_agents"] if record["suspended"]]
        self.assertEqual(suspended, ["agent-1"])
        self.assertTrue(agents["cro"]["veto"])
        fucking = Board().fucking
        buy_order = Decision("momentum-1", "buy", "test", USDC_MINT, SOL_MINT, usd(50), usd(50))
        self.assertFalse(fucking.allow(buy_order, book))
        buy(book.bot("momentum-1"), usd(50), SOL_MINT, 500_000_000, 100.0, 0)
        sell = Decision("momentum-1", "sell", "protective stop", SOL_MINT, USDC_MINT, 500_000_000, 0)
        self.assertTrue(fucking.allow(sell, book))

    def test_cro_vetoes_entries_when_the_book_hits_the_daily_loss(self):
        book = state()
        book.bot("momentum-1").today_pnl_micro = usd(-60)
        book.bot("pullback-2").today_pnl_micro = usd(-40)
        agents = Board().convene(book, limits())
        self.assertTrue(agents["cro"]["veto"])
        self.assertTrue(agents["entries_blocked"])
        self.assertFalse(any(record["suspended"] for record in agents["competition_agents"]))
        buy_order = Decision("range-3", "buy", "test", USDC_MINT, SOL_MINT, usd(50), usd(50))
        self.assertFalse(Board().fucking.allow(buy_order, book))

    def test_bots_execute_only_the_deployed_strategy_and_value_audits(self):
        book = FieldState(day="2026-10-05", bots=open_field(usd(6000)))
        desk = Desk(book, limits())
        jupiter = FakeJupiter(price=100)
        run_round(desk, jupiter, mode="paper", now=0, today="2026-10-05")
        jupiter.price = 100.3
        snapshot = run_round(desk, jupiter, mode="paper", now=1, today="2026-10-05")
        roster = snapshot["agents"]["competition_agents"]
        self.assertEqual(len(roster), 6)
        filled = [item["bot_id"] for item in snapshot["results"] if item["status"] == "filled"]
        self.assertEqual(sorted(filled), ["momentum-1", "pullback-2"])
        self.assertEqual(book.bot("range-3").strategy, "pullback")
        self.assertEqual(book.bot("range-3").cash_micro, usd(1000))
        versions = {trade.bot_id: trade.strategy_version for trade in book.trades}
        self.assertEqual(versions["momentum-1"], "momentum@1")
        self.assertEqual(versions["pullback-2"], "momentum@1")
        last = snapshot["agents"]["log"][-1]
        self.assertEqual(last["d33p"]["author"], "d33p")
        self.assertTrue(last["value"]["accepted"])
        self.assertTrue(last["fucking"]["operated"])
        self.assertEqual(last["audit"]["author"], "value")
        self.assertEqual(last["audit"]["fills"], 2)


if __name__ == "__main__":
    unittest.main()
