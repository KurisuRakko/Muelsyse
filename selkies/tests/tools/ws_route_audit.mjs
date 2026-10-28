/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

// Where the WebSocket core opens its session socket (lib/ws-route.js): the
// round-trip timing that drops the setup ping and takes the median, the race
// that keeps the fastest door with no door preferred, and the preferences that
// skip the race. Fetch and the clock are stubs, so every number is exact.
//
// Prints one PASS/FAIL line per check and exits non-zero if any failed.

const { median, measureRtt, pickFastest, resolveWsRoute, fetchDirectEndpoints,
        routeLabel, wsUrlFromBase } = await import('../../addons/selkies-web-core/lib/ws-route.js');

let failed = 0;

function check(label, ok, detail = '') {
    if (!ok) failed++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  [ws-route] ${label}  ${detail}`);
}

const ORIGIN = 'https://desktop.example/';
const TS = 'https://host.example.ts.net:8444/';
const OTHER = 'https://other.example/';

{
    check('median of an odd list', median([30, 10, 20]) === 20);
    check('median of an even list', median([10, 40, 20, 30]) === 25);
    check('median of nothing', median([]) === null);
}

{
    // A clock that advances by the scripted durations, one per fetch.
    const durations = [300, 20, 25, 22];
    let t = 0, i = 0;
    const urls = [];
    const rtt = await measureRtt(TS, {
        now: () => t,
        fetchImpl: async (url, init) => {
            urls.push([url, init.cache, init.mode]);
            t += durations[i++];
            return { ok: true };
        },
    });
    check('the setup ping is dropped and the median of the rest kept', rtt === 22, rtt);
    check('four uncached CORS pings at the base', urls.length === 4
        && urls.every(([u, c, m]) => u === `${TS}api/ping` && c === 'no-store' && m === 'cors'),
        JSON.stringify(urls[0]));
}

{
    const failing = await measureRtt(TS, { fetchImpl: async () => { throw new TypeError('cors'); } });
    check('a failed fetch drops the candidate', failing === null, failing);
    const refused = await measureRtt(TS, { fetchImpl: async () => ({ ok: false }) });
    check('a non-2xx answer drops the candidate', refused === null, refused);
    const hung = await measureRtt(TS, {
        timeoutMs: 30,
        fetchImpl: (url, init) => new Promise((_, reject) => {
            init.signal.addEventListener('abort', () => reject(new Error('aborted')));
        }),
    });
    check('a candidate overrunning its timeout is aborted and dropped', hung === null, hung);
}

{
    const c = [{ base: 'a', rttMs: null }, { base: 'b', rttMs: 12 }, { base: 'c', rttMs: 12 }];
    check('the lowest timed candidate wins, ties to the earlier', pickFastest(c).base === 'b');
    check('nothing timed: no winner', pickFastest([{ base: 'a', rttMs: null }]) === null);
}

{
    const table = { [ORIGIN]: 18, [TS]: 25 };
    const measure = async (base) => table[base];
    const auto = await resolveWsRoute({ originBase: ORIGIN, directBases: [TS], pref: 'auto', measure });
    check('auto keeps the origin when it is faster', auto.route === 'origin' && auto.rttMs === 18,
        JSON.stringify(auto));
    table[TS] = 9;
    const autoDirect = await resolveWsRoute({ originBase: ORIGIN, directBases: [TS], pref: 'auto', measure });
    check('auto takes the direct endpoint when it is faster',
        autoDirect.route === 'direct' && autoDirect.base === TS && autoDirect.rttMs === 9);
    check('auto reports every candidate it timed',
        autoDirect.candidates.map((c) => c.rttMs).join() === '18,9');

    const allDown = await resolveWsRoute({
        originBase: ORIGIN, directBases: [TS], pref: 'auto', measure: async () => null });
    check('nothing answering keeps the origin', allDown.route === 'origin' && allDown.base === ORIGIN);

    const slow = await resolveWsRoute({
        originBase: ORIGIN, directBases: [TS], pref: 'auto', budgetMs: 20,
        measure: (base) => (base === TS ? new Promise(() => {}) : Promise.resolve(40)) });
    check('a candidate still timing at the budget is out', slow.route === 'origin'
        && slow.candidates[1].rttMs === null, JSON.stringify(slow.candidates));

    let timed = 0;
    const counting = async () => { timed++; return 1; };
    const direct = await resolveWsRoute({
        originBase: ORIGIN, directBases: [TS, OTHER], pref: 'direct', measure: counting });
    check('direct takes the first endpoint untimed', direct.route === 'direct' && direct.base === TS && timed === 0);
    const origin = await resolveWsRoute({
        originBase: ORIGIN, directBases: [TS], pref: 'origin', measure: counting });
    check('origin stays untimed', origin.route === 'origin' && timed === 0);
    const none = await resolveWsRoute({ originBase: ORIGIN, directBases: [], pref: 'auto', measure: counting });
    check('an empty list stays on the origin untimed', none.route === 'origin' && timed === 0 && !none.fallback);
    const failedTab = await resolveWsRoute({
        originBase: ORIGIN, directBases: [TS], pref: 'direct', directFailed: true, measure: counting });
    check('a direct socket that failed in this tab falls back to the origin',
        failedTab.route === 'origin' && failedTab.fallback && timed === 0);
}

{
    const reply = (status, body, headers = {}) => async () => ({
        ok: status >= 200 && status < 300, json: async () => body,
        headers: { has: (k) => k in headers },
    });
    let r = await fetchDirectEndpoints(ORIGIN, {
        fetchImpl: reply(200, { urls: [TS, 'https://desktop.example/', 'http://plain.example/', OTHER.slice(0, -1)] },
                         { 'cf-ray': 'x' }) });
    check('the list keeps https endpoints off the page origin, with a trailing slash',
        JSON.stringify(r.urls) === JSON.stringify([TS, OTHER]), JSON.stringify(r.urls));
    check('a cf-ray header marks the origin as Cloudflare', r.behindCloudflare === true);
    r = await fetchDirectEndpoints(ORIGIN, { fetchImpl: reply(404, null) });
    check('a server without the route offers nothing', r.urls.length === 0);
    r = await fetchDirectEndpoints(ORIGIN, { fetchImpl: async () => { throw new Error('offline'); } });
    check('an unreachable list offers nothing', r.urls.length === 0);
}

{
    check('a tailnet host is named Tailscale', routeLabel(TS) === 'Tailscale');
    check('a Cloudflare origin is named CF', routeLabel(ORIGIN, true) === 'CF');
    check('anything else is named by its host', routeLabel('https://lan.example:8443/') === 'lan.example:8443');
    check('an https base opens wss', wsUrlFromBase(TS).href === 'wss://host.example.ts.net:8444/');
    check('an http base opens ws', wsUrlFromBase('http://lan.example:8090/desk/').href === 'ws://lan.example:8090/desk/');
}

process.exit(failed ? 1 : 0);
