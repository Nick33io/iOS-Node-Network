import unittest

from robot_billy.jupiter import SOL_MINT
from robot_billy.ledger import Bot, buy, open_field, roll_day, sell, usd


class CapitalTests(unittest.TestCase):
    def test_worked_example(self):
        bot = Bot(bot_id="momentum-1", strategy="momentum", base_micro=usd(1000), cash_micro=usd(1000))
        buy(bot, usd(400), SOL_MINT, 1_000_000_000, 100.0, 0)
        sell(bot, 1_000_000_000, usd(900))
        self.assertEqual(bot.today_pnl_micro, usd(500))
        self.assertEqual(bot.cash_micro, usd(1125))
        self.assertEqual(bot.reserved_micro, 0)
        roll_day(bot)
        self.assertEqual(bot.base_micro, usd(1025))
        self.assertEqual(bot.cash_micro, usd(1025))
        self.assertEqual(bot.today_pnl_micro, 0)

    def test_loss_reduces_the_next_allowance(self):
        bot = Bot(bot_id="range-3", strategy="range", base_micro=usd(1000), cash_micro=usd(1000))
        buy(bot, usd(400), SOL_MINT, 1_000_000_000, 100.0, 0)
        sell(bot, 1_000_000_000, usd(300))
        self.assertEqual(bot.cash_micro, usd(900))
        roll_day(bot)
        self.assertEqual(bot.base_micro, usd(900))
        self.assertEqual(bot.cash_micro, usd(900))

    def test_bots_cannot_spend_each_others_cash(self):
        bots = open_field(usd(6000))
        buy(bots[0], usd(50), SOL_MINT, 100, 100.0, 0)
        self.assertEqual(bots[1].cash_micro, usd(1000))
        self.assertEqual(bots[0].cash_micro, usd(950))

    def test_open_position_stays_reserved_across_the_roll(self):
        bot = Bot(bot_id="pullback-2", strategy="pullback", base_micro=usd(1000), cash_micro=usd(1000))
        buy(bot, usd(200), SOL_MINT, 100, 100.0, 0)
        roll_day(bot)
        self.assertEqual(bot.reserved_micro, usd(200))
        self.assertEqual(bot.cash_micro, usd(800))


if __name__ == "__main__":
    unittest.main()
