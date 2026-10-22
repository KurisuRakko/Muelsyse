/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/**
 * 触摸的本地可见反馈：点按涟漪、长按进度圈、拖动时手指下的圆点。
 *
 * 只画在页面上，不发任何消息给服务端。所有元素都是 `position: fixed`、
 * `pointer-events: none`，用触点的 client 坐标定位，所以不影响事件命中，
 * 也不随画面的捏合缩放变形。颜色取仪表盘主题的 `--accent` 系 token，
 * 没有仪表盘时退回同色值；`prefers-reduced-motion` 下涟漪不扩散、只闪一下。
 * 涟漪元素放在一个小池子里复用，快速连点不会一直创建节点。
 *
 * @module
 */

const STYLE_ID = 'selkies-touch-feedback-style';
const RIPPLE_POOL = 4;

const CSS = `
.stf-layer { position: fixed; left: 0; top: 0; width: 0; height: 0; z-index: 2147483000; pointer-events: none; }
.stf-dot, .stf-ripple, .stf-ring { position: fixed; left: 0; top: 0; pointer-events: none; border-radius: 50%; box-sizing: border-box; opacity: 0; }
.stf-ripple { width: 44px; height: 44px; margin: -22px 0 0 -22px; border: 2px solid var(--accent-strong, #f472b6);
  background: var(--accent-soft, rgba(236, 72, 153, 0.14)); box-shadow: 0 0 0 1px rgba(0, 0, 0, 0.35); }
.stf-ripple.stf-on { animation: stf-ripple 260ms ease-out forwards; }
.stf-ripple.stf-second { background: var(--accent-strong, #f472b6); }
@keyframes stf-ripple { from { opacity: 0.95; transform: scale(0.35); } to { opacity: 0; transform: scale(1); } }
.stf-dot { width: 18px; height: 18px; margin: -9px 0 0 -9px; background: var(--accent-strong, #f472b6);
  box-shadow: 0 0 0 2px rgba(255, 255, 255, 0.8), 0 0 0 3px rgba(0, 0, 0, 0.35); transition: opacity 120ms; }
.stf-dot.stf-on { opacity: 0.85; }
.stf-ring { width: 64px; height: 64px; margin: -32px 0 0 -32px; transition: opacity 120ms, transform 120ms;
  background: conic-gradient(var(--accent-strong, #f472b6) calc(var(--stf-p, 0) * 1turn), rgba(255, 255, 255, 0.28) 0);
  -webkit-mask: radial-gradient(circle, transparent 23px, #000 24px); mask: radial-gradient(circle, transparent 23px, #000 24px);
  filter: drop-shadow(0 0 1px rgba(0, 0, 0, 0.6)); transform: scale(0.8); }
.stf-ring.stf-on { opacity: 1; transform: scale(1); }
.stf-ring.stf-armed { transform: scale(1.12); }
@media (prefers-reduced-motion: reduce) {
  .stf-ripple.stf-on { animation: stf-flash 200ms linear forwards; }
  @keyframes stf-flash { from { opacity: 0.9; transform: none; } to { opacity: 0; transform: none; } }
}
`;

/**
 * 长按进度圈的句柄。
 * @typedef {Object} RingHandle
 * @property {function(number): void} progress 0 到 1
 * @property {function(): void} armed 圈满，等抬手或拖动
 * @property {function(): void} hide 收起
 */

/** 页面上的触摸反馈层；没有 `document` 的环境（测试）里所有方法都是空操作。 */
export class TouchFeedback {
    constructor() {
        this._layer = null;
        this._ripples = [];
        this._nextRipple = 0;
        this._dot = null;
        this._ring = null;
        this.enabled = true;
    }

    /** 首次用到时建层并注入样式，避免页面没有触摸也多出节点。 */
    _ensure() {
        if (this._layer) return true;
        if (typeof document === 'undefined' || !document.body
            || typeof document.createElement !== 'function') {
            return false;
        }
        if (typeof document.getElementById === 'function' && !document.getElementById(STYLE_ID)) {
            const style = document.createElement('style');
            style.id = STYLE_ID;
            style.textContent = CSS;
            (document.head || document.body).appendChild(style);
        }
        const make = (cls) => {
            const el = document.createElement('div');
            el.className = cls;
            return el;
        };
        this._layer = make('stf-layer');
        for (let i = 0; i < RIPPLE_POOL; i++) {
            const r = make('stf-ripple');
            if (typeof r.addEventListener === 'function') {
                r.addEventListener('animationend', () => { r.className = 'stf-ripple'; });
            }
            this._ripples.push(r);
            this._layer.appendChild(r);
        }
        this._dot = make('stf-dot');
        this._ring = make('stf-ring');
        this._layer.appendChild(this._dot);
        this._layer.appendChild(this._ring);
        document.body.appendChild(this._layer);
        return true;
    }

    static _place(el, x, y) {
        el.style.left = `${x}px`;
        el.style.top = `${y}px`;
    }

    /**
     * 点按涟漪。
     * @param {number} x client 坐标
     * @param {number} y
     * @param {boolean} [second=false] 双击的第二下，画实心以示区别
     */
    tap(x, y, second = false) {
        if (!this.enabled || !this._ensure()) return;
        const r = this._ripples[this._nextRipple];
        this._nextRipple = (this._nextRipple + 1) % this._ripples.length;
        TouchFeedback._place(r, x, y);
        r.className = 'stf-ripple';
        // 读一次布局让同一个节点的动画能重新开始。
        void r.offsetWidth;
        r.className = second ? 'stf-ripple stf-on stf-second' : 'stf-ripple stf-on';
    }

    /**
     * 拖动时手指下的圆点；`x` 为 null 时隐藏。
     * @param {?number} x
     * @param {number} [y]
     */
    dot(x, y) {
        if (!this._ensure()) return;
        if (x === null || !this.enabled) {
            this._dot.className = 'stf-dot';
            return;
        }
        TouchFeedback._place(this._dot, x, y);
        this._dot.className = 'stf-dot stf-on';
    }

    /**
     * 在触点显示长按进度圈。
     * @param {number} x
     * @param {number} y
     * @returns {RingHandle}
     */
    ring(x, y) {
        const noop = { progress() {}, armed() {}, hide() {} };
        if (!this.enabled || !this._ensure()) return noop;
        const ring = this._ring;
        TouchFeedback._place(ring, x, y);
        ring.style.setProperty('--stf-p', '0');
        ring.className = 'stf-ring stf-on';
        return {
            progress: (p) => ring.style.setProperty('--stf-p', String(Math.max(0, Math.min(1, p)))),
            armed: () => {
                ring.style.setProperty('--stf-p', '1');
                ring.className = 'stf-ring stf-on stf-armed';
            },
            hide: () => { ring.className = 'stf-ring'; },
        };
    }

    /** 收起所有持续显示的反馈（圈、圆点），涟漪自行淡出。 */
    clear() {
        if (!this._layer) return;
        this._dot.className = 'stf-dot';
        this._ring.className = 'stf-ring';
    }

    /** 移除反馈层。 */
    destroy() {
        if (this._layer && this._layer.parentNode) {
            this._layer.parentNode.removeChild(this._layer);
        }
        this._layer = null;
        this._ripples = [];
        this._dot = null;
        this._ring = null;
    }
}
