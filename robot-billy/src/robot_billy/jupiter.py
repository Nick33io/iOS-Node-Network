"""Jupiter Swap V2 client.

The current swap flow is GET /swap/v2/order, sign, POST /swap/v2/execute.
https://developers.jup.ag/docs/swap/order-and-execute
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable

SOL_MINT = "So11111111111111111111111111111111111111112"
USDC_MINT = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
SOL_DECIMALS = 9
USDC_DECIMALS = 6

Transport = Callable[[str, str, dict[str, str], bytes | None], tuple[int, bytes]]


class JupiterError(RuntimeError):
    def __init__(self, message: str, status: int | None = None):
        super().__init__(message)
        self.status = status


def urllib_transport(timeout: float) -> Transport:
    def send(method: str, url: str, headers: dict[str, str], body: bytes | None) -> tuple[int, bytes]:
        request = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:300]
            raise JupiterError(f"Jupiter returned {exc.code}: {detail}", exc.code) from None
        except urllib.error.URLError as exc:
            raise JupiterError(f"Jupiter request failed: {exc.reason}") from None

    return send


@dataclass
class JupiterClient:
    base_url: str = "https://api.jup.ag/swap/v2"
    api_key: str | None = None
    timeout: float = 20.0
    transport: Transport | None = None

    def order(
        self,
        input_mint: str,
        output_mint: str,
        amount: int,
        taker: str | None = None,
    ) -> dict[str, Any]:
        if amount <= 0:
            raise JupiterError("order amount must be positive")
        params = {
            "inputMint": input_mint,
            "outputMint": output_mint,
            "amount": str(int(amount)),
        }
        if taker:
            params["taker"] = taker
        query = urllib.parse.urlencode(params)
        url = f"{self.base_url.rstrip('/')}/order?{query}"
        return self._send("GET", url, None)

    def execute(self, signed_transaction: str, request_id: str) -> dict[str, Any]:
        if not signed_transaction or not request_id:
            raise JupiterError("execute requires a signed transaction and requestId")
        url = f"{self.base_url.rstrip('/')}/execute"
        body = json.dumps(
            {"signedTransaction": signed_transaction, "requestId": request_id}
        ).encode()
        return self._send("POST", url, body)

    def _send(self, method: str, url: str, body: bytes | None) -> dict[str, Any]:
        headers = {"accept": "application/json"}
        if body is not None:
            headers["content-type"] = "application/json"
        if self.api_key:
            headers["x-api-key"] = self.api_key
        transport = self.transport or urllib_transport(self.timeout)
        status, raw = transport(method, url, headers, body)
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            raise JupiterError("Jupiter returned non-JSON", status) from None
        if status >= 400:
            raise JupiterError(f"Jupiter returned {status}", status)
        if not isinstance(parsed, dict):
            raise JupiterError("Jupiter returned an unexpected payload", status)
        return parsed


def sol_price_usdc(order: dict[str, Any]) -> float | None:
    """USDC per SOL from an order that sells SOL for USDC."""
    if order.get("inputMint") != SOL_MINT or order.get("outputMint") != USDC_MINT:
        return None
    try:
        sol = int(order["inAmount"]) / 10**SOL_DECIMALS
        usdc = int(order["outAmount"]) / 10**USDC_DECIMALS
    except (KeyError, TypeError, ValueError):
        return None
    if sol <= 0 or usdc <= 0:
        return None
    return usdc / sol
