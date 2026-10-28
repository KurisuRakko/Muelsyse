/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/**
 * Which endpoint the WebSocket core opens its session socket on.
 *
 * A page loaded through one front door (a tunnel with a login in front, say)
 * may reach the same server through others the operator lists in the
 * `direct_ws_urls` setting, which the server hands out at
 * `api/direct-endpoints`. Only the session socket moves: the page, uploads
 * and every other request keep the page's origin, so whatever gates that
 * origin keeps gating them. An empty list leaves the socket on the origin
 * without timing anything.
 *
 * The route preference is one of `WS_ROUTE_PREFS`. `auto` times every
 * candidate, the origin included, in parallel: `PING_SAMPLES` sequential
 * `api/ping` fetches each, the first dropped because it pays the connection
 * and TLS setup the open socket will not, the median of the rest kept. A
 * candidate that errors or overruns `PING_TIMEOUT_MS` is out, the whole race
 * is cut at `PROBE_BUDGET_MS`, and the lowest median wins; nothing is
 * preferred in advance, since which door is faster depends on where the
 * client sits. `direct` takes the first listed endpoint untimed and `origin`
 * never leaves. With nothing measured the socket stays on the origin, the
 * path a page without the setting takes.
 * @module
 */

/** The route preferences a user can pick, the default first. */
export const WS_ROUTE_PREFS = ['auto', 'direct', 'origin'];
/** Pings per candidate; the first is dropped as the connection setup. */
export const PING_SAMPLES = 4;
/** Per-candidate ceiling on all of its pings together. */
export const PING_TIMEOUT_MS = 1500;
/** Ceiling on the whole race, after which a candidate still timing is out. */
export const PROBE_BUDGET_MS = 2000;
/** Ceiling on the endpoint list request, which every socket waits for. */
export const LIST_TIMEOUT_MS = 3000;

/**
 * @typedef {Object} WsRouteCandidate
 * @property {'origin'|'direct'} route Whether this is the page's own origin.
 * @property {string} base Base URL, ending in `/`, that `api/...` joins.
 * @property {?number} rttMs Measured median round trip, `null` when not
 *     timed or failed.
 */

/**
 * @typedef {Object} WsRouteChoice
 * @property {'origin'|'direct'} route Where the socket opens.
 * @property {string} base The chosen candidate's base URL.
 * @property {?number} rttMs The chosen candidate's round trip, if timed.
 * @property {WsRouteCandidate[]} candidates Every candidate, timed or not.
 * @property {boolean} fallback Whether a direct route the preference asked
 *     for was skipped because it already failed in this tab.
 */

/**
 * Median of a list of numbers.
 * @param {number[]} values
 * @returns {?number} `null` for an empty list.
 */
export function median(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

/**
 * Times one candidate with sequential `api/ping` fetches.
 *
 * Credentials follow the fetch default, sent to the page's own origin (whose
 * login may front the probe) and never to a direct endpoint. A redirect is an
 * error rather than a sample: a front door that answers with its login page
 * has not reached the server.
 * @param {string} base Candidate base URL, ending in `/`.
 * @param {Object} [opts]
 * @param {number} [opts.samples] Pings to send, the first discarded.
 * @param {number} [opts.timeoutMs] Ceiling on all of them together.
 * @param {typeof fetch} [opts.fetchImpl]
 * @param {function(): number} [opts.now] Millisecond clock.
 * @returns {Promise<?number>} Median round trip in ms, `null` on any failure.
 */
export async function measureRtt(base, {
  samples = PING_SAMPLES, timeoutMs = PING_TIMEOUT_MS,
  fetchImpl = (...a) => fetch(...a), now = () => performance.now(),
} = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const times = [];
    for (let i = 0; i < samples; i++) {
      const t0 = now();
      const res = await fetchImpl(`${base}api/ping`, {
        cache: 'no-store', mode: 'cors', redirect: 'error', signal: ctrl.signal,
      });
      if (!res.ok) return null;
      times.push(now() - t0);
    }
    return median(times.slice(1));
  } catch (e) {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * The lowest timed candidate; ties go to the earlier one.
 * @param {WsRouteCandidate[]} candidates
 * @returns {?WsRouteCandidate} `null` when none was timed.
 */
export function pickFastest(candidates) {
  let best = null;
  for (const c of candidates) {
    if (c.rttMs === null || !Number.isFinite(c.rttMs)) continue;
    if (best === null || c.rttMs < best.rttMs) best = c;
  }
  return best;
}

/**
 * Fetches the direct endpoint list from the page's own origin.
 *
 * Any failure, a server without the route included, reads as an empty list,
 * and so does a request that outlives `LIST_TIMEOUT_MS`: the session socket
 * waits on this list, so an origin that accepts it and never answers must not
 * hold the socket back.
 * An endpoint on the page's own origin is dropped: the page already is there.
 * @param {string} originBase The page's base URL, ending in `/`.
 * @param {Object} [opts]
 * @param {Object<string, string>} [opts.headers] Session auth headers.
 * @param {typeof fetch} [opts.fetchImpl]
 * @returns {Promise<{urls: string[], behindCloudflare: boolean}>} The list,
 *     and whether the origin answered through Cloudflare (a `cf-ray` header),
 *     which names that route for the user.
 */
export async function fetchDirectEndpoints(originBase, {
  headers = {}, fetchImpl = (...a) => fetch(...a),
} = {}) {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), LIST_TIMEOUT_MS);
  try {
    const res = await fetchImpl(`${originBase}api/direct-endpoints`,
      { cache: 'no-store', headers, signal: ctrl.signal });
    if (!res.ok) return { urls: [], behindCloudflare: false };
    const body = await res.json();
    const own = new URL(originBase).origin;
    const urls = (Array.isArray(body && body.urls) ? body.urls : [])
      .filter((u) => typeof u === 'string' && /^https:\/\//i.test(u))
      .map((u) => (u.endsWith('/') ? u : `${u}/`))
      .filter((u) => new URL(u).origin !== own);
    return { urls, behindCloudflare: res.headers.has('cf-ray') };
  } catch (e) {
    return { urls: [], behindCloudflare: false };
  } finally {
    clearTimeout(timer);
  }
}

/**
 * The name a route is shown under: `Tailscale` for a tailnet host, `CF` for
 * an origin served through Cloudflare, otherwise the host itself.
 * @param {string} base Candidate base URL.
 * @param {boolean} [behindCloudflare] Whether this origin answered via Cloudflare.
 * @returns {string}
 */
export function routeLabel(base, behindCloudflare = false) {
  const url = new URL(base);
  if (url.hostname.endsWith('.ts.net')) return 'Tailscale';
  if (behindCloudflare) return 'CF';
  return url.host;
}

/**
 * Decides where the session socket opens (see the module docblock).
 * @param {Object} opts
 * @param {string} opts.originBase The page's base URL, ending in `/`.
 * @param {string[]} opts.directBases The direct endpoints, in configured order.
 * @param {string} opts.pref One of `WS_ROUTE_PREFS`; anything else is `auto`.
 * @param {boolean} [opts.directFailed] A direct socket already failed in this
 *     tab, so only the origin is tried.
 * @param {function(string): Promise<?number>} [opts.measure] Times one base.
 * @param {number} [opts.budgetMs] Ceiling on the `auto` race.
 * @returns {Promise<WsRouteChoice>}
 */
export async function resolveWsRoute({
  originBase, directBases, pref, directFailed = false,
  measure = (base) => measureRtt(base), budgetMs = PROBE_BUDGET_MS,
}) {
  const candidates = [{ route: 'origin', base: originBase, rttMs: null },
    ...directBases.map((base) => ({ route: 'direct', base, rttMs: null }))];
  const choose = (c, fallback = false) => ({
    route: c.route, base: c.base, rttMs: c.rttMs, candidates, fallback,
  });
  if (!directBases.length || pref === 'origin') return choose(candidates[0]);
  if (directFailed) return choose(candidates[0], true);
  if (pref === 'direct') return choose(candidates[1]);

  let budgetTimer = null;
  const budget = new Promise((resolve) => { budgetTimer = setTimeout(resolve, budgetMs, null); });
  await Promise.all(candidates.map(async (c) => {
    c.rttMs = await Promise.race([measure(c.base), budget]);
  }));
  clearTimeout(budgetTimer);
  return choose(pickFastest(candidates) || candidates[0]);
}

/**
 * The session socket's URL for a base: `wss` for an https base, `ws` for http.
 * The caller appends the socket path and query as it does for the origin.
 * @param {string} base Base URL, ending in `/`.
 * @returns {URL}
 */
export function wsUrlFromBase(base) {
  const url = new URL(base);
  url.protocol = url.protocol === 'http:' ? 'ws:' : 'wss:';
  return url;
}
