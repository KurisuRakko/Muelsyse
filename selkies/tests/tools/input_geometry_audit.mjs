// CSS-to-remote input geometry: one mapping for every pointer path.
//
// Absolute mouse, touch, drag, relative motion and pointer lock all resolve a
// client point (or delta) against the same sink box, so the checks here are
// written against lib/input-geometry.js -- the shared rule -- and against the
// Input instance that uses it, driven by fabricated rectangles rather than a
// browser. What every check is really guarding is that the local
// `devicePixelRatio` is applied exactly once, by whoever sized the
// framebuffer, and never a second time on the way in: the remote pixels per
// CSS pixel are `framebuffer / CSS box`, measured, not inferred.
//
// Prints one PASS/FAIL line per check and exits non-zero if any failed.

let failed = 0;
function check(label, ok, detail = '') {
    if (!ok) failed++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  [input-geometry] ${label}  ${detail}`);
}
const near = (a, b, eps = 1e-6) => Math.abs(a - b) <= eps;

const rect = (left, top, width, height) => ({
    left, top, width, height, right: left + width, bottom: top + height,
    x: left, y: top,
});

// --- the pure rule -------------------------------------------------------

const { streamGeometryFromSink, mapClientToStream, mapRelativeToStream } =
    await import('../../addons/selkies-web-core/lib/input-geometry.js');

{
    // 1x: the framebuffer is the CSS box, so a click lands on itself.
    const g = streamGeometryFromSink(rect(0, 0, 1600, 900), 1600, 900, 'fill');
    const p = mapClientToStream(400, 225, g);
    check('a 1x stream maps a click to itself', near(p.x, 400) && near(p.y, 225),
        `${p.x},${p.y}`);
}

{
    // The five stops: the framebuffer is the CSS box times the pick, so the
    // scale is the pick itself -- whatever screen the browser is on.
    const stops = [[96, 1], [120, 1.25], [144, 1.5], [168, 1.75], [192, 2]];
    const got = stops.map(([, mult]) => {
        const g = streamGeometryFromSink(rect(0, 0, 1280, 720),
            1280 * mult, 720 * mult, 'fill');
        return mapClientToStream(640, 360, g).x;
    });
    check('each DPI stop scales the click by the pick itself',
        got.join() === [640, 800, 960, 1120, 1280].join(), got.join());
}

{
    // The same page at DPR 1 and DPR 2. Nothing here reads the ratio: the
    // framebuffer the server realized already carries it, so the two agree.
    const atDpr = (dpr) => {
        const g = streamGeometryFromSink(rect(0, 0, 1280, 720), 1280 * dpr, 720 * dpr, 'fill');
        // A device-pixel click is reported in CSS pixels by every browser.
        return mapClientToStream(320, 180, g);
    };
    const one = atDpr(1), two = atDpr(2);
    check('DPR 1 and DPR 2 differ only by the framebuffer the server realized',
        near(two.x, one.x * 2) && near(two.y, one.y * 2),
        `${one.x},${one.y} vs ${two.x},${two.y}`);
}

{
    // CSS scaling: the core asks for dpr/pick, so the box is larger than the
    // framebuffer and the scale falls below 1. Still measured, not inferred.
    const g = streamGeometryFromSink(rect(0, 0, 1280, 720), 640, 360, 'fill');
    const p = mapClientToStream(1280, 720, g);
    check('CSS scaling maps the far corner onto the far corner',
        near(p.x, 640) && near(p.y, 360), `${p.x},${p.y}`);
}

{
    // A manual resolution: the framebuffer is the operator's, the box is
    // whatever the window gives it, and the ratio is neither side's DPR.
    const g = streamGeometryFromSink(rect(0, 0, 1000, 562.5), 3840, 2160, 'fill');
    const p = mapClientToStream(500, 281.25, g);
    check('a manual resolution maps through its own framebuffer',
        near(p.x, 1920) && near(p.y, 1080), `${p.x},${p.y}`);
}

{
    // object-fit: contain on a wider box letterboxes left and right; the pad
    // is not part of the stream and must not shift the mapping.
    const g = streamGeometryFromSink(rect(0, 0, 2000, 900), 1600, 900, 'contain');
    check('a letterboxed box keeps the stream centered',
        near(g.boxLeft, 200) && near(g.boxW, 1600) && near(g.boxTop, 0),
        `${g.boxLeft},${g.boxTop},${g.boxW}x${g.boxH}`);
    const origin = mapClientToStream(200, 0, g);
    const corner = mapClientToStream(1800, 900, g);
    check('and maps its own corners, not the padding\'s',
        near(origin.x, 0) && near(corner.x, 1600), `${origin.x} .. ${corner.x}`);
}

{
    // A page whose box does not start at the viewport origin: a second display
    // window, or a dashboard-inset stream. The offset is the box's, not the
    // screen's, so the same client point reads the same remote pixel.
    const g = streamGeometryFromSink(rect(300, 120, 800, 450), 1600, 900, 'fill');
    const p = mapClientToStream(300, 120, g);
    const q = mapClientToStream(700, 345, g);
    check('a box offset inside the viewport maps from its own origin',
        near(p.x, 0) && near(p.y, 0) && near(q.x, 800) && near(q.y, 450),
        `${p.x},${p.y} .. ${q.x},${q.y}`);
}

{
    // Pointer lock and trackpad deltas cover the same ground as the absolute
    // coordinates they stand in for, so they carry the same scale.
    const g = streamGeometryFromSink(rect(0, 0, 1280, 720), 2560, 1440, 'fill');
    const d = mapRelativeToStream(10, -4, g);
    check('a locked-pointer delta scales like an absolute move',
        near(d.x, 20) && near(d.y, -8), `${d.x},${d.y}`);
    const a = mapClientToStream(10, 0, g), b = mapClientToStream(0, 0, g);
    check('and matches the absolute mapping it replaces',
        near(d.x, a.x - b.x), `${d.x} vs ${a.x - b.x}`);
}

{
    check('a zero-size box has no mapping',
        streamGeometryFromSink(rect(0, 0, 0, 0), 1600, 900, 'fill') === null);
    check('and neither has a framebuffer of no size',
        streamGeometryFromSink(rect(0, 0, 800, 600), 0, 0, 'fill') === null);
    check('a non-finite client point is refused',
        mapClientToStream(NaN, 0, streamGeometryFromSink(
            rect(0, 0, 800, 600), 800, 600, 'fill')) === null);
}

// --- the Input instance that uses it -------------------------------------

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

const element = new FakeNode('overlayInput', 'DIV');
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

/** The absolute-pointer path a mouse event takes, without the event plumbing. */
function mapAbsolute(clientX, clientY) {
    return input._applySinkCoordinates(
        clientX, clientY, document.getElementById('videoCanvas'),
        document.getElementById('stream'), 0, 0);
}

/** Points the fake DOM at one CSS box and one framebuffer. */
function layout(cssBox, fbWidth, fbHeight) {
    canvasNode.setBox(cssBox);
    canvasNode.width = fbWidth;
    canvasNode.height = fbHeight;
    element.setBox(cssBox);
    input.setStreamResolution(fbWidth, fbHeight);
}

{
    layout(rect(0, 0, 1280, 720), 2560, 1440);
    const box = input._streamBox();
    check('the Input reads the canvas buffer as the framebuffer',
        box && near(box.scaleX, 2) && near(box.scaleY, 2),
        box && `${box.scaleX},${box.scaleY}`);
    check('and its density matches the mapping, with no extra DPR',
        near(input._cursorDensity(), 2), input._cursorDensity());
}

{
    // A 24-remote-pixel hotspot on a 2x stream is 12 CSS pixels in; the cursor
    // image is scaled by the same density the pointer is mapped by.
    const density = input._cursorDensity();
    check('a cursor hotspot divides by that same density',
        near(24 / density, 12), 24 / density);
}

{
    // Absolute pointer, through the public path a mouse event takes.
    mapAbsolute(640, 360);
    check('an absolute click maps by the measured scale',
        input.x === 1280 && input.y === 720, `${input.x},${input.y}`);
    mapAbsolute(-50, -50);
    check('and a click outside the box is clamped into the framebuffer',
        input.x === 0 && input.y === 0, `${input.x},${input.y}`);
}

{
    // The touch path resolves the same point through the same box.
    input._calculateTouchCoordinates({ clientX: 640, clientY: 360, screenX: 0, screenY: 0 });
    check('a touch resolves to the same remote pixel as a click',
        input.x === 1280 && input.y === 720, `${input.x},${input.y}`);
}

{
    const scale = input._pointerScale();
    check('a relative/locked delta carries the same scale',
        near(scale.x, 2) && near(scale.y, 2), `${scale.x},${scale.y}`);
}

{
    // The local screen changing density must not move the mapping: the
    // framebuffer the server realized is what decides it.
    window.devicePixelRatio = 1;
    input._invalidateGeometry();
    const box = input._streamBox();
    check('moving the page to a 1x screen leaves the mapping alone',
        box && near(box.scaleX, 2), box && box.scaleX);
    window.devicePixelRatio = 2;
}

{
    // The five stops again, this time end to end: one CSS box, five
    // framebuffers, each click scaled by its own pick and nothing else.
    const got = [1, 1.25, 1.5, 1.75, 2].map((mult) => {
        layout(rect(0, 0, 1280, 720), 1280 * mult, 720 * mult);
        mapAbsolute(640, 360);
        return input.x;
    });
    check('every stop maps the center to its own framebuffer center',
        got.join() === [640, 800, 960, 1120, 1280].join(), got.join());
}

{
    // A manual resolution the browser letterboxes: the canvas box is the
    // stream's own aspect, so the offset comes off the box, not the window.
    layout(rect(160, 0, 960, 720), 1920, 1440);
    mapAbsolute(160, 0);
    const origin = `${input.x},${input.y}`;
    mapAbsolute(1120, 720);
    check('a letterboxed manual resolution maps corner to corner',
        origin === '0,0' && input.x === 1920 && input.y === 1440,
        `${origin} .. ${input.x},${input.y}`);
}

{
    // The canvas hidden behind a <video> sink: the box is measured on the
    // visible node, and the framebuffer is that node's intrinsic size.
    const videoNode = new FakeNode('videoStream', 'VIDEO');
    videoNode.videoWidth = 2560;
    videoNode.videoHeight = 1440;
    videoNode.style.objectFit = 'contain';
    videoNode.setBox(rect(0, 0, 1280, 720));
    nodes.set('videoStream', videoNode);
    canvasNode.setBox(rect(0, 0, 0, 0));
    input._invalidateGeometry();
    const box = input._streamBox();
    check('a hidden canvas hands the measurement to the visible video sink',
        box && near(box.scaleX, 2) && near(box.left, 0),
        box && `${box.scaleX} @ ${box.left}`);
    nodes.delete('videoStream');
}

console.log(`\n[input-geometry] ${failed ? 'FAILED' : 'OK'}`);
process.exit(failed ? 1 : 0);
