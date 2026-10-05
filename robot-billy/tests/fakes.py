from robot_billy.jupiter import SOL_DECIMALS, SOL_MINT, USDC_DECIMALS, USDC_MINT, JupiterError


class FakeJupiter:
    def __init__(self, price: float = 100.0, fail_execute: bool = False):
        self.price = price
        self.fail_execute = fail_execute
        self.orders = []
        self.executions = []
        self.last = None

    def order(self, input_mint, output_mint, amount, taker=None):
        if input_mint == SOL_MINT and output_mint == USDC_MINT:
            out_amount = int(amount / 10**SOL_DECIMALS * self.price * 10**USDC_DECIMALS)
        elif input_mint == USDC_MINT and output_mint == SOL_MINT:
            out_amount = int(amount / 10**USDC_DECIMALS / self.price * 10**SOL_DECIMALS)
        else:
            out_amount = 1
        payload = {
            "inputMint": input_mint,
            "outputMint": output_mint,
            "inAmount": str(amount),
            "outAmount": str(out_amount),
            "priceImpact": 0.0001,
            "requestId": f"req-{len(self.orders) + 1}",
            "transaction": "dHhfYnl0ZXM" if taker else None,
        }
        self.orders.append(payload)
        self.last = payload
        return payload

    def execute(self, signed_transaction, request_id):
        self.executions.append((signed_transaction, request_id))
        if self.fail_execute:
            raise JupiterError("execute timed out")
        assert self.last is not None
        return {
            "status": "Success",
            "signature": "sig-" + request_id,
            "totalInputAmount": self.last["inAmount"],
            "totalOutputAmount": self.last["outAmount"],
        }


class FakeWallet:
    public_key = "WalletPubKey"

    def __init__(self):
        self.signed = []

    def sign_transaction(self, transaction_b64: str) -> str:
        self.signed.append(transaction_b64)
        return "signed-" + transaction_b64


class FakeRpc:
    def __init__(self, usdc_atoms: int):
        self.usdc_atoms = usdc_atoms

    def get_token_atoms(self, owner: str, mint: str) -> int:
        return self.usdc_atoms
