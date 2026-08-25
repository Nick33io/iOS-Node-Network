"""Launcher for `mlx_lm.server` with a listen backlog that survives a real fleet.

Python's HTTPServer inherits `request_queue_size = 5`. The Macs batch decode —
one weight read feeds the whole batch — so their throughput only appears when
many requests are in flight at once. At the concurrency that actually pays
(32), the default backlog refused connections: the sixth request onward got
ECONNRESET, which read as a compute ceiling and hid a 2x.

Everything else is stock mlx_lm. Run it exactly as `python -m mlx_lm server`:

    ~/mlxenv/bin/python ops/mlx-serve.py \
        --model mlx-community/Qwen3-4B-Instruct-2507-4bit \
        --port 8081 --decode-concurrency 32 --prompt-concurrency 8

`--decode-concurrency` exists only in mlx-lm >= 0.30. On 0.29.x the server
still batches (at a fixed 32) but rejects the flag, so omit it there.
"""

import sys
import http.server
import socketserver

socketserver.TCPServer.request_queue_size = 256
http.server.HTTPServer.request_queue_size = 256

from mlx_lm.server import main  # noqa: E402  (import after the patch, by design)

sys.exit(main())
