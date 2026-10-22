/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/**
 * 触摸手势用到的纯函数：滚动锁轴、像素到滚轮格的累加、抬手速度、惯性衰减、
 * 捏合缩放的视图变换。不读 window、DOM 或时钟，时间都由调用方传入，
 * 所以 `tests/tools/touch_gesture_audit.mjs` 能直接用数字驱动。
 *
 * @module
 */

/**
 * 按起步方向锁定滚动轴：一个方向明显占优就只滚那个方向，斜着滑的抖动
 * 不会变成另一轴的滚动；两者接近时两轴都滚（地图、表格）。
 * @param {number} dx 起步位移，CSS 像素
 * @param {number} dy
 * @param {number} ratio 占优倍数
 * @returns {'x'|'y'|'xy'}
 */
export function lockScrollAxis(dx, dy, ratio) {
    const ax = Math.abs(dx);
    const ay = Math.abs(dy);
    if (ay >= ax * ratio) return 'y';
    if (ax >= ay * ratio) return 'x';
    return 'xy';
}

/**
 * 把手指位移（CSS 像素）换算成整格滚轮，余数留到下一次。方向一变就清掉
 * 余数，否则反向的第一格会被上一方向剩下的小数吃掉。
 */
export class ScrollAccumulator {
    /** @param {number} pixelsPerNotch 一格对应的 CSS 像素 */
    constructor(pixelsPerNotch) {
        this.pixelsPerNotch = pixelsPerNotch;
        this.reset();
    }

    reset() {
        this.carry = 0;
        this.sign = 0;
    }

    /**
     * @param {number} pixels 本次位移，正负即方向
     * @returns {number} 本次应发的整格数，带符号
     */
    add(pixels) {
        if (!Number.isFinite(pixels) || pixels === 0) return 0;
        const sign = pixels > 0 ? 1 : -1;
        if (sign !== this.sign) {
            this.carry = 0;
            this.sign = sign;
        }
        this.carry += pixels / this.pixelsPerNotch;
        const notches = Math.trunc(this.carry);
        this.carry -= notches;
        return notches;
    }
}

/**
 * 用最近 `windowMs` 内的采样估计抬手速度（像素/毫秒）。采样跨度短于
 * `minSpanMs` 时返回 0：一批几乎同一时刻送达的 touchmove 会把整段位移除以
 * 一两毫秒，算出一个荒谬的甩动；结果再按 `maxSpeed` 限幅。
 * @param {Array<{t:number, x:number, y:number}>} samples 按时间递增
 * @param {number} now
 * @param {number} windowMs
 * @param {number} [minSpanMs=10]
 * @param {number} [maxSpeed=6]
 * @returns {{vx:number, vy:number}}
 */
export function releaseVelocity(samples, now, windowMs, minSpanMs = 10, maxSpeed = 6) {
    const recent = samples.filter((s) => now - s.t <= windowMs);
    if (recent.length < 2) return { vx: 0, vy: 0 };
    const first = recent[0];
    const last = recent[recent.length - 1];
    const dt = last.t - first.t;
    if (!(dt >= minSpanMs)) return { vx: 0, vy: 0 };
    const vx = (last.x - first.x) / dt;
    const vy = (last.y - first.y) / dt;
    const speed = Math.hypot(vx, vy);
    const k = speed > maxSpeed ? maxSpeed / speed : 1;
    return { vx: vx * k, vy: vy * k };
}

/**
 * 惯性滚动的一步：速度按时间常数 `tau` 指数衰减，返回这一步走过的距离。
 * 用衰减曲线的积分而不是 `v * dt`，帧间隔抖动时总距离不变。
 * @param {number} v 当前速度，像素/毫秒
 * @param {number} dt 距上一步的毫秒数
 * @param {number} tau 时间常数，毫秒
 * @returns {{distance:number, v:number}}
 */
export function inertiaStep(v, dt, tau) {
    const decay = Math.exp(-dt / tau);
    return { distance: v * tau * (1 - decay), v: v * decay };
}

/**
 * 捏合缩放：保持手势开始时两指中点下的那一点始终在两指中点下面，
 * 缩放限制在 [minScale, maxScale]，平移限制在画面始终铺满视口。
 * 变换以视口左上角为原点：屏幕点 = 内容点 * scale + t。
 * @param {{scale:number, tx:number, ty:number}} start 手势开始时的视图
 * @param {{x:number, y:number}} startCenter 开始时两指中点（视口坐标）
 * @param {number} startSpread 开始时两指距离
 * @param {{x:number, y:number}} center 当前两指中点
 * @param {number} spread 当前两指距离
 * @param {number} width 视口宽，CSS 像素
 * @param {number} height 视口高
 * @param {number} minScale
 * @param {number} maxScale
 * @returns {{scale:number, tx:number, ty:number}}
 */
export function pinchView(start, startCenter, startSpread, center, spread,
                          width, height, minScale, maxScale) {
    const ratio = startSpread > 0 && spread > 0 ? spread / startSpread : 1;
    const scale = Math.min(maxScale, Math.max(minScale, start.scale * ratio));
    const contentX = (startCenter.x - start.tx) / start.scale;
    const contentY = (startCenter.y - start.ty) / start.scale;
    return clampView({ scale, tx: center.x - contentX * scale, ty: center.y - contentY * scale },
        width, height);
}

/**
 * 把视图平移限制在画面铺满视口的范围内：放大后不会露出画面外的黑边。
 * @param {{scale:number, tx:number, ty:number}} view
 * @param {number} width
 * @param {number} height
 * @returns {{scale:number, tx:number, ty:number}}
 */
export function clampView(view, width, height) {
    const minTx = width - width * view.scale;
    const minTy = height - height * view.scale;
    return {
        scale: view.scale,
        tx: Math.min(0, Math.max(minTx, view.tx)),
        ty: Math.min(0, Math.max(minTy, view.ty)),
    };
}
