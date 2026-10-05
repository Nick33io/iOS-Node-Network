"""Local status page. It can run a paper round. It cannot submit a live swap."""

from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable
from urllib.parse import urlparse

from robot_billy.competition import Desk


def make_handler(desk: Desk, paper_round: Callable[[], dict]) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            path = urlparse(self.path).path
            if path == "/api/status":
                self._json(200, desk.snapshot())
                return
            if path in {"/", "/index.html"}:
                body = _page(desk.snapshot()).encode()
                self.send_response(200)
                self.send_header("content-type", "text/html; charset=utf-8")
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            self._json(404, {"error": "not found"})

        def do_POST(self) -> None:
            path = urlparse(self.path).path
            if path != "/api/paper-round":
                self._json(404, {"error": "not found"})
                return
            try:
                snapshot = paper_round()
            except Exception as exc:
                desk.state.last_error = str(exc)
                desk.save()
                self._json(400, {"error": str(exc)})
                return
            self._json(200, snapshot)

        def log_message(self, fmt: str, *args) -> None:
            return

        def _json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    return Handler


def serve(desk: Desk, paper_round: Callable[[], dict], host: str = "127.0.0.1", port: int = 8787) -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), make_handler(desk, paper_round))
    return server


def _page(snapshot: dict) -> str:
    rows = []
    for bot in snapshot.get("bots", []):
        rows.append(
            "<tr>"
            f"<td>{_esc(bot.get('agent_id') or '')}</td>"
            f"<td>{_esc(bot['bot_id'])}</td>"
            f"<td>{_esc(bot['strategy'])}</td>"
            f"<td>{bot['cash_usdc']:.2f}</td>"
            f"<td>{bot['today_pnl_usdc']:.2f}</td>"
            f"<td>{bot['lifetime_pnl_usdc']:.2f}</td>"
            f"<td>{bot['equity_usdc']:.2f}</td>"
            f"<td>{bot['position_atoms']}</td>"
            f"<td>{'halted' if bot['halted'] else 'open'}</td>"
            "</tr>"
        )
    price = snapshot.get("last_price")
    price_text = f"{price:.4f}" if isinstance(price, (int, float)) else "—"
    error = _esc(snapshot.get("last_error") or "")
    agents = snapshot.get("agents") or {}
    suspended_ids = [
        record["id"]
        for record in agents.get("competition_agents") or []
        if record.get("suspended")
    ]
    suspended = ", ".join(suspended_ids) or "none"
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>roBot billy</title>
<style>
body {{ font-family: Helvetica, Arial, sans-serif; background:#4E8B8B; color:#2C3131; margin:0; }}
main {{ max-width:960px; margin:32px auto; background:#F3F5F5; padding:24px; }}
h1 {{ letter-spacing:-0.04em; margin:0 0 8px; }}
table {{ width:100%; border-collapse:collapse; font-variant-numeric:tabular-nums; }}
th, td {{ text-align:left; border-bottom:1px solid rgba(44,49,49,.22); padding:8px; }}
button {{ background:#2C3131; color:#F3F5F5; border:0; padding:8px 12px; cursor:pointer; }}
</style>
</head>
<body>
<main>
<h1>roBot billy.</h1>
<p>Paper competition. Live swaps are not available from this page.</p>
<p>SOL/USDC {price_text}. Day {_esc(snapshot.get("day"))}. {error}</p>
<p>D33P trains and deploys. Assist revision {_esc(agents.get("revision", 0))}. Operations entries {"blocked" if agents.get("entries_blocked") else "open"}. Suspended {_esc(suspended)}.</p>
<table>
<thead><tr><th>Agent</th><th>Bot</th><th>Strategy</th><th>Cash</th><th>Today</th><th>Lifetime</th><th>Equity</th><th>SOL atoms</th><th>Status</th></tr></thead>
<tbody>{''.join(rows)}</tbody>
</table>
<p><button id="round" type="button">Run paper round</button></p>
</main>
<script>
document.getElementById("round").onclick = async () => {{
  const response = await fetch("/api/paper-round", {{method:"POST"}});
  if (!response.ok) {{
    const body = await response.json();
    alert(body.error || "paper round failed");
    return;
  }}
  location.reload();
}};
</script>
</body>
</html>
"""


def _esc(value: object) -> str:
    text = "" if value is None else str(value)
    return (
        text.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
