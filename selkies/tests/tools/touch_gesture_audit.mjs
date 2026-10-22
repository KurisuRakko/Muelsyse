/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

// Direct-touch gestures, driven through Input._handleTouchEvent the way a
// tablet's Touch Events reach it, with every message the page would put on the
// wire captured: a one-finger swipe scrolls and never holds a button, however
// fast or slow the screen reports it; a tap of any length short of the long
// press clicks; a double tap held down drags with the left button; a full
// long-press ring right-clicks on lift and drags with the left button when it
// moves instead; two fingers scroll, tap to right-click and pinch the local
// view; a cancel or a third finger releases what a drag held. Native touch,
// once the server offers it, sends each finger as a contact instead. The pure
// gesture math in lib/touch-gestures.js is checked on numbers.
//
// Prints one PASS/FAIL line per check and exits non-zero if any failed.

let failed = 0;
function check(label, ok, detail = '') {
    if (!ok) failed++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  [touch] ${label}  ${detail}`);
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const rect = (left, top, width, height) => ({
    left, top, width, height, right: left + width, bottom: top + height, x: left, y: top,
});

const nodes = new Map();
class FakeNode {
    constructor(id, tagName) {
        this.id = id;
        this.tagName = tagName;
        this.style = { setProperty() {}, removeProperty() {} };
        this.isConnected = true;
        this._rect = rect(0, 0, 0, 0);
        this.width = 0; this.height = 0;
        this.videoWidth = 0; this.videoHeight = 0;
        this.offsetWidth = 0; this.offsetHeight = 0;
        this.offsetLeft = 0; this.offsetTop = 0;
    }
    setBox(r) { this._rect = r; this.offsetWidth = r.width; this.offsetHeight = r.height; return this; }
    getBoundingClientRect() { return this._rect; }
    getContext() { return fakeContext; }
    addEventListener() {}
    removeEventListener() {}
    appendChild() {}
    closest() { return null; }
    contains() { return true; }
}
const fakeContext = new Proxy({}, { get: (_t, prop) => (prop === 'canvas' ? null : () => undefined) });

const element = new FakeNode('overlayInput', 'INPUT');
const canvasNode = new FakeNode('videoCanvas', 'CANVAS');
const container = new FakeNode('container', 'DIV');
nodes.set('videoCanvas', canvasNode);

const defineGlobal = (name, value) =>
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
defineGlobal('navigator', { platform: 'MacIntel', userAgent: 'node', maxTouchPoints: 5 });
defineGlobal('window', {
    devicePixelRatio: 2,
    location: { origin: 'http://localhost', href: 'http://localhost/' },
    addEventListener() {}, removeEventListener() {},
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    screenX: 0, screenY: 0, innerWidth: 1600, innerHeight: 900,
});
// The feedback layer builds on these fake nodes too, so a throw in it fails here.
defineGlobal('document', {
    body: new FakeNode('body', 'BODY'),
    documentElement: new FakeNode('html', 'HTML'),
    getElementById: (id) => nodes.get(id) || null,
    createElement: (tag) => new FakeNode('', String(tag).toUpperCase()),
    addEventListener() {}, removeEventListener() {},
});

const { Input } = await import('../../addons/selkies-web-core/lib/input.js');
const { lockScrollAxis, ScrollAccumulator, releaseVelocity, inertiaStep, pinchView, clampView } =
    await import('../../addons/selkies-web-core/lib/touch-gestures.js');

const input = new Input(element, () => {}, false, 0, null);
input._drawAndScaleCursor = () => {};
input._updateBrowserCursor = () => {};
input._streamContainer = container;
for (const node of [canvasNode, element, container]) node.setBox(rect(0, 0, 1600, 900));
canvasNode.width = 1600; canvasNode.height = 900;
input.setStreamResolution(1600, 900);
input._windowMath();
input.inputAttached = true;

const sent = [];
input.send = (m) => sent.push(m);

let seq = 0;
const touch = (id, x, y) => ({ identifier: id, clientX: x, clientY: y, screenX: x, screenY: y });
const fire = (type, touches, onScreen) => input._handleTouchEvent({
    type, changedTouches: touches, touches: onScreen, target: element, [`_n${seq++}`]: 1,
    preventDefault() {}, stopPropagation() {},
});

const parse = () => sent.map((m) => {
    const [t, x, y, mask, mag] = m.split(',');
    return { t, x: +x, y: +y, mask: +mask, mag: +mag };
});
/** Wheel notches per scroll button: the rising-edge message carries the bit and the count. */
const notches = () => {
    const out = { up: 0, down: 0, left: 0, right: 0 };
    for (const m of parse()) {
        if (m.t !== 'm2') continue;
        if (m.mask & (1 << 3)) out.down += m.mag;
        if (m.mask & (1 << 4)) out.up += m.mag;
        if (m.mask & (1 << 6)) out.left += m.mag;
        if (m.mask & (1 << 7)) out.right += m.mag;
    }
    return out;
};
const anyButton = (bit) => parse().some((m) => m.mask & bit);
const reset = async () => {
    await sleep(80);
    input._resetTouchGesture();
    input._lastTouchTap = null;
    input.buttonMask = 0;
    sent.length = 0;
};

/** One finger from (x, y0) to (x, y1) in `step`-pixel touchmoves, all at once. */
function swipe(x, y0, y1, step, id = 1) {
    fire('touchstart', [touch(id, x, y0)]);
    const dir = Math.sign(y1 - y0);
    for (let y = y0 + dir * step; dir > 0 ? y <= y1 : y >= y1; y += dir * step) {
        fire('touchmove', [touch(id, x, y)]);
    }
    fire('touchend', [touch(id, x, y1)]);
}

input.setTouchOptions({ longPressMs: 400 });

// --- one finger scrolls -------------------------------------------------

{
    await reset();
    swipe(800, 700, 400, 10);
    const n = notches();
    check('a one-finger swipe up scrolls down and holds no button',
        n.down === 7 && n.up === 0 && !anyButton(1), JSON.stringify(n));
    const hover = parse().find((m) => m.t === 'm');
    check('the pointer is moved to where the finger landed before scrolling',
        hover && hover.x === 800 && hover.y === 700 && hover.mask === 0, JSON.stringify(hover));
}
{
    await reset();
    swipe(800, 700, 400, 5);
    const fast = notches().down;
    await reset();
    swipe(800, 700, 400, 15);
    const slow = notches().down;
    check('the distance scrolled does not depend on the touch event rate', fast === slow && fast === 7,
        `5px steps ${fast}, 15px steps ${slow}`);
}
{
    await reset();
    swipe(800, 300, 600, 1);
    check('a slow swipe of one pixel per event still scrolls', notches().up === 7, JSON.stringify(notches()));
}
{
    await reset();
    fire('touchstart', [touch(1, 900, 450)]);
    for (let x = 890; x >= 700; x -= 10) fire('touchmove', [touch(1, x, 450 + (x % 20 ? 1 : -1))]);
    fire('touchend', [touch(1, 700, 450)]);
    const n = notches();
    check('a swipe left scrolls right, locked to the horizontal axis',
        n.right === 5 && n.up === 0 && n.down === 0 && n.left === 0, JSON.stringify(n));
}

// --- taps -----------------------------------------------------------------

{
    await reset();
    fire('touchstart', [touch(1, 500, 500)]);
    await sleep(100);
    fire('touchend', [touch(1, 502, 501)]);
    await sleep(40);
    const m = parse();
    check('a quick tap clicks the left button where it lifts',
        m.length === 2 && m[0].mask === 1 && m[1].mask === 0 && m[0].x === 502, sent.join(' '));
}
{
    await reset();
    fire('touchstart', [touch(1, 500, 500)]);
    await sleep(300);
    fire('touchend', [touch(1, 500, 500)]);
    await sleep(40);
    const m = parse();
    check('a slow tap short of the long press still clicks',
        m.length === 2 && m[0].mask === 1 && m[1].mask === 0, sent.join(' '));
}
{
    await reset();
    fire('touchstart', [touch(1, 500, 500)]);
    fire('touchend', [touch(1, 500, 500)]);
    await sleep(60);
    fire('touchstart', [touch(2, 505, 503)]);
    fire('touchend', [touch(2, 505, 503)]);
    await sleep(40);
    const presses = parse().filter((m) => m.mask === 1).length;
    check('a double tap is two clicks', presses === 2 && parse().at(-1).mask === 0, sent.join(' '));
}

// --- dragging ---------------------------------------------------------------

{
    await reset();
    fire('touchstart', [touch(1, 400, 400)]);
    fire('touchend', [touch(1, 400, 400)]);
    await sleep(60);
    sent.length = 0;
    fire('touchstart', [touch(2, 402, 401)]);
    for (let x = 410; x <= 600; x += 10) fire('touchmove', [touch(2, x, 401)]);
    fire('touchend', [touch(2, 600, 401)]);
    const m = parse();
    const held = m.slice(0, -1).every((e) => e.mask === 1);
    check('a double tap held down drags with the left button, released on lift',
        m[0].x === 402 && held && m.at(-1).mask === 0 && m.at(-1).x === 600 && notches().down === 0,
        `${m.length} messages, first ${sent[0]}, last ${sent.at(-1)}`);
}
{
    await reset();
    fire('touchstart', [touch(1, 300, 300)]);
    await sleep(470);
    fire('touchend', [touch(1, 304, 302)]);
    await sleep(80);
    const m = parse();
    check('a full long-press ring right-clicks where the press began on lift',
        m.length === 2 && m[0].mask === 4 && m[0].x === 300 && m[0].y === 300 && m[1].mask === 0
        && !anyButton(1), sent.join(' '));
}
{
    await reset();
    fire('touchstart', [touch(1, 300, 300)]);
    await sleep(470);
    for (let x = 310; x <= 400; x += 10) fire('touchmove', [touch(1, x, 300)]);
    fire('touchend', [touch(1, 400, 300)]);
    await sleep(80);
    const m = parse();
    check('a full ring that moves drags with the left button from where it began',
        m[0].mask === 1 && m[0].x === 300 && m.at(-1).mask === 0 && m.at(-1).x === 400 && !anyButton(4),
        `first ${sent[0]}, last ${sent.at(-1)}`);
}
{
    await reset();
    fire('touchstart', [touch(1, 300, 300)]);
    await sleep(200);
    for (let y = 290; y >= 100; y -= 10) fire('touchmove', [touch(1, 300, y)]);
    await sleep(400);
    fire('touchend', [touch(1, 300, 100)]);
    await sleep(80);
    check('moving before the ring fills scrolls and never right-clicks',
        notches().down === 5 && !anyButton(4) && !anyButton(1), JSON.stringify(notches()));
}
{
    await reset();
    input.setTouchOptions({ swipeScroll: false });
    swipe(800, 700, 400, 10);
    const m = parse();
    check('with swipe scrolling off a swipe drags with the left button',
        m[0].mask === 1 && m[0].y === 700 && m.at(-1).mask === 0 && notches().down === 0,
        `first ${sent[0]}, last ${sent.at(-1)}`);
    input.setTouchOptions({ swipeScroll: true });
}

// --- two fingers -------------------------------------------------------------

{
    await reset();
    fire('touchstart', [touch(1, 700, 400), touch(2, 900, 400)]);
    await sleep(80);
    fire('touchend', [touch(1, 700, 400)]);
    fire('touchend', [touch(2, 900, 400)]);
    await sleep(80);
    const m = parse();
    check('a two-finger tap right-clicks between the fingers',
        m.length === 2 && m[0].mask === 4 && m[0].x === 800 && m[1].mask === 0, sent.join(' '));
}
{
    await reset();
    fire('touchstart', [touch(1, 700, 700)]);
    fire('touchstart', [touch(2, 900, 700)]);
    for (let y = 690; y >= 500; y -= 10) fire('touchmove', [touch(1, 700, y), touch(2, 900, y)]);
    fire('touchend', [touch(1, 700, 500), touch(2, 900, 500)]);
    check('two fingers scroll by distance and hold no button',
        notches().down === 5 && !anyButton(1) && !anyButton(4), JSON.stringify(notches()));
}
{
    await reset();
    fire('touchstart', [touch(1, 750, 450), touch(2, 850, 450)]);
    for (let d = 55; d <= 100; d += 5) fire('touchmove', [touch(1, 800 - d, 450), touch(2, 800 + d, 450)]);
    const zoom = input.viewZoom;
    const t = canvasNode.style.transform;
    fire('touchend', [touch(1, 700, 450), touch(2, 900, 450)]);
    check('a pinch zooms the local view and sends nothing',
        Math.abs(zoom - 2) < 1e-9 && /scale\(2\)/.test(t) && sent.length === 0, `zoom ${zoom}, ${t}, ${sent.length} sent`);
    await reset();
    fire('touchstart', [touch(1, 700, 450), touch(2, 900, 450)]);
    for (let d = 95; d >= 51; d -= 4) fire('touchmove', [touch(1, 800 - d, 450), touch(2, 800 + d, 450)]);
    fire('touchend', [touch(1, 749, 450), touch(2, 851, 450)]);
    check('pinching back to about 1x snaps the view to unzoomed',
        input.viewZoom === 1 && canvasNode.style.transform === '', `zoom ${input.viewZoom}`);
}

// --- releases -----------------------------------------------------------------

{
    await reset();
    fire('touchstart', [touch(1, 400, 400)]);
    fire('touchend', [touch(1, 400, 400)]);
    await sleep(60);
    fire('touchstart', [touch(2, 400, 400)]);
    fire('touchmove', [touch(2, 450, 400)]);
    fire('touchcancel', [touch(2, 450, 400)]);
    check('a cancel mid-drag releases the left button', input.buttonMask === 0 && parse().at(-1).mask === 0,
        sent.at(-1));
}
{
    await reset();
    fire('touchstart', [touch(1, 400, 400)]);
    fire('touchend', [touch(1, 400, 400)]);
    await sleep(60);
    fire('touchstart', [touch(2, 400, 400)]);
    fire('touchmove', [touch(2, 450, 400)]);
    fire('touchstart', [touch(3, 600, 600), touch(4, 650, 600)]);
    fire('touchmove', [touch(2, 500, 400)]);
    const after = sent.length;
    fire('touchend', [touch(2, 500, 400), touch(3, 600, 600), touch(4, 650, 600)]);
    check('a third finger drops a drag, releasing it, and the rest is ignored',
        input.buttonMask === 0 && parse().at(-1).mask === 0 && sent.length === after, sent.slice(-2).join(' '));
}

{
    await reset();
    const pen = (x, y) => ({ ...touch(9, x, y), touchType: 'stylus' });
    fire('touchstart', [pen(400, 400)]);
    for (let y = 390; y >= 200; y -= 10) fire('touchmove', [pen(400, y)]);
    fire('touchend', [pen(400, 200)]);
    await sleep(40);
    check('an Apple Pencil is left to the pen pointer path', sent.length === 0, sent.join(' '));
}
{
    await reset();
    fire('touchstart', [touch(1, 400, 400)], [touch(1, 400, 400)]);
    // The touchend for contact 1 never arrives.
    fire('touchstart', [touch(2, 600, 600)], [touch(2, 600, 600)]);
    fire('touchend', [touch(2, 600, 600)], []);
    await sleep(40);
    const m = parse();
    check('a contact whose touchend was lost does not block the next tap',
        m.length === 2 && m[0].mask === 1 && m[0].x === 600, sent.join(' '));
}

// --- inertia -------------------------------------------------------------------

{
    await reset();
    fire('touchstart', [touch(1, 800, 800)]);
    for (let i = 1; i <= 8; i++) {
        await sleep(8);
        fire('touchmove', [touch(1, 800, 800 - i * 16)]);
    }
    fire('touchend', [touch(1, 800, 672)]);
    const atLift = notches().down;
    await sleep(250);
    const coasting = notches().down;
    fire('touchstart', [touch(2, 100, 100)]);
    const stoppedAt = notches().down;
    await sleep(150);
    fire('touchend', [touch(2, 100, 100)]);
    check('a flick keeps scrolling after the finger lifts', coasting > atLift, `${atLift} -> ${coasting}`);
    check('a new touch stops the inertia', notches().down === stoppedAt, `${stoppedAt} -> ${notches().down}`);
    check('the touch that stops the inertia does not click', !anyButton(1), sent.slice(-2).join(' '));
}
{
    await reset();
    swipe(800, 700, 400, 10);
    await sleep(150);
    check('a swipe reported all at once leaves no inertia', notches().down === 7, JSON.stringify(notches()));
}

// --- trackpad mode ---------------------------------------------------------------

{
    await reset();
    input.setTrackpadMode(true);
    sent.length = 0;
    fire('touchstart', [touch(1, 700, 700), touch(2, 900, 700)]);
    for (let y = 695; y >= 500; y -= 5) fire('touchmove', [touch(1, 700, y), touch(2, 900, y)]);
    fire('touchend', [touch(1, 700, 500), touch(2, 900, 500)]);
    await sleep(80);
    check('trackpad two-finger scroll counts distance, not events', notches().down === 5, JSON.stringify(notches()));
    input.setTrackpadMode(false);
}

// --- the pure rules ----------------------------------------------------------------

check('a mostly vertical start locks the vertical axis',
    lockScrollAxis(3, 20, 1.5) === 'y' && lockScrollAxis(20, 3, 1.5) === 'x' && lockScrollAxis(10, 12, 1.5) === 'xy');
{
    const acc = new ScrollAccumulator(40);
    const got = [acc.add(30), acc.add(30), acc.add(-30), acc.add(-30)];
    check('the notch carry resets when the direction turns', got.join() === '0,1,0,-1', got.join());
}
{
    const v = releaseVelocity([{ t: 0, x: 0, y: 0 }, { t: 50, x: 0, y: -100 }, { t: 100, x: 0, y: -200 }], 100, 80);
    check('release velocity reads the recent samples', Math.abs(v.vy + 2) < 1e-9 && v.vx === 0, JSON.stringify(v));
}
// --- native touch ---------------------------------------------------------

const frames = () => sent.filter((m) => m.startsWith('t,')).map((m) => {
    const f = m.split(',').slice(1);
    const out = [];
    for (let i = 0; i < f.length; i += 4) out.push({ k: f[i], id: +f[i + 1], x: +f[i + 2], y: +f[i + 3] });
    return out;
});
{
    await reset();
    swipe(800, 700, 400, 10);
    check('touch stays emulated until the server offers native touch', frames().length === 0 && notches().down === 7);
    input.setNativeTouchAvailable(true);
    check('native touch is the default once the server offers it', input.nativeTouchActive());
    await reset();
    swipe(800, 700, 400, 10);
    const f = frames();
    const flat = f.flat();
    check('a native swipe is one down, a motion per move and one up, with no pointer message',
        f.length === 32 && flat[0].k === 'd' && flat[0].x === 800 && flat[0].y === 700
        && flat.at(-1).k === 'u' && flat.slice(1, -1).every((e) => e.k === 'm')
        && !sent.some((m) => m.startsWith('m')), `${f.length} frames, ${sent.length} messages`);
    check('every event of one contact carries its id', new Set(flat.map((e) => e.id)).size === 1);
}
{
    await reset();
    fire('touchstart', [touch(1, 100, 100)]);
    const first = frames()[0][0].id;
    fire('touchstart', [touch(2, 300, 300)], [touch(1, 100, 100), touch(2, 300, 300)]);
    fire('touchmove', [touch(1, 110, 100), touch(2, 290, 300)]);
    const both = frames()[2];
    fire('touchend', [touch(1, 110, 100), touch(2, 290, 300)]);
    const ups = frames()[3];
    check('two contacts move in one frame and lift in one frame',
        both.length === 2 && both[0].id === first && both[1].id !== first && ups.length === 2 && ups.every((e) => e.k === 'u'),
        JSON.stringify(frames()));
    fire('touchstart', [touch(1, 100, 100)], [touch(1, 100, 100)]);
    check('a new contact gets a fresh id even when the browser reuses its identifier',
        frames()[4][0].id !== first && frames()[4][0].id !== both[1].id);
    fire('touchend', [touch(1, 100, 100)], []);
}
{
    await reset();
    fire('touchstart', [touch(1, 100, 100)]);
    fire('touchstart', [touch(2, 400, 400)], [touch(2, 400, 400)]);
    const f = frames()[1];
    check('a contact whose touchend was lost is lifted before the next one goes down',
        f.length === 2 && f[0].k === 'u' && f[1].k === 'd', JSON.stringify(f));
    fire('touchcancel', [touch(2, 400, 400)], []);
    check('a cancel ends the touch sequence', frames()[2][0].k === 'c' && input._nativeContacts.size === 0);
}
{
    await reset();
    fire('touchstart', [{ ...touch(1, 100, 100), touchType: 'stylus' }]);
    check('an Apple Pencil touch is not sent as a finger', frames().length === 0);
    fire('touchend', [{ ...touch(1, 100, 100), touchType: 'stylus' }]);
}
{
    await reset();
    fire('touchstart', [touch(1, 500, 500)]);
    input.setTouchOptions({ native: false });
    check('switching to emulated touch cancels the contacts native touch held',
        sent.at(-1) === 't,c,0,0,0' && !input.nativeTouchActive());
    fire('touchend', [touch(1, 500, 500)]);
    await reset();
    swipe(800, 700, 400, 10);
    check('emulated touch scrolls again after switching back', frames().length === 0 && notches().down === 7);
    input.setTouchOptions({ native: true });
    await reset();
    input.setTrackpadMode(true);
    check('trackpad mode takes touch from the native path', !input.nativeTouchActive());
    input.setTrackpadMode(false);
    input.setNativeTouchAvailable(false);
    check('a server without native touch falls back to emulated touch', !input.nativeTouchActive());
    input.setNativeTouchAvailable(true);
}
{
    await reset();
    input._cancelNativeTouch();
    check('nothing is cancelled when no contact is held', sent.length === 0);
}

{
    const burst = releaseVelocity([{ t: 0, x: 0, y: 0 }, { t: 2, x: 0, y: -300 }], 2, 80);
    const fling = releaseVelocity([{ t: 0, x: 0, y: 0 }, { t: 20, x: 0, y: -1000 }], 20, 80);
    check('a burst of moves in a few milliseconds is no fling, and speed is capped',
        burst.vy === 0 && Math.abs(fling.vy + 6) < 1e-9, `${burst.vy}, ${fling.vy}`);
}
{
    let v = 2, total = 0;
    for (let i = 0; i < 400; i++) { const s = inertiaStep(v, 16, 325); total += s.distance; v = s.v; }
    let v2 = 2, total2 = 0;
    for (let i = 0; i < 200; i++) { const s = inertiaStep(v2, 32, 325); total2 += s.distance; v2 = s.v; }
    check('inertia covers v * tau whatever the frame interval', Math.abs(total - 650) < 0.5 && Math.abs(total2 - 650) < 0.5,
        `${total.toFixed(2)}, ${total2.toFixed(2)}`);
}
{
    const v = pinchView({ scale: 1, tx: 0, ty: 0 }, { x: 400, y: 300 }, 100, { x: 400, y: 300 }, 200, 1600, 900, 1, 4);
    const back = { x: (400 - v.tx) / v.scale, y: (300 - v.ty) / v.scale };
    check('a pinch keeps the point between the fingers under them', v.scale === 2 && back.x === 400 && back.y === 300,
        JSON.stringify(v));
    const edge = pinchView({ scale: 1, tx: 0, ty: 0 }, { x: 10, y: 10 }, 100, { x: 300, y: 300 }, 200, 1600, 900, 1, 4);
    check('the zoomed view never uncovers the viewport', edge.tx === 0 && edge.ty === 0, JSON.stringify(edge));
    const c = clampView({ scale: 2, tx: -5000, ty: 50 }, 1600, 900);
    check('panning is clamped to the zoomed content', c.tx === -1600 && c.ty === 0, JSON.stringify(c));
    const capped = pinchView({ scale: 3, tx: 0, ty: 0 }, { x: 0, y: 0 }, 100, { x: 0, y: 0 }, 1000, 1600, 900, 1, 4);
    check('zoom stops at the maximum', capped.scale === 4, String(capped.scale));
}

console.log(failed ? `${failed} check(s) failed` : 'all touch checks passed');
process.exit(failed ? 1 : 0);
