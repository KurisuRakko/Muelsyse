/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

// What the client puts on the wire for wheel input under smooth scrolling. A `ws`
// delta must add up to the distance the `m2` click path sends for the same input
// (ten axis units a notch), signed like the DOM delta; a wheel notch is spread over
// frames while a trackpad's distance goes out on the next frame; at most one message
// leaves per frame, within the server's bound; and nothing is left scheduled once the
// distance is sent or dropped. With the setting off the click path is untouched.
//
// Prints one PASS/FAIL line per check and exits non-zero if any failed.

import { Input } from '../../addons/selkies-web-core/lib/input.js';

let failed = 0;

function check(label, ok, detail = '') {
    if (!ok) failed++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  [smooth-scroll] ${label}  ${detail}`);
}

// A frame clock the audit advances by hand.
let frameQueue = new Map();
let nextFrameId = 1;
globalThis.requestAnimationFrame = (cb) => { const id = nextFrameId++; frameQueue.set(id, cb); return id; };
globalThis.cancelAnimationFrame = (id) => { frameQueue.delete(id); };

/** Runs the scheduled frames `count` times, one display frame apart, from `start`. */
function runFrames(count, start = 1000, step = 1000 / 60) {
    for (let i = 0; i < count && frameQueue.size; i++) {
        const callbacks = [...frameQueue.values()];
        frameQueue.clear();
        for (const cb of callbacks) cb(start + i * step);
    }
}

function makeQueue() {
    const items = [];
    return {
        isEmpty: () => items.length === 0,
        dequeue: () => items.shift(),
        enqueue: (v) => items.push(v),
        size: () => items.length,
    };
}

/** An Input with only what the wheel paths touch, capturing what it would send. */
function makeInput(smooth = true) {
    frameQueue.clear();
    const input = Object.create(Input.prototype);
    input.sent = [];
    input.send = (msg) => input.sent.push(msg);
    input.buttonMask = 0;
    input._queue = makeQueue();
    input._allowTrackpadScrolling = true;
    input._allowThreshold = true;
    input._smallestDeltaY = 10000;
    input._smallestLineDeltaY = 10000;
    input._wheelThreshold = 100;
    input._scrollMagnitude = 10;
    input._wheelAccumY = 0;
    input._wheelDirY = null;
    input._wheelAccumX = 0;
    input._wheelDirX = null;
    input._lastWheelEventTs = 0;
    input.smoothScroll = smooth;
    input._smoothEaseX = 0;
    input._smoothEaseY = 0;
    input._smoothDirectX = 0;
    input._smoothDirectY = 0;
    input._smoothFrame = null;
    input._smoothFrameTs = null;
    return input;
}

function wheel(deltaY, deltaX = 0, deltaMode = 0) {
    return { deltaY, deltaX, deltaMode, preventDefault() {} };
}

/** The `ws` deltas in a captured wire sequence, as [dx, dy] pairs. */
function deltas(sent) {
    return sent.filter((m) => m.startsWith('ws,')).map((m) => m.slice(3).split(',').map(Number));
}

const sum = (pairs, axis) => pairs.reduce((a, p) => a + p[axis], 0);
const near = (a, b) => Math.abs(a - b) < 1e-6;

// A discrete wheel notch: ten units in all, spread over frames, most of it within 120 ms.
{
    const input = makeInput();
    input._allowThreshold = false;
    input._smoothWheel(wheel(100), true);
    runFrames(60);
    const d = deltas(input.sent);
    check('a wheel notch sends ten units', near(sum(d, 1), 10), JSON.stringify(d));
    check('a wheel notch is eased over several frames', d.length >= 5 && d[0][1] < 10, `${d.length} frames`);
    const by120 = d.slice(0, 7).reduce((a, p) => a + p[1], 0);
    check('most of a notch lands within 120 ms', by120 >= 9.5, by120.toFixed(2));
    check('the easing settles within 200 ms', d.length <= 12, `${d.length} frames`);
    check('the frame loop stops once settled', frameQueue.size === 0 && input._smoothFrame === null);
    check('every delta has at most two decimals',
          input.sent.every((m) => m.split(',').slice(1).every((v) => /^-?\d+(\.\d{1,2})?$/.test(v))),
          input.sent.join(' '));
}

// Directions follow the DOM delta, the convention the server's scroll clicks share.
{
    const input = makeInput();
    input._allowThreshold = false;
    input._smoothWheel(wheel(-3, 2, 1), true);
    runFrames(60);
    const d = deltas(input.sent);
    check('wheel up is negative dy', near(sum(d, 1), -10), sum(d, 1));
    check('wheel right is positive dx', near(sum(d, 0), 20), sum(d, 0));
}

// A trackpad's distance goes out whole on the next frame, one message for the events between.
{
    const input = makeInput();
    input._smoothWheel(wheel(34), false);
    input._smoothWheel(wheel(17), false);
    runFrames(1);
    const d = deltas(input.sent);
    check('trackpad events coalesce into one message per frame', d.length === 1, input.sent.join(' '));
    check('a trackpad sends the click path distance', d.length === 1 && near(d[0][1], 15), JSON.stringify(d));
    runFrames(5);
    check('a trackpad adds no easing tail', deltas(input.sent).length === 1);
}

// The same input through either path covers the same distance: ten units per notch
// the click path accumulates, its sub-notch remainder included.
{
    const gesture = [12, 30, 41, 27, 9, 5];
    const clicks = makeInput(false);
    const smooth = makeInput(true);
    for (const dy of gesture) {
        clicks._accumulateWheelY(wheel(dy));
        smooth._smoothWheel(wheel(dy), false);
    }
    runFrames(5);
    const units = sum(deltas(smooth.sent), 1);
    check('trackpad units are ten per click-path notch', Math.abs(units - 10 * clicks._wheelAccumY) < 0.01,
          `${units.toFixed(2)} vs ${(10 * clicks._wheelAccumY).toFixed(2)}`);
}

// One message is bounded by the server's clamp; the rest carries to later frames.
{
    const input = makeInput();
    input._smoothWheel(wheel(34 * 50), false);
    runFrames(10);
    const d = deltas(input.sent);
    check('an oversized frame is split at 200 units', d.map((p) => p[1]).join(',') === '200,200,100', JSON.stringify(d));
}

// A reversal drops what is still easing the other way.
{
    const input = makeInput();
    input._allowThreshold = false;
    input._smoothWheel(wheel(100), true);
    runFrames(1);
    input._smoothWheel(wheel(-100), true);
    runFrames(60);
    const d = deltas(input.sent);
    const after = d.slice(1);
    check('a reversal eases only the new direction', near(sum(after, 1), -10) && after.every((p) => p[1] <= 0),
          JSON.stringify(d));
}

// Clearing drops the pending distance and stops the loop.
{
    const input = makeInput();
    input._allowThreshold = false;
    input._smoothWheel(wheel(100), true);
    runFrames(1);
    const before = input.sent.length;
    input.clearPendingScroll();
    runFrames(60);
    check('clearing stops the frame loop', frameQueue.size === 0 && input.sent.length === before);
}

// Off, the wheel goes out as m2 clicks and nothing schedules a frame.
{
    const input = makeInput(false);
    input._mouseWheelWrapper(wheel(3, 0, 1));
    check('with smooth scroll off a line-mode notch sends m2 clicks',
          input.sent.length === 3 && input.sent.every((m) => m.startsWith('m2,')) && frameQueue.size === 0,
          input.sent.join(' '));
    input.setSmoothScroll(true);
    input._mouseWheelWrapper(wheel(3, 0, 1));
    runFrames(60);
    const d = deltas(input.sent);
    check('turned on, the same notch goes out as ws', near(sum(d, 1), 10) && input.sent.length === 3 + d.length,
          input.sent.slice(3).join(' '));
}

process.exit(failed ? 1 : 0);
