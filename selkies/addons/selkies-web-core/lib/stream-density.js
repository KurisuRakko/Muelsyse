/**
 * The density a display page streams at: stream pixels per CSS pixel.
 *
 * `render_scale` is the only multiplier. The framebuffer is the window's CSS
 * size times it, so 100% (1x) streams the window at its own size and 200% (2x)
 * streams twice the pixels per axis into the same box. The browser's
 * `devicePixelRatio` takes no part: a window has one CSS size on every screen,
 * so two pages streaming one session at one `render_scale` ask for the same
 * framebuffer whatever their screens are.
 *
 * 远端桌面 DPI（`scaling_dpi`）与这个倍率无关：它只决定会话合成器的输出 scale，
 * 也就是远端字体与图标的大小 —— 逻辑桌面尺寸是 `framebuffer / (scaling_dpi / 96)`。
 * 于是「用渲染倍率换清晰度、用桌面 DPI 换 UI 大小」各调各的，互不牵连。
 *
 * 手动分辨率是例外：那是操作员点名的 framebuffer，没有可供倍率去乘的东西，密度
 * 固定为 1。盒子以流的原始尺寸为基准绘制；它实际被缩放到多大，由盒子的 fit 与
 * `publishedScale` 的实测比值表达，不由这里表达。
 * 服务端给了像素预算（`stream_pixel_budget`）时，倍率会按 `budgetedRenderScale`
 * 降档，保证 framebuffer 不超过预算；桌面 DPI 同比例降档（`budgetedScalingDpi`），
 * 逻辑桌面尺寸不变。
 * @param {{renderScale: (number|undefined), manual: (boolean|undefined),
 *     css: (number[]|null|undefined), budget: (number|null|undefined)}} page
 *     `renderScale` 是渲染倍率，按倍数计（1 是 100%）；`manual` 是这个页面的
 *     分辨率是否由操作员指定；`css` 是流盒子的 CSS 尺寸，`budget` 是像素预算。
 * @returns {number}
 */
export function streamDensity({ renderScale, manual, css, budget }) {
    // 手动分辨率不受任何倍率影响：framebuffer 就是操作员要的那个数。
    if (manual) return 1;
    const scale = (Number.isFinite(renderScale) && renderScale > 0) ? renderScale : 1;
    return budgetedRenderScale(scale, css, budget);
}

/**
 * 服务端像素预算的默认值：2600×1440。
 *
 * 在 Intel UHD 630 上实测（隔离 KWin 加 pixelflux VAAPI，全屏 60 fps 浏览器动画）：
 * 3.7 MP 及以下稳定 59–61 fps，4.7 MP 中位 60、最低 46，5.6 MP 中位 47，7.3 MP（3640×2016）
 * 只有 23–25 fps。合成与编码都随像素面积变慢，与网络无关。
 */
export const DEFAULT_STREAM_PIXEL_BUDGET = 2600 * 1440;

/**
 * The render scale a page actually streams at under the server's pixel budget.
 *
 * The largest `RENDER_SCALE_STOPS` multiplier no higher than the page's pick
 * whose framebuffer (CSS size times it) fits `budget`, floored at 1x: below
 * the window's own size there is no stop to fall to, and the remote desktop
 * DPI has none to pair with it. Stops rather than an exact fit because the
 * desktop DPI follows the same ratio (`budgetedScalingDpi`) and its stops are
 * the same five multipliers, so the logical desktop keeps its size across the
 * cap. A missing size or a budget of 0 leaves the pick alone.
 * @param {number} renderScale The page's pick as a multiplier (1 is 100%).
 * @param {(number[]|null|undefined)} css The stream box's CSS `[width, height]`.
 * @param {(number|null|undefined)} budget Maximum framebuffer pixels; 0 or
 *     absent disables the cap.
 * @returns {number} A multiplier no higher than `renderScale`.
 */
export function budgetedRenderScale(renderScale, css, budget) {
    if (!(budget > 0) || !css || !(css[0] > 0) || !(css[1] > 0)) return renderScale;
    const fits = (scale) => (css[0] * scale) * (css[1] * scale) <= budget;
    if (fits(renderScale)) return renderScale;
    const lower = RENDER_SCALE_STOPS.map((pct) => pct / 100)
        .filter((scale) => scale < renderScale - 1e-9)
        .sort((x, y) => y - x);
    for (const scale of lower) {
        if (fits(scale)) return scale;
    }
    return Math.min(renderScale, 1);
}

/**
 * The desktop DPI to ask for when the pixel budget lowered the render scale.
 *
 * The logical desktop is `framebuffer / (dpi / 96)`, so the DPI moves by the
 * same ratio as the stream density to keep windows where they were; the result
 * is snapped to the nearest of `DPI_STOPS`, which the server's DPI setting
 * accepts, and is exact whenever the pick pairs a DPI stop with the same
 * render-scale stop.
 * @param {number} scalingDpi The page's desktop DPI pick.
 * @param {number} renderScale The page's render-scale pick as a multiplier.
 * @param {number} density The multiplier `streamDensity` settled on.
 * @returns {number} One of `DPI_STOPS`, or `scalingDpi` when nothing was capped.
 */
export function budgetedScalingDpi(scalingDpi, renderScale, density) {
    if (!(renderScale > 0) || Math.abs(density - renderScale) < 1e-9) return scalingDpi;
    const target = scalingDpi * density / renderScale;
    return DPI_STOPS.reduce((best, stop) =>
        (Math.abs(stop - target) < Math.abs(best - target) ? stop : best), DPI_STOPS[0]);
}

/** `scaling_dpi` 收敛成 5 档：96/120/144/168/192，对应 1x / 1.25x / 1.5x / 1.75x / 2x。 */
export const DPI_STOPS = [96, 120, 144, 168, 192];

/**
 * 新会话的远端桌面 DPI：96（1x），也就是远端桌面保持它本来的大小。
 *
 * 这个数只表示「把远端桌面的字体图标放大多少」，不参与 framebuffer 尺寸；请求的
 * framebuffer 由窗口 CSS 尺寸与渲染倍率决定。
 *
 * 两个 dashboard 各自声明同一个字面量，tests/unit/test_dpi_default_mirror.py
 * 比对三处是否一致。
 */
export const DEFAULT_DPI = 96;

/** `render_scale` 的 5 档，按百分比：100/125/150/175/200。 */
export const RENDER_SCALE_STOPS = [100, 125, 150, 175, 200];

/** 新会话的渲染倍率：100（1x），此时 framebuffer 就是窗口的 CSS 尺寸。 */
export const DEFAULT_RENDER_SCALE = 100;

/**
 * The default `scaling_dpi`.
 *
 * 恒为 `DEFAULT_DPI`：它是远端桌面的属性，浏览器所在屏幕的密度与窗口大小都
 * 不该改写它。
 * @returns {number} One of `DPI_STOPS`.
 */
export function autoScalingDpi() {
    return DEFAULT_DPI;
}

/**
 * The default `render_scale`.
 * @returns {number} One of `RENDER_SCALE_STOPS`.
 */
export function autoRenderScale() {
    return DEFAULT_RENDER_SCALE;
}

/**
 * The scale a page publishes with the layout: the remote pixels per CSS pixel
 * of the stream box it presents.
 *
 * Measured off that box, since a manual resolution or the pixel cap makes the
 * ratio something other than the density. Only while the box is showing the
 * stream the server realized, though: a box still holding the stream from
 * before a resize measures that one's ratio instead, and a neighbouring
 * display would take the answer for this page's density and stream at it. The
 * density the request was built with stands in until the two agree.
 * @param {{stream: (number[]|null), css: (number[]|null),
 *     realized: (number[]|null), density: number}} box Sink pixels, the CSS
 *     box drawing them, the size the server realized, and the density.
 * @returns {number}
 */
export function publishedScale({ stream, css, realized, density }) {
    if (!stream || !css || !realized || !(css[0] > 0) || !(css[1] > 0)) return density;
    if (stream[0] !== realized[0] || stream[1] !== realized[1]) return density;
    // The tighter dimension is the one a fitted box scales by.
    return Math.max(stream[0] / css[0], stream[1] / css[1]);
}
