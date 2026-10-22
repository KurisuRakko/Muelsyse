// IME caret placement: the composition host's insertion point follows the
// remote caret, so the browser opens its IME window under the remote field.
//
// The host is the stream overlay; `Input._applyImeCaret` narrows its content
// box with padding to one caret-high line at the caret. Checked here against
// fabricated rectangles: the frame-to-CSS mapping (letterbox and density),
// a layout box that differs from the CSS box, the click fallback, and that a
// change mid-composition waits for it to settle.
//
// Prints one PASS/FAIL line per check and exits non-zero if any failed.

let failed = 0;
function check(label, ok, detail = '') {
    if (!ok) failed++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  [ime-caret] ${label}  ${detail}`);
}
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;
const px = (v) => parseFloat(v);

const rect = (left, top, width, height) => ({
    left, top, width, height, right: left + width, bottom: top + height,
    x: left, y: top,
});

const nodes = new Map();

class FakeNode {
    constructor(id, tagName) {
        this.id = id;
        this.tagName = tagName;
        this.style = {};
        this.isConnected = true;
        this._rect = rect(0, 0, 0, 0);
        this.width = 0;
        this.height = 0;
        this.videoWidth = 0;
        this.videoHeight = 0;
        this.offsetWidth = 0;
        this.offsetHeight = 0;
    }
    setBox(r) {
        this._rect = r;
        this.offsetWidth = r.width;
        this.offsetHeight = r.height;
        return this;
    }
    getBoundingClientRect() { return this._rect; }
    getContext() { return fakeContext; }
    addEventListener() {}
    removeEventListener() {}
    appendChild() {}
    closest() { return null; }
}

const fakeContext = new Proxy({}, {
    get: (_t, prop) => (prop === 'canvas' ? null : () => undefined),
});

const element = new FakeNode('overlayInput', 'INPUT');
const canvasNode = new FakeNode('videoCanvas', 'CANVAS');
nodes.set('videoCanvas', canvasNode);

// Node 24 defines `navigator` as a getter-only global, so every stub goes in
// through defineProperty rather than assignment.
const defineGlobal = (name, value) =>
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });

defineGlobal('navigator', { platform: 'Linux x86_64', userAgent: 'node', maxTouchPoints: 0 });
defineGlobal('window', {
    devicePixelRatio: 2,
    location: { origin: 'http://localhost', href: 'http://localhost/' },
    addEventListener() {}, removeEventListener() {},
    // 故意不提供 requestAnimationFrame：_pointerScale 的每帧缓存因此不生效，
    // 每次断言都重新量一次几何，正是这里要检查的东西。
    matchMedia: () => ({ matches: false, addEventListener() {}, removeEventListener() {} }),
    screenX: 0, screenY: 0, innerWidth: 1600, innerHeight: 900,
});
defineGlobal('document', {
    body: new FakeNode('body', 'BODY'),
    documentElement: new FakeNode('html', 'HTML'),
    getElementById: (id) => nodes.get(id) || null,
    createElement: (tag) => new FakeNode('', String(tag).toUpperCase()),
    addEventListener() {}, removeEventListener() {},
});

const { Input } = await import('../../addons/selkies-web-core/lib/input.js');
const input = new Input(element, () => {}, false, 0, null);
// 光标绘制走 ImageBitmap/2D 上下文，与几何无关，这里只关心映射。
input._drawAndScaleCursor = () => {};
input._updateBrowserCursor = () => {};


/** Points the fake DOM at one CSS box and one framebuffer. */
function layout(cssBox, fbWidth, fbHeight, layoutW = cssBox.width, layoutH = cssBox.height) {
    canvasNode.setBox(cssBox);
    canvasNode.width = fbWidth;
    canvasNode.height = fbHeight;
    element.setBox(cssBox);
    element.offsetWidth = layoutW;
    element.offsetHeight = layoutH;
    input.setStreamResolution(fbWidth, fbHeight);
    input._windowMath();
}

const pad = () => ({
    left: px(element.style.paddingLeft), top: px(element.style.paddingTop),
    bottom: px(element.style.paddingBottom), font: px(element.style.fontSize),
});
const fmt = (p) => `${p.left},${p.top},${p.bottom},${p.font}`;

{
    layout(rect(0, 0, 1280, 720), 2560, 1440);
    input.setImeCaret({ x: 1000, y: 400, w: 2, h: 60 });
    const p = pad();
    check('a 2x frame caret lands at half its pixels, one caret-high line',
        near(p.left, 500) && near(p.top, 200) && near(p.bottom, 490) && near(p.font, 30), fmt(p));
    check('the content box is border-box so padding does not grow the overlay',
        element.style.boxSizing === 'border-box', element.style.boxSizing);
}

{
    // Wider than the frame's aspect: the stream is letterboxed 160px in.
    layout(rect(0, 0, 1600, 720), 2560, 1440);
    input.setImeCaret({ x: 1000, y: 400, w: 2, h: 60 });
    const p = pad();
    check('the letterbox offset is added', near(p.left, 660) && near(p.top, 200), fmt(p));
}

{
    // A CSS transform halves the box on screen; padding is in layout pixels.
    layout(rect(0, 0, 1280, 720), 2560, 1440, 2560, 1440);
    input.setImeCaret({ x: 1000, y: 400, w: 2, h: 60 });
    const p = pad();
    check('a transformed overlay converts to its layout box',
        near(p.left, 1000) && near(p.top, 400) && near(p.font, 60), fmt(p));
}

{
    layout(rect(0, 0, 1280, 720), 2560, 1440);
    input.setImeCaret({ x: 99999, y: 99999, w: 2, h: 60 });
    const p = pad();
    check('a caret past the edge is clamped inside the overlay',
        p.left <= 1278 && near(p.top, 690) && near(p.bottom, 0), fmt(p));
}

{
    layout(rect(0, 0, 1280, 720), 2560, 1440);
    input.setImeCaret({ x: 100, y: 100, w: 2, h: 60 });
    const before = fmt(pad());
    input.isComposing = true;
    input.setImeCaret({ x: 1000, y: 400, w: 2, h: 60 });
    check('a caret change mid-composition leaves the IME anchor in place', fmt(pad()) === before, fmt(pad()));
    input.isComposing = false;
    input._clearCompositionHostSoon();
    await new Promise((r) => setTimeout(r, 5));
    const p = pad();
    check('and is applied once the composition settles', near(p.left, 500) && near(p.top, 200), fmt(p));
}

{
    layout(rect(0, 0, 1280, 720), 2560, 1440);
    input.setImeCaret(null);
    input._noteImeClickCaret({ clientX: 300, clientY: 100 });
    const p = pad();
    check('without a server caret the last click stands in, one fallback line centred on it',
        near(p.left, 300) && near(p.top, 91) && near(p.font, 18), fmt(p));
    input.setImeCaret({ x: 1000, y: 400, w: 2, h: 60 });
    check('a server caret wins over the click', near(pad().left, 500), fmt(pad()));
    input._noteImeClickCaret({ clientX: 10, clientY: 10 });
    check('and a later click does not override it', near(pad().left, 500), fmt(pad()));
    input.setImeCaret(null);
    check('losing the server caret returns to the latest click', near(pad().left, 10), fmt(pad()));
}

{
    input._imeClickCaret = null;
    input.setImeCaret(null);
    check('with no caret at all the overlay keeps its stylesheet layout',
        element.style.paddingLeft === '' && element.style.boxSizing === '' && element.style.fontSize === '',
        JSON.stringify(element.style));
    input.setImeCaret({ x: 1, y: 2, w: 0, h: 0 });
    check('a zero-height caret is treated as none', element.style.paddingLeft === '');
}

process.exit(failed ? 1 : 0);
