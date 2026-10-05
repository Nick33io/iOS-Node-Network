import json
import unittest

from robot_billy.jupiter import SOL_MINT, USDC_MINT, JupiterClient, JupiterError


class JupiterClientTests(unittest.TestCase):
    def test_order_and_execute_use_swap_v2_paths(self):
        seen = []

        def transport(method, url, headers, body):
            seen.append((method, url, headers, body))
            if method == "GET":
                payload = {"inAmount": "100", "outAmount": "200", "inputMint": SOL_MINT, "outputMint": USDC_MINT}
            else:
                payload = {"status": "Success", "signature": "sig"}
            return 200, json.dumps(payload).encode()

        client = JupiterClient(api_key="test-key", transport=transport)
        client.order(SOL_MINT, USDC_MINT, 100, taker="PUB")
        client.execute("c2lnbmVk", "req-1")
        self.assertIn("/swap/v2/order?", seen[0][1])
        self.assertIn("taker=PUB", seen[0][1])
        self.assertEqual(seen[0][2]["x-api-key"], "test-key")
        self.assertEqual(seen[1][0], "POST")
        self.assertTrue(seen[1][1].endswith("/swap/v2/execute"))
        self.assertEqual(json.loads(seen[1][3]), {"signedTransaction": "c2lnbmVk", "requestId": "req-1"})

    def test_http_error_does_not_include_a_response_body_secret_placeholder(self):
        def transport(method, url, headers, body):
            raise JupiterError("Jupiter returned 401: unauthorized", 401)

        client = JupiterClient(transport=transport)
        with self.assertRaises(JupiterError) as caught:
            client.order(SOL_MINT, USDC_MINT, 1)
        self.assertEqual(caught.exception.status, 401)


if __name__ == "__main__":
    unittest.main()
