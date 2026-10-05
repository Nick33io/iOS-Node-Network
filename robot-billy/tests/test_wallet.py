import base64
import json
import tempfile
import unittest
from pathlib import Path

from solders.hash import Hash
from solders.keypair import Keypair
from solders.message import MessageV0
from solders.signature import Signature
from solders.system_program import TransferParams, transfer
from solders.transaction import VersionedTransaction

from robot_billy.wallet import Wallet, WalletError, keypair_from_file, load_wallet


class WalletTests(unittest.TestCase):
    def test_signs_only_its_required_slot(self):
        keypair = Keypair()
        instruction = transfer(TransferParams(from_pubkey=keypair.pubkey(), to_pubkey=keypair.pubkey(), lamports=1))
        message = MessageV0.try_compile(keypair.pubkey(), [instruction], [], Hash.default())
        unsigned = VersionedTransaction.populate(message, [Signature.default()])
        encoded = base64.b64encode(bytes(unsigned)).decode()
        signed = Wallet(keypair).sign_transaction(encoded)
        transaction = VersionedTransaction.from_bytes(base64.b64decode(signed))
        self.assertNotEqual(transaction.signatures[0], Signature.default())

    def test_keyfile_round_trip_does_not_need_the_secret_in_the_error(self):
        keypair = Keypair()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "id.json"
            path.write_text(json.dumps(list(bytes(keypair))))
            loaded = keypair_from_file(path)
            self.assertEqual(loaded.pubkey(), keypair.pubkey())
            path.write_text('{"not": "a key"}')
            with self.assertRaises(WalletError) as caught:
                keypair_from_file(path)
        self.assertNotIn("not", str(caught.exception))

    def test_missing_key_is_not_a_wallet(self):
        self.assertIsNone(load_wallet({}))
        with self.assertRaises(WalletError):
            load_wallet({"WALLET_KEYPAIR_PATH": "/tmp/a", "BS58_PRIVATE_KEY": "b"})


if __name__ == "__main__":
    unittest.main()
