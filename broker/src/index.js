/**
 * Entry point. Fails closed: configuration errors are printed and the
 * process exits non-zero before a socket is ever opened.
 */

import { loadConfig } from "./config.js";
import { createBroker } from "./server.js";

let config;
try {
  config = loadConfig(process.env);
} catch (err) {
  console.error(err.message);
  process.exit(1);
}

const server = createBroker(config);
server.listen(config.port, () => {
  console.log(`broker listening on :${config.port}`);
});
