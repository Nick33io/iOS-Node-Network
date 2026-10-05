import unittest

from robot_billy.agents import (
    AuthorityError,
    Board,
    Proposal,
    ValueAgent,
    Verdict,
    evidence_is_observed,
)
from robot_billy.competition import Decision, run_round
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


def buy_decision(bot_id: str = "momentum-1") -> Decision:
    return Decision(bot_id, "buy", "test", USDC_MINT, SOL_MINT, usd(50), usd(50))


class AgentTests(unittest.TestCase):
    def test_uptrend_proposal_is_accepted_and_limits_stay_put(self):
        book = state()
        cap = limits()
        agents = Board().convene(book, cap)
        self.assertEqual(agents["enabled"], ["momentum"])
        self.assertEqual(agents["revision"], 1)
        self.assertEqual(agents["log"][-1]["d33p"]["author"], "d33p")
        self.assertTrue(agents["log"][-1]["value"]["accepted"])
        self.assertEqual(cap.max_trade_micro, usd(50))

    def test_d33p_cannot_approve_and_value_cannot_raise_the_cap(self):
        book = state()
        cap = limits()
        proposal = Proposal("d33p", 2, ("momentum",), "raise", (100.0, 100.3), usd(500))
        verdict = ValueAgent().review(book, proposal, cap)
        self.assertFalse(verdict.accepted)
        self.assertIn("spending limit", verdict.reason)
        forged = Verdict("d33p", 2, True, "self approval")
        with self.assertRaises(AuthorityError):
            Board().apply(book, proposal, forged, cap)
        forged_value = Verdict("value", 2, True, "approved anyway")
        with self.assertRaises(AuthorityError):
            Board().apply(book, proposal, forged_value, cap)
        self.assertIsNone(book.agents["revision"] if book.agents and book.agents.get("revision") == 2 else None)

    def test_value_rejects_a_price_the_desk_did_not_record(self):
        book = state()
        proposal = Proposal("d33p", 2, ("range",), "invented", (100.0, 999.0), usd(50))
        verdict = ValueAgent().review(book, proposal, limits())
        self.assertFalse(verdict.accepted)
        self.assertFalse(evidence_is_observed((100.0, 999.0), book.prices))

    def test_fleet_blocks_entries_for_a_losing_strategy_and_still_exits(self):
        book = state()
        for bot in book.bots:
            if bot.strategy == "momentum":
                bot.today_pnl_micro = usd(-60)
        agents = Board().convene(book, limits())
        self.assertIn("momentum", agents["suspended"])
        fleet = Board().fleet
        self.assertFalse(fleet.allow(buy_decision(), book))
        bot = book.bot("momentum-1")
        buy(bot, usd(50), SOL_MINT, 500_000_000, 100.0, 0)
        sell = Decision("momentum-1", "sell", "protective stop", SOL_MINT, USDC_MINT, 500_000_000, 0)
        self.assertTrue(fleet.allow(sell, book))

    def test_a_round_records_the_seats_and_still_papers_momentum(self):
        book = FieldState(day="2026-10-05", bots=open_field(usd(6000)))
        from robot_billy.competition import Desk

        desk = Desk(book, limits())
        jupiter = FakeJupiter(price=100)
        run_round(desk, jupiter, mode="paper", now=0, today="2026-10-05")
        jupiter.price = 100.3
        snapshot = run_round(desk, jupiter, mode="paper", now=1, today="2026-10-05")
        self.assertEqual(snapshot["agents"]["enabled"], ["momentum"])
        filled = [item["bot_id"] for item in snapshot["results"] if item["status"] == "filled"]
        self.assertEqual(sorted(filled), ["momentum-1", "momentum-4"])


if __name__ == "__main__":
    unittest.main()
