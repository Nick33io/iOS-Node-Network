import json
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from robot_billy.competition import Desk
from robot_billy.gate import Limits
from robot_billy.http_api import serve
from robot_billy.ledger import FieldState, open_field, usd


class HttpTests(unittest.TestCase):
    def test_status_page_and_paper_round(self):
        desk = Desk(FieldState(day="2026-10-05", bots=open_field(usd(6000))), Limits(usd(50), usd(100)))
        calls = []

        def paper_round():
            calls.append("paper")
            desk.state.prices.append(101.0)
            desk.save()
            return desk.snapshot()

        server = serve(desk, paper_round, port=0)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        port = server.server_address[1]
        try:
            page = urlopen(f"http://127.0.0.1:{port}/").read().decode()
            self.assertIn("roBot billy.", page)
            self.assertIn("Live swaps are not available", page)
            status = json.loads(urlopen(f"http://127.0.0.1:{port}/api/status").read())
            self.assertEqual(len(status["bots"]), 6)
            request = Request(f"http://127.0.0.1:{port}/api/paper-round", method="POST")
            body = json.loads(urlopen(request).read())
            self.assertEqual(body["last_price"], 101.0)
            self.assertEqual(calls, ["paper"])
            with self.assertRaises(HTTPError) as caught:
                urlopen(Request(f"http://127.0.0.1:{port}/api/live-round", method="POST"))
            self.assertEqual(caught.exception.code, 404)
        finally:
            server.shutdown()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
