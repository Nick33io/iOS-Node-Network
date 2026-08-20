/**
 * In-memory sliding-window rate limiter, keyed by device id. Suitable for a
 * single-process broker; a multi-instance deployment would move this to a
 * shared store, but the interface stays the same.
 */
export class SlidingWindowLimiter {
  /**
   * @param {object} opts
   * @param {number} opts.max     requests allowed per window
   * @param {number} opts.windowMs window length in milliseconds
   */
  constructor({ max, windowMs }) {
    this.max = max;
    this.windowMs = windowMs;
    /** @type {Map<string, number[]>} key -> timestamps of counted requests */
    this.hits = new Map();
  }

  /**
   * Record an attempt and report whether it is allowed. Refused attempts are
   * not counted, so a device cannot lock itself out further by retrying.
   *
   * @param {string} key
   * @param {number} [now]
   * @returns {boolean} true if the request is within the limit
   */
  allow(key, now = Date.now()) {
    const cutoff = now - this.windowMs;
    const recent = (this.hits.get(key) || []).filter((t) => t > cutoff);
    if (recent.length >= this.max) {
      // Write back the pruned list so memory does not grow with refusals.
      this.hits.set(key, recent);
      return false;
    }
    recent.push(now);
    this.hits.set(key, recent);
    return true;
  }

  /** Drop keys with no recent activity. Called opportunistically. */
  prune(now = Date.now()) {
    const cutoff = now - this.windowMs;
    for (const [key, times] of this.hits) {
      if (times.length === 0 || times[times.length - 1] <= cutoff) {
        this.hits.delete(key);
      }
    }
  }
}
