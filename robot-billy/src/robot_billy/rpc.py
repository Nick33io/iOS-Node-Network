"""Minimal Solana JSON-RPC reads for SOL and SPL token balances."""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

from robot_billy.jupiter import USDC_MINT

Transport = Callable[[str, dict[str, str], bytes], tuple[int, bytes]]


class RpcError(RuntimeError):
    pass


def urllib_transport(timeout: float) -> Transport:
    def send(url: str, headers: dict[str, str], body: bytes) -> tuple[int, bytes]:
        request = urllib.request.Request(url, data=body, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            raise RpcError(f"Solana RPC returned {exc.code}") from None
        except urllib.error.URLError as exc:
            raise RpcError(f"Solana RPC request failed: {exc.reason}") from None

    return send


@dataclass
class SolanaRpc:
    url: str = "https://api.mainnet-beta.solana.com"
    timeout: float = 20.0
    transport: Transport | None = None

    def get_balance_lamports(self, pubkey: str) -> int:
        result = self._call("getBalance", [pubkey, {"commitment": "confirmed"}])
        try:
            return int(result["value"])
        except (KeyError, TypeError, ValueError):
            raise RpcError("getBalance returned an unexpected payload") from None

    def get_token_atoms(self, owner: str, mint: str = USDC_MINT) -> int:
        result = self._call(
            "getTokenAccountsByOwner",
            [owner, {"mint": mint}, {"encoding": "jsonParsed", "commitment": "confirmed"}],
        )
        total = 0
        try:
            accounts = result["value"]
        except (KeyError, TypeError):
            raise RpcError("getTokenAccountsByOwner returned an unexpected payload") from None
        for account in accounts:
            try:
                amount = account["account"]["data"]["parsed"]["info"]["tokenAmount"]["amount"]
                total += int(amount)
            except (KeyError, TypeError, ValueError):
                raise RpcError("token balance payload was missing an amount") from None
        return total

    def _call(self, method: str, params: list[Any]) -> Any:
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        transport = self.transport or urllib_transport(self.timeout)
        status, raw = transport(self.url, {"content-type": "application/json"}, body)
        if status >= 400:
            raise RpcError(f"Solana RPC returned {status}")
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            raise RpcError("Solana RPC returned non-JSON") from None
        if parsed.get("error"):
            message = parsed["error"].get("message", "RPC error") if isinstance(parsed["error"], dict) else "RPC error"
            raise RpcError(message)
        if "result" not in parsed:
            raise RpcError("Solana RPC response was missing a result")
        return parsed["result"]
