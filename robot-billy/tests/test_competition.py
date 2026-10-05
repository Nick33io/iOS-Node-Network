import os
import unittest

from robot_billy.competition import LIVE_CONFIRM, Desk, LiveDisabled, run_round
from robot_billy.gate import Limits
from robot_billy.jupiter import SOL_MINT
from robot_billy.ledger import FieldState, buy, open_field, usd
from fakes import FakeJupiter, FakeRpc, FakeWallet

LIVE_ENV = {
    "ROBOT_BILLY_LIVE": "1",
    "ROBOT_BILLY_LIVE_CONFIRM": LIVE_CONFIRM,
}


def limits():
    return Limits(max_trade_micro=usd(50), max_daily_loss_micro=usd(100))


def desk():
    return Desk(FieldState(day="2026-10-05", bots=open_field(usd(6000))), limits())


class CompetitionTests(unittest.TestCase):
    def setUp(self):
        self._saved = {key: os.environ.get(key) for key in LIVE_ENV}
        for key in LIVE_ENV:
            os.environ.pop(key, None)

    def tearDown(self):
        for key, value in self._saved.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    def test_paper_round_books_a_jupiter_quote_and_does_not_sign(self):
        book = desk()
        jupiter = FakeJupiter(price=100)
        wallet = FakeWallet()
        run_round(book, jupiter, mode="paper", wallet=wallet, now=0, today="2026-10-05")
        jupiter.price = 100.3
        snapshot = run_round(book, jupiter, mode="paper", wallet=wallet, now=1, today="2026-10-05")
        self.assertEqual(wallet.signed, [])
        self.assertEqual(jupiter.executions, [])
        filled = [item for item in snapshot["results"] if item["status"] == "filled"]
        self.assertEqual(sorted(item["bot_id"] for item in filled), ["momentum-1", "momentum-4"])
        self.assertEqual(book.state.bot("momentum-1").cash_micro, usd(950))
        self.assertEqual(book.state.bot("pullback-2").cash_micro, usd(1000))

    def test_live_is_refused_without_the_confirmation(self):
        jupiter = FakeJupiter()
        with self.assertRaises(LiveDisabled):
            run_round(desk(), jupiter, mode="live", wallet=FakeWallet(), rpc=FakeRpc(usd(6000)), now=0, today="2026-10-05")
        self.assertEqual(jupiter.orders, [])

    def test_live_round_signs_and_submits(self):
        os.environ.update(LIVE_ENV)
        book = desk()
        jupiter = FakeJupiter(price=100)
        wallet = FakeWallet()
        rpc = FakeRpc(usd(6000))
        run_round(book, jupiter, mode="paper", now=0, today="2026-10-05")
        jupiter.price = 100.3
        snapshot = run_round(book, jupiter, mode="live", wallet=wallet, rpc=rpc, now=1, today="2026-10-05")
        filled = [item for item in snapshot["results"] if item["status"] == "filled"]
        self.assertEqual(len(filled), 2)
        self.assertEqual(len(wallet.signed), 2)
        self.assertEqual(len(jupiter.executions), 2)
        self.assertFalse(filled[0]["paper"])
        self.assertIsNone(book.state.pending)

    def test_a_lost_execute_response_blocks_the_next_live_send(self):
        os.environ.update(LIVE_ENV)
        book = desk()
        book.state.prices.append(100)
        jupiter = FakeJupiter(price=100.3, fail_execute=True)
        run_round(book, jupiter, mode="live", wallet=FakeWallet(), rpc=FakeRpc(usd(6000)), now=1, today="2026-10-05")
        self.assertIsNotNone(book.state.pending)
        self.assertIn("timed out", book.state.last_error or "")
        with self.assertRaises(LiveDisabled):
            run_round(book, FakeJupiter(price=100.3), mode="live", wallet=FakeWallet(), rpc=FakeRpc(usd(6000)), now=2, today="2026-10-05")

    def test_protective_stop_sells_the_position(self):
        book = desk()
        bot = book.state.bot("momentum-1")
        buy(bot, usd(50), SOL_MINT, 500_000_000, 100.0, 0)
        book.state.prices.append(100)
        jupiter = FakeJupiter(price=95)
        snapshot = run_round(book, jupiter, mode="paper", now=10, today="2026-10-05")
        self.assertIsNone(bot.position)
        self.assertEqual(snapshot["results"][0]["side"], "sell")
        self.assertEqual(book.state.trades[0].reason, "protective stop")


if __name__ == "__main__":
    unittest.main()
