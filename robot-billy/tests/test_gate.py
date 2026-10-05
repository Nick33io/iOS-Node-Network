import unittest

from robot_billy.gate import GateError, Limits, check_order
from robot_billy.jupiter import SOL_MINT, USDC_MINT
from robot_billy.ledger import Bot, usd


def bot() -> Bot:
    return Bot(bot_id="momentum-1", strategy="momentum", base_micro=usd(1000), cash_micro=usd(1000))


def limits() -> Limits:
    return Limits(max_trade_micro=usd(50), max_daily_loss_micro=usd(100))


def order(**overrides):
    payload = {
        "inputMint": USDC_MINT,
        "outputMint": SOL_MINT,
        "inAmount": str(usd(50)),
        "outAmount": "500000000",
        "priceImpact": 0.001,
        "transaction": "signed-later",
        "requestId": "req-1",
    }
    payload.update(overrides)
    return payload


class GateTests(unittest.TestCase):
    def test_entry_cap_and_allowlist(self):
        with self.assertRaises(GateError):
            check_order(order(inAmount=str(usd(80))), bot(), limits(), live=False, spend_micro=usd(80), entry=True)
        with self.assertRaises(GateError):
            check_order(order(outputMint="NotAMint"), bot(), limits(), live=False, spend_micro=usd(50), entry=True)

    def test_price_impact_blocks_entries_only(self):
        with self.assertRaises(GateError):
            check_order(order(priceImpact=0.2), bot(), limits(), live=False, spend_micro=usd(50), entry=True)
        check_order(order(inputMint=SOL_MINT, outputMint=USDC_MINT, priceImpact=0.2), bot(), limits(), live=False, spend_micro=0, entry=False)

    def test_live_requires_a_transaction(self):
        with self.assertRaises(GateError):
            check_order(order(transaction=""), bot(), limits(), live=True, spend_micro=usd(50), entry=True)

    def test_halt_blocks_a_new_entry(self):
        halted = bot()
        halted.today_pnl_micro = usd(-100)
        with self.assertRaises(GateError):
            check_order(order(), halted, limits(), live=False, spend_micro=usd(50), entry=True)


if __name__ == "__main__":
    unittest.main()
