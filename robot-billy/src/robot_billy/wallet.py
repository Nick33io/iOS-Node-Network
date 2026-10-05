"""Load a Solana keypair and sign a Jupiter versioned transaction.

The secret is read from a Solana CLI keyfile or from BS58_PRIVATE_KEY.
It is never written to status output or logs.
"""

from __future__ import annotations

import base64
import json
import os
from dataclasses import dataclass
from pathlib import Path

from solders.keypair import Keypair
from solders.message import to_bytes_versioned
from solders.transaction import VersionedTransaction


class WalletError(RuntimeError):
    pass


@dataclass
class Wallet:
    keypair: Keypair

    @property
    def public_key(self) -> str:
        return str(self.keypair.pubkey())

    def sign_transaction(self, transaction_b64: str) -> str:
        if not transaction_b64:
            raise WalletError("Jupiter did not return a transaction to sign")
        try:
            raw = base64.b64decode(transaction_b64)
            transaction = VersionedTransaction.from_bytes(raw)
        except Exception as exc:
            raise WalletError("Jupiter transaction could not be decoded") from exc
        message = transaction.message
        required = int(message.header.num_required_signatures)
        keys = list(message.account_keys)[:required]
        pubkey = self.keypair.pubkey()
        try:
            index = keys.index(pubkey)
        except ValueError:
            raise WalletError("wallet is not a required signer on this transaction") from None
        signature = self.keypair.sign_message(to_bytes_versioned(message))
        signatures = list(transaction.signatures)
        signatures[index] = signature
        signed = VersionedTransaction.populate(message, signatures)
        return base64.b64encode(bytes(signed)).decode()


def load_wallet(env: dict[str, str] | None = None) -> Wallet | None:
    """Return the configured wallet, or None when no key is configured."""
    values = os.environ if env is None else env
    path = values.get("WALLET_KEYPAIR_PATH", "").strip()
    secret = values.get("BS58_PRIVATE_KEY", "").strip()
    if path and secret:
        raise WalletError("set WALLET_KEYPAIR_PATH or BS58_PRIVATE_KEY, not both")
    if path:
        return Wallet(keypair_from_file(Path(path)))
    if secret:
        return Wallet(keypair_from_base58(secret))
    return None


def keypair_from_file(path: Path) -> Keypair:
    try:
        raw = json.loads(path.read_text())
        if not isinstance(raw, list) or not all(isinstance(item, int) for item in raw):
            raise WalletError("wallet keyfile must be a JSON array of bytes")
        return Keypair.from_bytes(bytes(raw))
    except WalletError:
        raise
    except Exception:
        raise WalletError("wallet keyfile could not be read") from None


def keypair_from_base58(secret: str) -> Keypair:
    try:
        return Keypair.from_base58_string(secret)
    except Exception:
        raise WalletError("BS58_PRIVATE_KEY could not be read") from None
