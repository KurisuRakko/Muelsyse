/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

// The density a display page streams at and the scale it publishes for its
// neighbours. `render_scale` is the only multiplier -- the framebuffer is the
// window's CSS size times it -- so both are pure functions of the page's own
// settings and the box it draws, checked here rather than through two browsers
// on two screens. A `window` stub stays in scope so a check can move its
// `devicePixelRatio` under the function and require the answer not to follow.
//
// Prints one PASS/FAIL line per check and exits non-zero if any failed.

globalThis.window = { devicePixelRatio: 2 };

const { streamDensity, publishedScale, autoScalingDpi, autoRenderScale,
        DPI_STOPS, DEFAULT_DPI, RENDER_SCALE_STOPS, DEFAULT_RENDER_SCALE,
        DEFAULT_STREAM_PIXEL_BUDGET, budgetedRenderScale, budgetedScalingDpi } = await import(
    '../../addons/selkies-web-core/lib/stream-density.js');

let failed = 0;

function check(label, ok, detail = '') {
    if (!ok) failed++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  [stream-density] ${label}  ${detail}`);
}

{
    // 1x is the default and the window's own size: framebuffer = CSS size.
    const unity = streamDensity({ renderScale: 1 });
    check('1x streams the window at its CSS size', unity === 1, unity);
}

{
    // The five stops are absolute multipliers of the CSS size, not of any
    // local density: 200% is two stream pixels per CSS pixel.
    const stops = RENDER_SCALE_STOPS.map((pct) =>
        streamDensity({ renderScale: pct / 100 }));
    check('the render scale is the absolute multiplier of the CSS size',
        stops.join() === '1,1.25,1.5,1.75,2', stops.join());
}

{
    // The whole point of the rule: the browser's own screen density is not an
    // input. Same arguments, three device pixel ratios, one answer.
    const at = (dpr, args) => { window.devicePixelRatio = dpr; return streamDensity(args); };
    const shapes = [{}, { renderScale: 1 }, { renderScale: 2 }, { renderScale: 1.5 },
                    { renderScale: 2, manual: true }, { manual: true }];
    const moved = shapes.filter((args) =>
        new Set([1, 2, 3.5].map((dpr) => at(dpr, args))).size !== 1);
    check('the same arguments return the same density at dpr 1, 2 and 3.5',
        moved.length === 0, moved.map((a) => JSON.stringify(a)).join(' '));
    window.devicePixelRatio = 2;
}

{
    // Anti-regression: the deleted HiDPI flag and the local density must not
    // come back as parameters of the density function.
    const params =
        (streamDensity.toString().match(/^[^(]*\(\s*(\{[^}]*\})/) || [])[1] || '';
    check('streamDensity takes no useCssScaling parameter',
        !/useCssScaling/.test(params), params);
    check('and no local density parameter',
        !/devicePixelRatio/i.test(params), params);
}

{
    // A manual resolution is the operator's framebuffer: density 1 whatever
    // the render scale says.
    const fixed = streamDensity({ renderScale: 2, manual: true });
    check('a manual resolution streams at density 1', fixed === 1, fixed);
    const bare = streamDensity({ manual: true });
    check('even when no render scale is given', bare === 1, bare);
}

{
    // Unusable scales fall back to 1 (the window's CSS size), never to the
    // old device pixel ratio.
    const got = [undefined, 0, -1, NaN, null, 'wide'].map(
        (renderScale) => streamDensity({ renderScale }));
    check('an unusable render scale falls back to 1x',
        got.every((value) => value === 1), got.join());
    const empty = streamDensity({});
    check('and an empty page streams at 1x', empty === 1, empty);
}

{
    // The other half of the decoupling: the desktop DPI is not an input
    // either, and neither is any other local scale a page might carry.
    const shaped = streamDensity(
        { renderScale: 1, scalingDpi: 192, localScale: 2 });
    const plain = streamDensity({ renderScale: 1 });
    check('the desktop DPI is not an input to the density at all',
        shaped === plain, `${shaped} vs ${plain}`);
}

{
    const scale = publishedScale({ stream: [3024, 1612], css: [1512, 806],
                                   realized: [3024, 1612], density: 1 });
    check('a box showing the realized stream publishes its ratio', scale === 2, scale);
}

{
    // The page asked for 1512x806 and the server realized it; the box is still
    // holding the 3024x1612 stream from before the resize.
    const scale = publishedScale({ stream: [3024, 1612], css: [1512, 806],
                                   realized: [1512, 806], density: 1 });
    check('a box still holding the previous stream publishes the density', scale === 1, scale);
}

{
    const scale = publishedScale({ stream: [1280, 720], css: [1512, 806],
                                   realized: null, density: 1 });
    check('so does a page with no layout yet', scale === 1, scale);
}

{
    const scale = publishedScale({ stream: null, css: [1512, 806],
                                   realized: [1512, 806], density: 2 });
    check('and one with nothing decoded yet', scale === 2, scale);
}

{
    const scale = publishedScale({ stream: [1280, 720], css: [1280, 900],
                                   realized: [1280, 720], density: 1 });
    check('a fitted box scales by its tighter dimension', scale === 1, scale);
}

{
    // A manual resolution the user scaled down: the ratio is not the density.
    const scale = publishedScale({ stream: [1280, 720], css: [2560, 1440],
                                   realized: [1280, 720], density: 2 });
    check('a stream scaled below its box publishes that ratio', scale === 0.5, scale);
}

{
    // The default pick is a constant: the browser's own screen density says
    // nothing about how large the remote desktop should draw its UI, and a
    // laptop moved to an external monitor must not silently re-pick for the user.
    const at = (dpr) => { window.devicePixelRatio = dpr; return autoScalingDpi(); };
    const derived = [1, 1.25, 1.5, 2, 3.5].map(at);
    check('the default pick ignores the local display scaling',
        new Set(derived).size === 1, derived.join());
    check('the default pick is DEFAULT_DPI', at(1) === DEFAULT_DPI, at(1));
    check('and DEFAULT_DPI is one of the stops',
        DPI_STOPS.includes(DEFAULT_DPI), DEFAULT_DPI);
    window.devicePixelRatio = 2;
}

{
    // 渲染倍率的默认值同样是常量，且必须落在自己的档位表里。
    check('the default render scale is DEFAULT_RENDER_SCALE',
        autoRenderScale() === DEFAULT_RENDER_SCALE, autoRenderScale());
    check('and DEFAULT_RENDER_SCALE is one of the render-scale stops',
        RENDER_SCALE_STOPS.includes(DEFAULT_RENDER_SCALE), DEFAULT_RENDER_SCALE);
    check('1x is offered, so the framebuffer can be the window itself',
        RENDER_SCALE_STOPS[0] === 100, RENDER_SCALE_STOPS.join());
    check('the desktop DPI defaults to unity, so the desktop keeps its own size',
        DEFAULT_DPI === 96, DEFAULT_DPI);
}

{
    // 像素预算：超出预算的渲染倍率按档往下降，DPI 同比例降档，逻辑桌面不变。
    const budget = DEFAULT_STREAM_PIXEL_BUDGET;
    const css = [2080, 1152];
    const capped = streamDensity({ renderScale: 1.75, css, budget });
    check('a framebuffer over the budget drops to the largest stop that fits',
        capped === 1.25, capped);
    check('and the capped framebuffer is within the budget',
        css[0] * capped * css[1] * capped <= budget, css[0] * capped * css[1] * capped);
    const dpi = budgetedScalingDpi(168, 1.75, capped);
    check('the desktop DPI drops by the same ratio, keeping the logical desktop',
        dpi === 120 && Math.abs(css[0] * capped / (dpi / 96) - css[0]) < 1e-9, dpi);
    check('a pick under the budget is left alone',
        streamDensity({ renderScale: 1.25, css, budget }) === 1.25
        && budgetedScalingDpi(120, 1.25, 1.25) === 120, '');
    check('a budget of 0 disables the cap',
        streamDensity({ renderScale: 1.75, css, budget: 0 }) === 1.75, '');
    check('without a measured box the pick is left alone',
        streamDensity({ renderScale: 1.75, budget }) === 1.75, '');
    check('the cap never goes below the window\'s own size',
        budgetedRenderScale(2, [3840, 2160], budget) === 1, budgetedRenderScale(2, [3840, 2160], budget));
    check('a manual resolution ignores the budget',
        streamDensity({ renderScale: 1.75, manual: true, css, budget }) === 1, '');
    const offStop = budgetedScalingDpi(144, 1.75, 1.25);
    check('an unpaired DPI snaps to the nearest stop the server accepts',
        DPI_STOPS.includes(offStop), offStop);
}

console.log(`\n[stream-density] ${failed ? 'FAILED' : 'OK'}`);
process.exit(failed ? 1 : 0);
