/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/**
 * The dashboard sidebar: every control the reference dashboard offers on top
 * of selkies-core, talking to the core through `window.postMessage` alone.
 *
 * Renders a draggable toggle handle, the core action buttons (video, audio,
 * microphone, webcam, gamepad), the soft modifier keys and virtual keyboard
 * button for touch clients, the collapsible video, screen, audio, stats,
 * clipboard, files, apps, sharing, gamepads and shortcuts sections, the
 * upload and clipboard notifications, the apps and files modals, and the
 * second-screen placement arrows.
 *
 * Messages it consumes from the core: `serverSettings` (the settings payload
 * that gates which controls render and seeds their values),
 * `pipelineStatusUpdate` and `sidebarButtonStatusUpdate`,
 * `effectiveCursorState`, `scalingDpiFollowed` (the desktop-DPI default the
 * core re-derived), `clientRoleUpdate`, `gamingModeUpdate`,
 * `toggleDashboard` and `toggleTouchGamepad` (the core-owned Ctrl+Shift+M and
 * Ctrl+Shift+G chords), `gamepadControl`, `clipboardContentUpdate`,
 * `audioDeviceSelected` (its own selection mirrored back, so the dropdowns
 * show what the core was told), `gamepadButtonUpdate` and
 * `gamepadAxisUpdate`, `fileUpload` (upload progress and every notification
 * the core raises), `trackpadModeUpdate` and `touchOptionsUpdate`.
 *
 * Messages it posts: `settings` (debounced), `pipelineControl`,
 * `gamepadControl`, `setManualResolution`, `resetResolutionToWindow`,
 * `setScaleLocally`, `setAntiAliasing`, `audioDeviceSelected`,
 * `clipboardUpdateFromUI`, `clipboardImageUpdate`, `requestFullscreen`,
 * `requestGamingMode`, `mode`, `setSynth`, `sidebarVisibilityChanged`, `TOUCH_GAMEPAD_SETUP`,
 * `TOUCH_GAMEPAD_VISIBILITY`, `touchinput:trackpad`, `touchinput:touch` and
 * `touchinput:options` (with no options it asks for `touchOptionsUpdate`),
 * plus whatever channel a conditional-settings spec propagates through. The
 * soft keys dispatch synthetic `KeyboardEvent`s on `window`, and the files
 * section dispatches the `requestFileUpload` DOM event.
 *
 * `window` state it reads: `system_stats`, `gpu_stats`, `fps`,
 * `currentAudioLevel`, `network_stats`, `webrtcInput.gamingMode`,
 * `__SELKIES_STREAMING_MODE__` and `__SELKIES_DUAL_MODE__`; it sets
 * `__selkiesModeSwitching` around a transport switch.
 *
 * Persistence: every setting lives in `localStorage` under
 * `<storageAppName>_<key>`, the keys in `PER_DISPLAY_SETTINGS` gaining a
 * `_display2` suffix on the `#display2` hash so a secondary display keeps its
 * own values; an explicit user choice of a derived setting writes a
 * `_explicit_choice` marker beside its value. The theme is stored unprefixed
 * because it is a per-browser preference.
 * @module
 */
import { useState, useEffect, useCallback, useMemo, useRef } from "react";
import brandWordmarkUrl from "../assets/rakko-wordmark.png";
import { displayLabel, decodableEncoders, canDecodeFullColor, getRoutePrefix, getStorageAppName, isMobileClient, isMacDesktop } from "../../../selkies-web-core/lib/util.js";
import { sessionAuthHeaders, withSessionToken } from "../../../selkies-web-core/lib/session-token.js";
import { resolveSpec, isSettingPinned, RATE_CONTROL_SPEC,
  USE_BROWSER_CURSORS_SPEC, VIDEO_FULLCOLOR_SPEC, VIDEO_STREAMING_MODE_SPEC,
  ADAPTIVE_FRAME_DROP_SPEC,
  USE_PAINT_OVER_QUALITY_SPEC, USE_CPU_SPEC, FORCE_ALIGNED_RESOLUTION_SPEC,
  RAW_POINTER_MOTION_SPEC, MAC_CMD_AS_CTRL_SPEC } from "../../../selkies-web-core/lib/conditional-settings.js";
import GamepadVisualizer from "./GamepadVisualizer";
import PlayerGamepadButton from "./PlayerGamepadButton.jsx";
import { getTranslator } from "../translations";
import {
  APP_COMMAND_STATE_EVENT,
  INSTALLED_APPS_ROLLBACK_EVENT,
  INSTALLED_APPS_SERVER_EVENT,
  applyServerInstalledApps,
  pendingAppAction,
  postAppCommand,
  readInstalledApps,
  resolveFailedAppCommand,
  writeInstalledApps,
} from "../../../selkies-web-core/lib/app-commands.js";
import * as yaml from "js-yaml";

const urlHash = window.location.hash;
const displayId = urlHash.startsWith('#display2') ? 'display2' : 'primary';

/**
 * Union of both streaming cores' `PER_DISPLAY_SETTINGS` lists, so the
 * dashboard and whichever core is running agree on which keys get the
 * `_display2` suffix. The websockets core alone owns `jpeg_quality` and
 * `paint_over_jpeg_quality` (JPEG is websockets framing); a key the running
 * core ignores is inert, while a missing one would make the secondary display
 * write the primary's key.
 */
const PER_DISPLAY_SETTINGS = [
    'framerate', 'video_crf', 'video_fullcolor',
    'video_streaming_mode', 'adaptive_frame_drop', 'jpeg_quality',
    'paint_over_jpeg_quality', 'use_cpu',
    'video_paintover_crf', 'video_paintover_burst_frames', 'use_paint_over_quality',
    'manual_resolution', 'manual_width', 'manual_height', 'encoder',
    'scaleLocallyManual', 'use_browser_cursors', 'rate_control_mode',
    'video_bitrate', 'force_aligned_resolution', 'scaling_dpi', 'render_scale'
];

const encoderOptions = [
  "h264enc",
  "h264enc-striped",
  "jpeg",
];

/**
 * WebRTC encoders offered before the server payload arrives; its `encoder`
 * allowed list is already filtered to what the WebRTC pipeline produces
 * (pixelflux emits H.264 only).
 */
const encoderOptionsWR = [
  "h264enc",
]

/** `webcam_encoder` values; labels come from `displayLabel`. */
const webcamEncoderOptions = ["auto", "h264", "vp8", "mjpeg"];

const rateControlOptions = ["cbr", "crf"];

const commonResolutionValues = [
  "",
  "1920x1080",
  "1280x720",
  "1366x768",
  "1920x1200",
  "2560x1440",
  "3840x2160",
  "1024x768",
  "800x600",
  "640x480",
  "320x240",
];

// 远端桌面 DPI 的 5 档：只决定远端桌面自己的大小（合成器输出 scale = dpi/96），
// 与 framebuffer 无关 —— 后者由窗口 CSS 尺寸与渲染倍率决定。两者互不相关。
const dpiScalingOptions = [
  { label: "1x", value: 96 },
  { label: "1.25x", value: 120 },
  { label: "1.5x", value: 144 },
  { label: "1.75x", value: 168 },
  { label: "2x", value: 192 },
];

/** 新会话的远端桌面 DPI：1x，即远端桌面保持原本大小。 */
const DEFAULT_DPI = 96;

// 渲染倍率的 5 档，按百分比：framebuffer = 窗口 CSS 尺寸 × 这个百分比。
const renderScaleOptions = [
  { label: "1x", value: 100 },
  { label: "1.25x", value: 125 },
  { label: "1.5x", value: 150 },
  { label: "1.75x", value: 175 },
  { label: "2x", value: 200 },
];

/** 新会话的渲染倍率：1x，此时 framebuffer 就是窗口的 CSS 尺寸。 */
const DEFAULT_RENDER_SCALE = 100;

/** 把任意来源的档位收敛到五个合法值之一，非法值退回 `fallback`。 */
const normalizeDpiChoice = (value, fallback = DEFAULT_DPI) => {
  const parsed = typeof value === "number" ? value : parseInt(String(value ?? ""), 10);
  return dpiScalingOptions.some((option) => option.value === parsed) ? parsed : fallback;
};

/** 同上，用于渲染倍率。 */
const normalizeRenderScale = (value, fallback = DEFAULT_RENDER_SCALE) => {
  const parsed = typeof value === "number" ? value : parseInt(String(value ?? ""), 10);
  return renderScaleOptions.some((option) => option.value === parsed) ? parsed : fallback;
};

const dpiPresetLabels = new Map([
  [96, "1x"],
  [120, "1.25x"],
  [144, "1.5x"],
  [168, "1.75x"],
  [192, "2x"],
]);

const formatDpiLabel = (dpiValue) => {
  const value = Number.parseInt(dpiValue, 10);
  return dpiPresetLabels.get(value) || `${Math.round((value / 96) * 100)}% (${value} DPI)`;
};

const renderScaleLabels = new Map([
  [100, "1x"],
  [125, "1.25x"],
  [150, "1.5x"],
  [175, "1.75x"],
  [200, "2x"],
]);

const formatRenderScaleLabel = (value) => {
  const parsed = Number.parseInt(value, 10);
  return renderScaleLabels.get(parsed) || `${parsed}%`;
};
/**
 * Browser language, resolved once: language, form factor and display density
 * are fixed for the life of the document, so resolving them at module scope
 * makes them available to the first render and a phone gets the mobile layout
 * without a repaint.
 */
const BROWSER_LANG_TAG =
  (typeof navigator !== "undefined" &&
    (navigator.language || navigator.userLanguage)) || "en";
const BROWSER_PRIMARY_LANG = BROWSER_LANG_TAG.split("-")[0].toLowerCase();

const STATS_READ_INTERVAL_MS = 500;
const DEFAULT_FRAMERATE = 60;
const DEFAULT_JPEG_QUALITY = 40;
const DEFAULT_PAINT_OVER_JPEG_QUALITY = 90;
const DEFAULT_USE_CPU = false;
const DEFAULT_H264_PAINTOVER_CRF = 18;
const DEFAULT_USE_PAINT_OVER_QUALITY = true;
const DEFAULT_ENCODER = encoderOptions[0];
const DEFAULT_VIDEO_CRF = 25;
const DEFAULT_SCALE_LOCALLY = true;
const DEFAULT_ENABLE_BINARY_CLIPBOARD = true;
const REPO_BASE_URL =
  "https://raw.githubusercontent.com/linuxserver/proot-apps/master/metadata/";
const METADATA_URL = `${REPO_BASE_URL}metadata.yml`;
const IMAGE_BASE_URL = `${REPO_BASE_URL}img/`;
const METADATA_FETCH_TIMEOUT_MS = 10000;

const MAX_NOTIFICATIONS = 3;
const NOTIFICATION_TIMEOUT_SUCCESS = 5000;
const NOTIFICATION_TIMEOUT_ERROR = 8000;
const NOTIFICATION_FADE_DURATION = 500;

const TOUCH_GAMEPAD_HOST_DIV_ID = "touch-gamepad-host";

const STREAM_MODE_WEBRTC = "webrtc";
const STREAM_MODE_WEBSOCKETS = "websockets";
const STREAMING_MODES= [STREAM_MODE_WEBSOCKETS, STREAM_MODE_WEBRTC]
const DEFAULT_STREAM_MODE = STREAM_MODE_WEBSOCKETS;
/** Audio bitrate default in bps, matching the server and the wish dashboard. */
const DEFAULT_AUDIO_BITRATE = 128000;
/**
 * Opus target bitrate stops mirroring the server's `audio_bitrate` allowed
 * enum (settings.py), used until `serverSettings` arrive; 510k is libopus's
 * hard maximum.
 */
const audioBitrateOptions = [32000, 48000, 64000, 96000, 128000, 192000, 256000, 320000, 384000, 510000];
/** Video bitrate default in kbps. */
const DEFAULT_VIDEO_BITRATE = 8000;
const RATE_CONTROL_CBR = "cbr";
const RATE_CONTROL_CRF = "crf";

/** Sub-Mbps CBR stops in kbps for constrained links, ahead of the 1000-kbps steps. */
const SUB_MBPS_BITRATE_STEPS = [100, 250, 500, 750];
/**
 * CBR stops above 100000 kbps: per-1000 granularity stops mattering there and
 * a 1000-position slider would be unusable.
 */
const COARSE_MBPS_BITRATE_STEPS = [150000, 200000, 300000, 400000, 500000, 750000, 1000000];


/**
 * Formats a byte count with a binary unit.
 * @param {number|null|undefined} bytes Byte count; empty or zero yields the zero label.
 * @param {number} [decimals=2] Fraction digits, clamped at zero.
 * @param {object} [rawDict] Translation table supplying `zeroBytes` and `byteUnits`.
 * @returns {string}
 */
function formatBytes(bytes, decimals = 2, rawDict) {
  const zeroBytesText = rawDict?.zeroBytes || "0 Bytes";
  if (bytes === null || bytes === undefined || bytes === 0)
    return zeroBytesText;
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = rawDict?.byteUnits || [
    "Bytes",
    "KB",
    "MB",
    "GB",
    "TB",
    "PB",
    "EB",
    "ZB",
    "YB",
  ];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  const unitIndex = Math.min(i, sizes.length - 1);
  return (
    parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + " " + sizes[unitIndex]
  );
}

/** Stroke dash offset that fills a gauge ring to `percentage` (clamped to 0 to 100). */
const calculateGaugeOffset = (percentage, radius, circumference) => {
  const clampedPercentage = Math.max(0, Math.min(100, percentage || 0));
  return circumference * (1 - clampedPercentage / 100);
};

/** Parses a dimension and rounds it down to an even number; non-numbers become 0. */
const roundDownToEven = (num) => {
  const n = parseInt(num, 10);
  if (isNaN(n)) return 0;
  return Math.floor(n / 2) * 2;
};

const CopyIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="16" height="16" style={{ display: 'block' }}>
    <path d="M16 1H4c-1.1 0-2 .9-2 2v14h2V3h12V1zm3 4H8c-1.1 0-2 .9-2 2v14c0 1.1.9 2 2 2h11c1.1 0 2-.9 2-2V7c0-1.1-.9-2-2-2zm0 16H8V7h11v14z"/>
  </svg>
);
/**
 * Crosshair marking gaming mode, the wish dashboard's icon for it: one glyph
 * names the control in both front ends and reads as a target, not a plus sign.
 * Drawn to the ink span of the fullscreen brackets beside it, which cover only
 * the middle of their box, so the header pair reads as one size.
 */
const GamingModeIcon = () => (
  <svg className="stroke-icon" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2" fill="none"
    width="22" height="22" strokeLinecap="round" strokeLinejoin="round">
    <circle cx="12" cy="12" r="6" />
    <path d="M18 12h-2.4M8.4 12H6M12 8.4V6M12 18v-2.4" />
  </svg>
);
const AppsIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20">
    <path d="M4 8h4V4H4v4zm6 12h4v-4h-4v4zm-6 0h4v-4H4v4zm0-6h4v-4H4v4zm6 0h4v-4h-4v4zm6-10v4h4V4h-4zm-6 4h4V4h-4v4zm6 6h4v-4h-4v4zm0 6h4v-4h-4v4z" />
  </svg>
);
/* Padded viewBox: the glyph inks its full box where its row neighbours ink
   about four fifths, and drawn as-is it reads as the larger tile. */
const KeyboardIcon = () => (
  <svg 
    xmlns="http://www.w3.org/2000/svg" 
    viewBox="-65 -65 620 620" 
    fill="currentColor" 
    width="24" 
    height="24"
  >
    <path d="M251.2 193.5v-53.7a10.5 10.5 0 0 1 10.5-10.5h119.4c21 0 38.1-17.1 38.1-38.1s-17.1-38.1-38.1-38.1H129.5c-5.4 0-10.1 4.3-10.1 10.1s4.3 10.1 10.1 10.1h251.6c10.1 0 17.9 8.2 17.9 17.9 0 10.1-8.2 17.9-17.9 17.9H261.7c-16.7 0-30.3 13.6-30.3 30.3v53.3H0v244.2h490V193.5H251.2zm-19 28h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.6-10.1 10.1-10.1zm-28.8 104.2h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.7 10.1-10.1 10.1zm10.1 27.2c0 5.4-4.3 10.1-10.1 10.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.7 10.1 10.1zM203.4 288h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.7 10.1-10.1 10.1zm-17.1-66.5h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.6-10.1 10.1-10.1zm-45.9 0H156c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.6-10.1 10.1-10.1zm-1.6 46.6h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.7-10.1 10.1-10.1zm0 37.4h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.3 10.1-10.1 10.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.5 4.7-10.1 10.1-10.1zm0 37.3h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.3 10.1-10.1 10.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.7-10.1 10.1-10.1zM94.5 221.5h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1H94.5c-5.4 0-10.1-4.3-10.1-10.1s4.7-10.1 10.1-10.1zm-5.1 46.6H105c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1H89.4c-5.4 0-10.1-4.3-10.1-10.1s4.7-10.1 10.1-10.1zm0 37.4H105c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.3 10.1-10.1 10.1H89.4c-5.4 0-10.1-4.3-10.1-10.1.4-5.5 4.7-10.1 10.1-10.1zm0 37.3H105c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.3 10.1-10.1 10.1H89.4c-5.4 0-10.1-4.3-10.1-10.1.4-5.4 4.7-10.1 10.1-10.1zM56 400.4H40.4c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1H56c5.4 0 10.1 4.3 10.1 10.1-.4 5.4-4.7 10.1-10.1 10.1zm0-37.4H40.4c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1H56c5.4 0 10.1 4.3 10.1 10.1-.4 5.5-4.7 10.1-10.1 10.1zm0-37.3H40.4c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1H56c5.4 0 10.1 4.3 10.1 10.1-.4 5.4-4.7 10.1-10.1 10.1zm0-37.7H40.4c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1H56c5.4 0 10.1 4.3 10.1 10.1S61.4 288 56 288zm0-46.7H40.4c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1H56c5.4 0 10.1 4.3 10.1 10.1s-4.7 10.1-10.1 10.1zm196.8 159.1H89.4c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h163.3c5.4 0 10.1 4.3 10.1 10.1.1 5.4-4.6 10.1-10 10.1zm0-37.4h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.5-4.7 10.1-10.1 10.1zm0-37.3h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.7 10.1-10.1 10.1zm0-37.7h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.7 10.1-10.1 10.1zm49.4 112.4h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1-.4 5.4-4.7 10.1-10.1 10.1zm0-37.4h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1-.4 5.5-4.7 10.1-10.1 10.1zm0-37.3h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1-.4 5.4-4.7 10.1-10.1 10.1zm0-37.7h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.7 10.1-10.1 10.1zm10.1-46.7h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.7 10.1-10.1 10.1zm38.9 159.1h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.7 10.1-10.1 10.1zm0-37.4h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.5-4.7 10.1-10.1 10.1zm0-37.3h-15.6c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.7 10.1-10.1 10.1zm0-37.7h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.7 10.1-10.1 10.1zm6.6-46.7h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1zm42.8 159.1H385c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1-.4 5.4-4.7 10.1-10.1 10.1zm0-37.4H385c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1-.4 5.5-4.7 10.1-10.1 10.1zm0-37.3H385c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1-.4 5.4-4.7 10.1-10.1 10.1zm0-37.7H385c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1S406 288 400.6 288zm3.1-46.7h-15.6c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.3 10.1-10.1 10.1zm45.9 159.1H434c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.7 10.1-10.1 10.1zm0-37.4H434c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.5-4.7 10.1-10.1 10.1zm0-37.3H434c-5.4 0-10.1-4.3-10.1-10.1 0-5.4 4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1 0 5.4-4.7 10.1-10.1 10.1zm0-37.7H434c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1S455 288 449.6 288zm0-46.7H434c-5.4 0-10.1-4.3-10.1-10.1s4.3-10.1 10.1-10.1h15.6c5.4 0 10.1 4.3 10.1 10.1s-4.7 10.1-10.1 10.1z" />
  </svg>
);
/* Padded viewBox: this glyph inks the full 24 units where its neighbours in the
   row ink about 19, and drawn at the same size it reads as the larger button. */
const ScreenIcon = () => (
  <svg viewBox="-3 -3 30 30" fill="currentColor" width="20" height="20">
    <path d="M20 18c1.1 0 1.99-.9 1.99-2L22 6c0-1.1-.9-2-2-2H4c-1.1 0-2 .9-2 2v10c0 1.1.9 2 2 2H0v2h24v-2h-4zM4 6h16v10H4V6z" />
  </svg>
);
const SpeakerIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20">
    <path d="M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z" />
  </svg>
);
const MicrophoneIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20">
    <path d="M12 14c1.66 0 2.99-1.34 2.99-3L15 5c0-1.66-1.34-3-3-3S9 3.34 9 5v6c0 1.66 1.34 3 3 3zm5.3-3c0 3-2.54 5.1-5.3 5.1S6.7 14 6.7 11H5c0 3.41 2.72 6.23 6 6.72V21h2v-3.28c3.28-.48 6-3.3 6-6.72h-1.7z" />
  </svg>
);
const WebcamIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20">
    <path d="M17 10.5V7a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-3.5l4 4v-11l-4 4z" />
  </svg>
);
const GamepadIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="20" height="20">
    <path d="M15 7.5V2H9v5.5l3 3 3-3zM7.5 9H2v6h5.5l3-3-3-3zM9 16.5V22h6v-5.5l-3-3-3 3zM16.5 9l-3 3 3 3H22V9h-5.5z" />
  </svg>
);
const TrackpadIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="18" height="18">
    <path d="M3 5C3 3.89543 3.89543 3 5 3H19C20.1046 3 21 3.89543 21 5V15H3V5Z"/>
    <path d="M3 16H11V21H5C3.89543 21 3 20.1046 3 19V16Z"/>
    <path d="M13 16H21V19C21 20.1046 20.1046 21 19 21H13V16Z"/>
  </svg>
);
const FullscreenIcon = () => (
  <svg viewBox="0 0 24 24" fill="currentColor" width="22" height="22">
    <path d="M7 14H5v5h5v-2H7v-3zm-2-4h2V7h3V5H5v5zm12 7h-3v2h5v-5h-2v3zM14 5v2h3v3h2V5h-5z" />
  </svg>
);
const CaretDownIcon = () => (
  <svg
    viewBox="0 0 24 24"
    fill="currentColor"
    width="18"
    height="18"
    style={{ display: "block" }}
  >
    <path d="M7 10l5 5 5-5H7z" />
  </svg>
);
const CaretUpIcon = () => (
  <svg
    viewBox="0 0 24 24"
    fill="currentColor"
    width="18"
    height="18"
    style={{ display: "block" }}
  >
    <path d="M7 14l5-5 5 5H7z" />
  </svg>
);
const SpinnerIcon = () => (
  <svg
    width="18"
    height="18"
    viewBox="0 0 38 38"
    xmlns="http://www.w3.org/2000/svg"
    stroke="currentColor"
  >
    <g fill="none" fillRule="evenodd">
      <g transform="translate(1 1)" strokeWidth="3">
        <circle strokeOpacity=".3" cx="18" cy="18" r="18" />
        <path d="M36 18c0-9.94-8.06-18-18-18">
          <animateTransform
            attributeName="transform"
            type="rotate"
            from="0 18 18"
            to="360 18 18"
            dur="0.8s"
            repeatCount="indefinite"
          />
        </path>
      </g>
    </g>
  </svg>
);
/**
 * Session cache of the fetched proot-apps catalog: AppsModal is conditionally
 * mounted, so each open is a fresh mount, and a hit here skips the network.
 */
let cachedAppData = null;

/**
 * Audio level of the WebRTC stream's audio track through a dashboard-owned
 * AnalyserNode, never routed to a destination so playback is unaffected. The
 * websockets worklet path exposes `window.currentAudioLevel` instead.
 * @param {{current: object|null}} meterRef Ref holding the analyser, rebuilt when the stream changes.
 * @returns {number|null} RMS in 0 to 1, or `null` without an audio track.
 */
function readStreamAudioLevel(meterRef) {
  const el = document.getElementById("stream");
  const ms = el && el.srcObject;
  if (!ms || typeof ms.getAudioTracks !== "function" || ms.getAudioTracks().length === 0) {
    return null;
  }
  let m = meterRef.current;
  if (!m || m.stream !== ms) {
    try {
      if (m && m.ctx) m.ctx.close();
      const Ctx = window.AudioContext || window.webkitAudioContext;
      const ctx = new Ctx();
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 512;
      ctx.createMediaStreamSource(ms).connect(analyser);
      m = { ctx, analyser, data: new Uint8Array(analyser.fftSize), stream: ms };
      meterRef.current = m;
    } catch {
      return null;
    }
  }
  m.analyser.getByteTimeDomainData(m.data);
  let sum = 0;
  for (let i = 0; i < m.data.length; i++) {
    const v = (m.data[i] - 128) / 128;
    sum += v * v;
  }
  return Math.sqrt(sum / m.data.length);
}

/**
 * Catalog of proot-apps with install, remove, update and launch actions,
 * posted as app commands through app-commands.js.
 * @param {object} props
 * @param {boolean} props.isOpen Renders nothing while false.
 * @param {() => void} props.onClose
 * @param {Function} props.t Translator.
 * @param {boolean} props.commandsAvailable Whether the server accepts remote commands; actions are disabled otherwise.
 * @param {boolean} props.commandsKnown Whether `serverSettings` have arrived, so the disabled notice is only shown once known.
 * @param {string[]|undefined} props.installedFromServer App names the runner reports installed; the stored list is only a cache of it.
 */
function AppsModal({ isOpen, onClose, t, commandsAvailable, commandsKnown,
                    installedFromServer }) {
  const [appData, setAppData] = useState(cachedAppData);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState(null);
  const [fetchAttempt, setFetchAttempt] = useState(0);
  const [searchTerm, setSearchTerm] = useState("");
  const [selectedApp, setSelectedApp] = useState(null);
  const [installedApps, setInstalledApps] = useState(readInstalledApps);
  const [commandTick, setCommandTick] = useState(0);

  useEffect(() => {
    writeInstalledApps(installedApps);
  }, [installedApps]);

  /* The running set lives in app-commands.js; this only re-reads it. */
  useEffect(() => {
    const onCommandState = () => setCommandTick((tick) => tick + 1);
    window.addEventListener(APP_COMMAND_STATE_EVENT, onCommandState);
    return () =>
      window.removeEventListener(APP_COMMAND_STATE_EVENT, onCommandState);
  }, []);

  /* The runner's answer replaces what this browser remembered, which a private
     window or cleared site data leaves empty while the session has apps. */
  useEffect(() => {
    const adopt = (apps) => {
      if (applyServerInstalledApps(apps)) setInstalledApps(readInstalledApps());
    };
    adopt(installedFromServer);
    const onServerList = (event) => setInstalledApps(event.detail?.apps || []);
    const onWindowMessage = (event) => {
      if (event.origin !== window.location.origin) return;
      const message = event.data;
      if (typeof message !== "object" || message === null) return;
      if (message.type === "appsInstalled") adopt(message.apps);
    };
    window.addEventListener(INSTALLED_APPS_SERVER_EVENT, onServerList);
    window.addEventListener("message", onWindowMessage);
    return () => {
      window.removeEventListener(INSTALLED_APPS_SERVER_EVENT, onServerList);
      window.removeEventListener("message", onWindowMessage);
    };
  }, [installedFromServer]);

  /**
   * A failed install or remove already rolled the stored list back; mirror
   * it into this mounted list so the badge flips without a remount.
   */
  useEffect(() => {
    const onRollback = (event) => {
      const { app, action } = event.detail || {};
      if (action === "install")
        setInstalledApps((prev) => prev.filter((name) => name !== app));
      else if (action === "remove")
        setInstalledApps((prev) =>
          prev.includes(app) ? prev : [...prev, app]
        );
    };
    window.addEventListener(INSTALLED_APPS_ROLLBACK_EVENT, onRollback);
    return () =>
      window.removeEventListener(INSTALLED_APPS_ROLLBACK_EVENT, onRollback);
  }, []);

  /**
   * Catalog fetch: one attempt per modal open plus explicit Retry bumps of
   * `fetchAttempt`; a failure settles into the error view rather than
   * refetching. The fetch is aborted after a timeout and on close or unmount,
   * and the cleanup's `active` flag suppresses any late setState. The loading
   * flag is state set here rather than derived during render: it marks the
   * transition into a fetch, which a Retry has to re-enter.
   */
  useEffect(() => {
    if (!isOpen || appData) return;
    const controller = new AbortController();
    const timeoutId = window.setTimeout(
      () => controller.abort(),
      METADATA_FETCH_TIMEOUT_MS
    );
    let active = true;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setIsLoading(true);
    setError(null);
    (async () => {
      try {
        const response = await fetch(METADATA_URL, {
          signal: controller.signal,
        });
        if (!response.ok) {
          throw new Error(`HTTP error! status: ${response.status}`);
        }
        const yamlText = await response.text();
        const parsedData = yaml.load(yamlText);
        if (!active) return;
        cachedAppData = parsedData;
        setAppData(parsedData);
      } catch (e) {
        if (!active) return;
        console.error("Failed to fetch or parse app data:", e);
        setError(
          t(
            "appsModal.errorLoading",
            "Failed to load app data. Please try again."
          )
        );
      } finally {
        clearTimeout(timeoutId);
        if (active) setIsLoading(false);
      }
    })();
    return () => {
      active = false;
      clearTimeout(timeoutId);
      controller.abort();
    };
  }, [isOpen, appData, fetchAttempt, t]);

  const handleSearchChange = (event) =>
    setSearchTerm(event.target.value.toLowerCase());
  const handleAppClick = (app) => setSelectedApp(app);
  const handleBackToGrid = () => setSelectedApp(null);

  /**
   * The apps command contract both dashboards share: app-commands.js posts
   * the selkies-proot wrapper commands and tracks them for rollback, and the
   * installed list is updated optimistically.
   */
  const handleInstall = (appName) => {
    if (!commandsAvailable) return;
    postAppCommand("install", appName);
    setInstalledApps((prev) =>
      prev.includes(appName) ? prev : [...prev, appName]
    );
  };
  const handleRemove = (appName) => {
    if (!commandsAvailable) return;
    postAppCommand("remove", appName);
    setInstalledApps((prev) => prev.filter((name) => name !== appName));
  };
  const handleUpdate = (appName) => {
    if (!commandsAvailable) return;
    postAppCommand("update", appName);
  };
  const handleLaunch = (appName) => {
    if (!commandsAvailable) return;
    postAppCommand("launch", appName);
  };

  const filteredApps =
    appData?.include?.filter(
      (app) =>
        !app.disabled &&
        (app.full_name?.toLowerCase().includes(searchTerm) ||
          app.name?.toLowerCase().includes(searchTerm) ||
          app.description?.toLowerCase().includes(searchTerm))
    ) || [];
  const isAppInstalled = (appName) => installedApps.includes(appName);

  if (!isOpen) return null;

  return (
    <div className="apps-modal">
      <button
        className="apps-modal-close"
        onClick={onClose}
        aria-label={t("appsModal.closeAlt", "Close apps modal")}
      >
        &times;
      </button>
      <div className="apps-modal-content">
        {commandsKnown && !commandsAvailable && (
          <div className="apps-modal-notice">
            <p>
              {t(
                "appsModal.commandsDisabled",
                "App installation is unavailable: this session has remote commands disabled (the server's SELKIES_COMMAND_ENABLED setting)."
              )}
            </p>
          </div>
        )}
        {isLoading && (
          <div className="apps-modal-loading">
            <SpinnerIcon />
            <p>{t("appsModal.loading", "Loading apps...")}</p>
          </div>
        )}
        {error && (
          <div className="apps-modal-error">
            <p>{error}</p>
            <button
              onClick={() => setFetchAttempt((n) => n + 1)}
              className="app-action-button install"
            >
              {t("appsModal.retryButton", "Retry")}
            </button>
          </div>
        )}
        {!isLoading && !error && appData && (
          <>
            {selectedApp ? (
              <div className="app-detail-view">
                <button
                  onClick={handleBackToGrid}
                  className="app-detail-back-button"
                >
                  &larr; {t("appsModal.backButton", "Back to list")}
                </button>
                <img
                  src={`${IMAGE_BASE_URL}${selectedApp.icon}`}
                  alt={selectedApp.full_name}
                  className="app-detail-icon"
                  onError={(e) => {
                    e.target.style.display = "none";
                  }}
                />
                <h2>{selectedApp.full_name}</h2>
                <p className="app-detail-description">
                  {selectedApp.description}
                </p>
                <div className="app-action-buttons">
                  {(() => {
                    const running =
                      commandTick >= 0 && pendingAppAction(selectedApp.name);
                    const held = !commandsAvailable || !!running;
                    const mark = (action) =>
                      `app-action-button ${action}${running === action ? " running" : ""}`;
                    return isAppInstalled(selectedApp.name) ? (
                    <>
                      <button
                        onClick={() => handleLaunch(selectedApp.name)}
                        disabled={held}
                        className={mark("install")}
                      >
                        {t("appsModal.launchButton", "Launch")}{" "}
                        {selectedApp.name}
                      </button>
                      <button
                        onClick={() => handleUpdate(selectedApp.name)}
                        disabled={held}
                        className={mark("update")}
                      >
                        {t("appsModal.updateButton", "Update")}{" "}
                        {selectedApp.name}
                      </button>
                      <button
                        onClick={() => handleRemove(selectedApp.name)}
                        disabled={held}
                        className={mark("remove")}
                      >
                        {t("appsModal.removeButton", "Remove")}{" "}
                        {selectedApp.name}
                      </button>
                    </>
                    ) : (
                      <button
                        onClick={() => handleInstall(selectedApp.name)}
                        disabled={held}
                        className={mark("install")}
                      >
                        {t("appsModal.installButton", "Install")}{" "}
                        {selectedApp.name}
                      </button>
                    );
                  })()}
                </div>
              </div>
            ) : (
              <>
                <input
                  type="text"
                  className="apps-search-bar allow-native-input"
                  placeholder={t(
                    "appsModal.searchPlaceholder",
                    "Search apps..."
                  )}
                  value={searchTerm}
                  onChange={handleSearchChange}
                />
                <div className="apps-grid">
                  {filteredApps.length > 0 ? (
                    filteredApps.map((app) => (
                      <div
                        key={app.name}
                        className="app-card"
                        onClick={() => handleAppClick(app)}
                      >
                        <img
                          src={`${IMAGE_BASE_URL}${app.icon}`}
                          alt={app.full_name}
                          className="app-card-icon"
                          loading="lazy"
                          onError={(e) => {
                            e.target.style.visibility = "hidden";
                          }}
                        />
                        <p className="app-card-name">{app.full_name}</p>
                        {isAppInstalled(app.name) && (
                          <div className="app-card-installed-badge">
                            {t("appsModal.installedBadge", "Installed")}
                          </div>
                        )}
                      </div>
                    ))
                  ) : (
                    <p>
                      {t(
                        "appsModal.noAppsFound",
                        "No apps found matching your search."
                      )}
                    </p>
                  )}
                </div>
              </>
            )}
          </>
        )}
      </div>
    </div>
  );
}

const storageAppName = getStorageAppName();
/**
 * The localStorage key for a setting: the session prefix, plus the
 * `_display2` suffix for per-display settings on the secondary display.
 * @param {string} key
 * @returns {string}
 */
const getPrefixedKey = (key) => {
  const prefixedKey = `${storageAppName}_${key}`;
  if (displayId === 'display2' && PER_DISPLAY_SETTINGS.includes(key)) {
    return `${prefixedKey}_display2`;
  }
  return prefixedKey;
};

/** Reads a setting's stored value under its prefixed key. */
const readStored = (key) => localStorage.getItem(getPrefixedKey(key));

/**
 * Whether a manual resolution is in force, resolved exactly as
 * `conditionalCtx.manualActive` does. Written as a free function so an effect
 * can read it from the server payload alone, without taking the whole
 * conditional context as a dependency.
 * @param {Object|null} serverSettings
 * @returns {boolean}
 */
const manualResolutionActive = (serverSettings) =>
  !!readStored("manual_width") || serverSettings?.manual_resolution?.value === true;

/**
 * Marker written beside a value the user chose explicitly. The cores persist
 * every value they are told to apply, so the stored key alone cannot tell a
 * user's pick from one the dashboard derived (rate control from the encoder,
 * paint-over from the rate control in force); the settings that are also
 * derived read storage through `readExplicitStored`, so a derived write never
 * pins them.
 */
const EXPLICIT_CHOICE_SUFFIX = "_explicit_choice";
/**
 * The marker key, suffixed onto the already-prefixed value key so it inherits
 * the per-display suffix and a secondary display keeps its own choice.
 */
const explicitChoiceKey = (spec) => `${getPrefixedKey(spec.storageKey)}${EXPLICIT_CHOICE_SUFFIX}`;
const isExplicitChoice = (spec) => localStorage.getItem(explicitChoiceKey(spec)) === "true";
/** A storage reader for a spec that returns the stored value only when it was an explicit choice. */
const readExplicitStored = (spec) => (key) => (isExplicitChoice(spec) ? readStored(key) : null);
const readRateControlStored = readExplicitStored(RATE_CONTROL_SPEC);
const readPaintOverStored = readExplicitStored(USE_PAINT_OVER_QUALITY_SPEC);

/**
 * Drives a conditional setting: lazy init, then a re-resolve whenever the
 * server settings or any dependency in `deps` changes, which covers the
 * server sync and the encoder or manual-resolution re-derivation uniformly.
 * The resolver honors explicit choices, so a re-resolve never clobbers a
 * pinned value. A re-resolve writes state rather than deriving during render
 * because the caller edits the value afterwards; deriving would discard that.
 * @param {object} spec A spec from conditional-settings.js.
 * @param {object|null} serverSettings The last `serverSettings` payload.
 * @param {object} ctx Resolution context the spec reads.
 * @param {Array} deps Values whose change triggers a re-resolve.
 * @param {(key: string) => string|null} [read=readStored] Storage reader.
 * @returns {[any, Function]} The value and its setter, as `useState` returns them.
 */
function useConditionalSetting(spec, serverSettings, ctx, deps, read = readStored) {
  const compute = () => resolveSpec(spec, serverSettings, ctx, read);
  const [value, setValue] = useState(compute);
  // eslint-disable-next-line react-hooks/exhaustive-deps, react-hooks/set-state-in-effect
  useEffect(() => { setValue(compute()); }, deps);
  return [value, setValue];
}

/** Height of `.toggle-handle` in Overlay.css; keep the two in sync. */
const TOGGLE_HANDLE_HEIGHT_PX = 60;
/**
 * Clamps the toggle handle's vertical position, a percentage of the viewport
 * height, so the handle stays fully inside the viewport. The handle's inline
 * `top` positions its center (Overlay.css keeps the `translateY(-50%)`), so
 * the clamp is by half the handle height. Without a finite viewport height
 * (headless, pre-layout) that half would be Infinity, so the clamp is a plain
 * 0 to 100 until a real height is known; a handle at least as tall as the
 * viewport inverts the bounds, so it is centered instead of pinned to an edge.
 * @param {number} pct
 * @returns {number}
 */
const clampToggleHandleTopPct = (pct) => {
  const safePct = Number.isFinite(pct) ? pct : 50;
  const vh = window.innerHeight;
  if (!vh || !Number.isFinite(vh)) return Math.min(100, Math.max(0, safePct));
  const halfHandlePct = (TOGGLE_HANDLE_HEIGHT_PX / 2 / vh) * 100;
  if (halfHandlePct >= 50) return 50;
  return Math.min(100 - halfHandlePct, Math.max(halfHandlePct, safePct));
};

/**
 * The sidebar component; see the module docblock for the message and storage
 * contract it implements. Renders nothing when the server hides the sidebar
 * (`ui_show_sidebar`), and viewer-role clients get no toggle handle.
 */
function Sidebar() {
  const [isOpen, setIsOpen] = useState(false);
  const [isToggleVisible, setIsToggleVisible] = useState(true);
  /**
   * Gaming mode: the fullscreen that holds the pointer and keyboard, announced
   * by the core however it was entered. Plain fullscreen keeps the dashboard
   * reachable, so only this one hides the toggle.
   */
  const [isGamingMode, setIsGamingMode] = useState(false);
  /**
   * Viewer-designated clients (shared/player URL modes, or a server-assigned
   * viewer role) get no server-wide controls such as the transport switch,
   * and no keyboard pop: whether the token grants keyboard input is not known
   * on this side, so the touch affordance for them is the gamepad toggle alone.
   */
  const [isViewerRole, setIsViewerRole] = useState(() => {
    const h = (typeof window !== "undefined" ? window.location.hash : "").toLowerCase();
    return h.startsWith("#shared") || /^#player[234]$/.test(h);
  });
  const toggleSidebar = () => {
    setIsOpen(!isOpen);
  };
  const isSecondaryDisplay = displayId === 'display2';
  const translator = useMemo(() => getTranslator(BROWSER_PRIMARY_LANG), []);
  // system-ui picks its face from the document language, and the script-aware
  // type rules key off it. Region included: zh-TW is not zh-CN.
  useEffect(() => {
    document.documentElement.lang = BROWSER_LANG_TAG;
  }, []);
  useEffect(() => {
    window.postMessage({ type: 'sidebarVisibilityChanged', isOpen: isOpen }, window.location.origin);
  }, [isOpen]);
  /**
   * Entering fullscreen (button, Ctrl+Shift+F, or browser UI) folds the
   * dashboard so the user lands in the session; gaming mode also hides the
   * toggle so pointer lock is not fighting it.
   */
  useEffect(() => {
    const onGamingMode = (event) => {
      if (event.source !== window || event.origin !== window.location.origin) return;
      if (!event.data || event.data.type !== "gamingModeUpdate") return;
      setIsGamingMode(!!event.data.active);
    };
    window.addEventListener("message", onGamingMode);
    return () => window.removeEventListener("message", onGamingMode);
  }, []);
  useEffect(() => {
    const foldOnFullscreen = () => {
      if (document.fullscreenElement) setIsOpen(false);
    };
    document.addEventListener("fullscreenchange", foldOnFullscreen);
    return () => document.removeEventListener("fullscreenchange", foldOnFullscreen);
  }, []);
  const isMobile = isMobileClient;
  const [isTrackpadModeActive, setIsTrackpadModeActive] = useState(false);
  /** Direct-touch options as the core reports them (`touchOptionsUpdate`). */
  const [touchOptions, setTouchOptions] = useState({
    native: true, nativeAvailable: false,
    swipeScroll: true, longPressMs: 600, pinchZoom: true, inertia: true,
  });
  const [hasDetectedTouch, setHasDetectedTouch] = useState(false);
  const [heldKeys, setHeldKeys] = useState({
    Control: false,
    Alt: false,
    Meta: false,
  });
  const [isKeyboardButtonVisible, setIsKeyboardButtonVisible] = useState(true);
  const [isTouchGamepadActive, setIsTouchGamepadActive] = useState(false);
  const [isTouchGamepadSetup, setIsTouchGamepadSetup] = useState(false);
  const [availablePlacements, setAvailablePlacements] = useState(null);
  const [serverSettings, setServerSettings] = useState(null);
  const [uiTitle, setUiTitle] = useState('Rakko Remote Desktop');
  const [uiShowLogo, setUiShowLogo] = useState(true);

  useEffect(() => {
    const handleMessage = (event) => {
      if (
        event.origin === window.location.origin &&
        event.data?.type === "serverSettings"
      ) {
        console.log("Dashboard received server settings:", event.data.payload);
        setServerSettings(event.data.payload);
      }
    };
    window.addEventListener("message", handleMessage);
    return () => {
      window.removeEventListener("message", handleMessage);
    };
  }, []);

  /**
   * Which sidebar controls the server's settings allow: a pure projection of
   * `serverSettings`. A setting that is locked, has at most one allowed value,
   * or a collapsed min/max range hides its control. The clipboard section and
   * the binary-clipboard toggle are also gated on `clipboard_enabled` (wish
   * parity): with it off the core drops writes and the textarea would be dead.
   */
  const renderableSettings = useMemo(() => {
    if (!serverSettings) return {};

    const newRenderable = {};
    const s = serverSettings;

    const isRenderable = (key) => {
        const setting = s[key];
        if (!setting) return true; 
        if (setting.locked === true) return false;
        if (setting.allowed && setting.allowed.length <= 1) return false;
        if (setting.min !== undefined && setting.max !== undefined && setting.min === setting.max) return false;
        return true;
    };

    newRenderable.videoSettings = s.ui_sidebar_show_video_settings?.value ?? true;
    newRenderable.screenSettings = s.ui_sidebar_show_screen_settings?.value ?? true;
    newRenderable.audioSettings = s.ui_sidebar_show_audio_settings?.value ?? true;
    newRenderable.stats = s.ui_sidebar_show_stats?.value ?? true;
    newRenderable.clipboard = (s.ui_sidebar_show_clipboard?.value ?? true)
      && (s.clipboard_enabled?.value ?? true);
    newRenderable.files = s.ui_sidebar_show_files?.value ?? true;
    newRenderable.apps = s.ui_sidebar_show_apps?.value ?? true;
    newRenderable.sharing = s.ui_sidebar_show_sharing?.value ?? true;
    newRenderable.gamepads = s.ui_sidebar_show_gamepads?.value ?? true;
    newRenderable.shortcuts = s.ui_sidebar_show_shortcuts?.value ?? true;
    newRenderable.fullscreen = s.ui_sidebar_show_fullscreen?.value ?? true;
    newRenderable.gamingMode = s.ui_sidebar_show_gaming_mode?.value ?? true;
    newRenderable.trackpad = s.ui_sidebar_show_trackpad?.value ?? true;
    newRenderable.keyboardButton = s.ui_sidebar_show_keyboard_button?.value ?? true;
    newRenderable.softButtons = s.ui_sidebar_show_soft_buttons?.value ?? true;
    newRenderable.coreButtons = s.ui_show_core_buttons?.value ?? true;

    newRenderable.encoder = isRenderable('encoder');
    newRenderable.framerate = isRenderable('framerate');
    newRenderable.jpeg_quality = isRenderable('jpeg_quality');
    newRenderable.paint_over_jpeg_quality = isRenderable('paint_over_jpeg_quality');
    newRenderable.video_crf = isRenderable('video_crf');
    newRenderable.videoPaintoverCRF = isRenderable('video_paintover_crf');
    newRenderable.videoPaintoverBurstFrames = isRenderable('video_paintover_burst_frames');
    newRenderable.usePaintOverQuality = isRenderable('use_paint_over_quality');
    newRenderable.videoStreamingMode = isRenderable('video_streaming_mode');
    newRenderable.adaptiveFrameDrop = isRenderable('adaptive_frame_drop');
    newRenderable.videoFullColor = isRenderable('video_fullcolor');
    newRenderable.use_cpu = isRenderable('use_cpu');
    newRenderable.uiScaling = isRenderable('scaling_dpi');
    newRenderable.renderScale = isRenderable('render_scale');
    newRenderable.binaryClipboard = isRenderable('enable_binary_clipboard')
      && (s.clipboard_enabled?.value ?? true);
    newRenderable.use_browser_cursors = isRenderable('use_browser_cursors');
    newRenderable.rawPointerMotion = isRenderable('raw_pointer_motion');
    newRenderable.macCmdAsCtrl = isRenderable('mac_cmd_as_ctrl') && isMacDesktop();
    newRenderable.video_bitrate = isRenderable('video_bitrate');
    newRenderable.audio_bitrate = isRenderable('audio_bitrate');

    newRenderable.forceAlignedResolution = isRenderable('force_aligned_resolution');

    newRenderable.enableSharing = s.enable_sharing?.value ?? true;
    newRenderable.enableShared = s.enable_shared?.value ?? true;
    newRenderable.enablePlayer2 = s.enable_player2?.value ?? true;
    newRenderable.enablePlayer3 = s.enable_player3?.value ?? true;
    newRenderable.enablePlayer4 = s.enable_player4?.value ?? true;
    newRenderable.enableDualMode = s.enable_dual_mode?.value ?? false;

    // No server-side video enable setting exists.
    newRenderable.videoToggle = true;
    newRenderable.audioToggle = isRenderable('audio_enabled');
    newRenderable.microphoneToggle = isRenderable('microphone_enabled');
    newRenderable.webcamToggle = isRenderable('webcam_enabled')
      && (s.ui_sidebar_show_webcam?.value ?? true);
    newRenderable.webcamEncoder = isRenderable('webcam_encoder') && newRenderable.webcamToggle;
    newRenderable.gamepadToggle = isRenderable('gamepad_enabled');

    // Absent from the payload means the server default, which is on.
    newRenderable.enableRateControl = s.enable_rate_control?.value ?? true;
    const ftSetting = s.file_transfers;
    newRenderable.fileUpload = ftSetting ? ftSetting.value.includes('upload') : true;
    newRenderable.fileDownload = ftSetting ? ftSetting.value.includes('download') : true;

    return newRenderable;
  }, [serverSettings]);

  /**
   * With rate control disabled the server ignores `rate_control_mode` and
   * keeps the encoder on its built-in default, so the dashboard neither pushes
   * a mode nor lets its own pick decide which quality slider is shown.
   */
  const rateControlEnabled = renderableSettings.enableRateControl ?? true;

  /**
   * Opens the secondary display in a new window, sized to `screen` when the
   * Window Management API found one in that direction.
   * @param {'up'|'down'|'left'|'right'} direction
   * @param {ScreenDetailed|null} [screen]
   * @returns {boolean} Whether the window opened.
   */
  const launchWindow = (direction, screen = null) => {
    const url = `${window.location.href.split('#')[0]}#display2-${direction}`;
    // Not `noopener` in the features: that makes window.open return null even
    // when it opened, leaving a refusal indistinguishable from success. The
    // opener is severed on the handle instead.
    let features = 'resizable=yes,scrollbars=yes';
    if (screen) {
      features += `,left=${screen.availLeft},top=${screen.availTop},width=${screen.availWidth},height=${screen.availHeight}`;
    }
    const opened = window.open(url, '_blank', features);
    if (!opened) {
      // Refused from an async continuation, whose click activation is spent (all
      // the more after a permission prompt). An arrow click is a fresh one.
      console.warn('Second display window was blocked; leaving the placement arrows up.');
      return false;
    }
    try { opened.opener = null; } catch { /* already navigated away */ }
    setAvailablePlacements(null);
    return true;
  };

  /** Every side, with no screen to place the window on: what the arrows offer
   *  when nothing can be measured to choose a side from. */
  const ANY_SIDE = { up: null, down: null, left: null, right: null };

  /**
   * Add Screen: places the second display on an adjacent physical screen when
   * the Window Management API reports exactly one, and otherwise offers the
   * placement arrows. Asking beats guessing: the API answers nothing without
   * the window-management permission, and a display silently opened to the
   * right of a monitor that sits above or left of this one is the one thing
   * the arrows exist to avoid. A refused popup falls back to the arrows too,
   * so the button is never seen to do nothing at all.
   */
  const handleAddScreenClick = async () => {
    if (!('getScreenDetails' in window)) {
      console.warn("Window Management API not supported; asking which side.");
      setAvailablePlacements(ANY_SIDE);
      return;
    }

    try {
      const screenDetails = await window.getScreenDetails();
      const currentScreen = screenDetails.currentScreen;
      const otherScreens = screenDetails.screens.filter(s => s !== currentScreen);

      if (otherScreens.length === 0) {
        console.log("No other screens detected; asking which side.");
        setAvailablePlacements(ANY_SIDE);
        return;
      }

      const placements = {};
      for (const s of otherScreens) {
        if (!placements.right && s.left >= currentScreen.left + currentScreen.width) {
          placements.right = s;
        }
        if (!placements.left && s.left + s.width <= currentScreen.left) {
          placements.left = s;
        }
        if (!placements.down && s.top >= currentScreen.top + currentScreen.height) {
          placements.down = s;
        }
        if (!placements.up && s.top + s.height <= currentScreen.top) {
          placements.up = s;
        }
      }
      
      const availableDirections = Object.keys(placements);

      if (availableDirections.length === 1) {
        const direction = availableDirections[0];
        const screen = placements[direction];
        console.log(`Auto-placing single screen to the ${direction}.`);
        if (!launchWindow(direction, screen)) setAvailablePlacements(placements);
      } else if (availableDirections.length > 1) {
        console.log("Multiple placement options found. Showing arrows.");
        setAvailablePlacements(placements);
      } else {
        console.log("No adjacent screens found in cardinal directions; asking which side.");
        setAvailablePlacements(ANY_SIDE);
      }
    } catch (err) {
      // A refused permission is an ordinary outcome — the arrows still ask,
      // with no screen to place the window on — so it is not a fault.
      if (err && err.name === "NotAllowedError") {
        console.warn("Window Management permission refused; asking which side.");
      } else {
        console.error("Error with Window Management API:", err);
      }
      setAvailablePlacements(ANY_SIDE);
    }
  };

  useEffect(() => {
    const detectTouch = () => {
      console.log("Dashboard: First touch detected. Enabling touch-specific features.");
      setHasDetectedTouch(true);
    };
    window.addEventListener('touchstart', detectTouch, { once: true, passive: true });
    return () => {
      window.removeEventListener('touchstart', detectTouch, { once: true, passive: true });
    };
  }, []);

  useEffect(() => {
    const setRealViewportHeight = () => {
      const vh = window.innerHeight * 0.01;
      document.documentElement.style.setProperty('--vh', `${vh}px`);
    };
    window.addEventListener('resize', setRealViewportHeight);
    window.addEventListener('orientationchange', setRealViewportHeight);
    setRealViewportHeight();
    return () => {
      window.removeEventListener('resize', setRealViewportHeight);
      window.removeEventListener('orientationchange', setRealViewportHeight);
    };
  }, []);

  const { t, raw } = translator;
  /** Dispatches a synthetic keyboard event on `window` for the input core to forward. */
  const sendKeyEvent = (type, key, code, modifierState) => {
    const event = new KeyboardEvent(type, {
      key: key,
      code: code,
      ctrlKey: modifierState.Control,
      altKey: modifierState.Alt,
      metaKey: modifierState.Meta,
      bubbles: true,
      cancelable: true,
    });
    window.dispatchEvent(event);
  };
  /**
   * Soft modifier key: toggles the key held, and switches the core's synth
   * mode on with the first held modifier and off with the last release.
   */
  const handleHoldKeyClick = (key, code) => {
    const isCurrentlyHeld = heldKeys[key];
    const currentHeldCount = Object.values(heldKeys).filter(Boolean).length;
    if (!isCurrentlyHeld && currentHeldCount === 0) {
      window.postMessage({ type: 'setSynth', value: true }, window.location.origin);
    } else if (isCurrentlyHeld && currentHeldCount === 1) {
      window.postMessage({ type: 'setSynth', value: false }, window.location.origin);
    }
    const nextHeldState = {
      ...heldKeys,
      [key]: !isCurrentlyHeld,
    };
    setHeldKeys(nextHeldState);
    if (isCurrentlyHeld) {
      sendKeyEvent('keyup', key, code, nextHeldState);
      console.log(`Dashboard: Dispatched keyup for ${key} with state:`, nextHeldState);
    } else {
      sendKeyEvent('keydown', key, code, nextHeldState);
      console.log(`Dashboard: Dispatched keydown for ${key} with state:`, nextHeldState);
    }
  };
  /** Soft momentary key: a press and release carrying the held modifiers. */
  const handleOnceKeyClick = (key, code) => {
    console.log(`Dashboard: Dispatching key press for ${key} with modifiers:`, heldKeys);
    sendKeyEvent('keydown', key, code, heldKeys);
    setTimeout(() => {
      sendKeyEvent('keyup', key, code, heldKeys);
    }, 50);
  };
  const toggleKeyboardButtonVisibility = () => {
    setIsKeyboardButtonVisible(prev => !prev);
  };

  const [streamMode, setStreamMode] = useState(
    localStorage.getItem(getPrefixedKey("stream_mode")) ||
      (typeof window !== "undefined" && window.__SELKIES_STREAMING_MODE__) ||
      DEFAULT_STREAM_MODE
  );
  const [audioBitrate, setAudioBitrate] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("audio_bitrate")), 10) || DEFAULT_AUDIO_BITRATE
  );
  const [videoBitrate, setVideoBitrate] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("video_bitrate")), 10) || DEFAULT_VIDEO_BITRATE
  );
  const [theme, setTheme] = useState(localStorage.getItem("theme") || "dark");
  const [encoder, setEncoder] = useState(
    localStorage.getItem(getPrefixedKey("encoder")) || DEFAULT_ENCODER
  );
  const [webcamEncoderChoice, setWebcamEncoderChoice] = useState(
    localStorage.getItem(getPrefixedKey("webcam_encoder"))
  );
  const [framerate, setFramerate] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("framerate")), 10) ||
      DEFAULT_FRAMERATE
  );
  const [video_crf, setVideoCRF] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("video_crf")), 10) ||
      DEFAULT_VIDEO_CRF
  );
  const [videoPaintoverCRF, setVideoPaintoverCRF] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("video_paintover_crf")), 10) ||
      DEFAULT_H264_PAINTOVER_CRF
  );
  const [videoPaintoverBurstFrames, setVideoPaintoverBurstFrames] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("video_paintover_burst_frames")), 10) || 5
  );
  const [jpeg_quality, setJpegQuality] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("jpeg_quality")), 10) ||
      DEFAULT_JPEG_QUALITY
  );
  const [paint_over_jpeg_quality, setPaintOverJpegQuality] = useState(
    parseInt(localStorage.getItem(getPrefixedKey("paint_over_jpeg_quality")), 10) ||
      DEFAULT_PAINT_OVER_JPEG_QUALITY
  );
  const [selectedDpi, setSelectedDpi] = useState(() => normalizeDpiChoice(
    localStorage.getItem(getPrefixedKey("scaling_dpi")), DEFAULT_DPI));
  const [selectedRenderScale, setSelectedRenderScale] = useState(() => normalizeRenderScale(
    localStorage.getItem(getPrefixedKey("render_scale")), DEFAULT_RENDER_SCALE));
  const [manual_width, setManualWidth] = useState(localStorage.getItem(getPrefixedKey("manual_width")) || "");
  const [manual_height, setManualHeight] = useState(localStorage.getItem(getPrefixedKey("manual_height")) || "");
  const [scaleLocally, setScaleLocally] = useState(() => {
    const saved = localStorage.getItem(getPrefixedKey("scaleLocallyManual"));
    return saved !== null ? saved === "true" : DEFAULT_SCALE_LOCALLY;
  });
  /**
   * State the conditional settings read; rebuilt each render so the hooks
   * below re-resolve against current values when their deps change.
   * `activeEncoder` is the one encoder knob for both transports, read from
   * storage first: an out-of-set stored value is ignored by the server's own
   * fallback and re-seated by the `serverSettings` sync. `softwareH264Encoder`
   * and `useCpu` (the client's choice, else the server's) feed the
   * rate-control default.
   */
  const conditionalCtx = {
    manualActive: manualResolutionActive(serverSettings),
    streamMode,
    activeEncoder: readStored("encoder") || encoder,
    softwareH264Encoder: serverSettings?.software_h264_encoder?.value,
    useCpu: readStored("use_cpu") !== null
      ? readStored("use_cpu") === "true" : !!serverSettings?.use_cpu?.value,
    allowedRateControl: serverSettings?.rate_control_mode?.allowed || rateControlOptions,
    macDesktop: isMacDesktop(),
  };
  /**
   * Each conditional setting is one hook call over a shared spec. The hook
   * owns init and server sync; client-driven changes (an explicit toggle, or
   * a dependency such as the encoder or resolution) flow through
   * `writeConditional`, which sets state, persists, and propagates uniformly.
   */
  /**
   * 远端桌面 DPI：只决定远端桌面自己的大小，**不碰**渲染倍率。
   * @param {number} dpi 目标档位。
   * @param {boolean} [persist] 是否作为显式选择钉住。
   */
  const applyDesktopDpi = (dpi, persist = true) => {
    const normalized = normalizeDpiChoice(dpi);
    setSelectedDpi(normalized);
    if (persist) {
      localStorage.setItem(getPrefixedKey("scaling_dpi"), String(normalized));
    }
    // 桌面 DPI 是服务端设置，走防抖的 settings 通道。
    conditionalIo.postSetting({ scaling_dpi: normalized });
  };
  /**
   * 渲染倍率：只决定 framebuffer 相对窗口 CSS 尺寸的倍数，**不碰**桌面 DPI。
   * @param {number} value 目标倍率（百分比）。
   * @param {boolean} [persist] 是否作为显式选择钉住。
   */
  const applyRenderScale = (value, persist = true) => {
    const normalized = normalizeRenderScale(value);
    setSelectedRenderScale(normalized);
    if (persist) {
      localStorage.setItem(getPrefixedKey("render_scale"), String(normalized));
    }
    // 纯客户端设置，直接告诉 core，不经防抖。
    conditionalIo.postToCore({ type: "setRenderScale", value: normalized, persist });
  };
  const [adaptiveFrameDrop, setAdaptiveFrameDrop] = useConditionalSetting(
    ADAPTIVE_FRAME_DROP_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  const [rateControlMode, setRateControlMode] = useConditionalSetting(
    RATE_CONTROL_SPEC, serverSettings, conditionalCtx, [serverSettings, streamMode], readRateControlStored);
  /** Paint-over's default tracks rate control, so its context carries the mode just settled on. */
  const paintOverCtx = { ...conditionalCtx, rateControlMode };
  const [usePaintOverQuality, setUsePaintOverQuality] = useConditionalSetting(
    USE_PAINT_OVER_QUALITY_SPEC, serverSettings, paintOverCtx, [serverSettings, rateControlMode], readPaintOverStored);
  const [videoFullColor, setVideoFullColor] = useConditionalSetting(
    VIDEO_FULLCOLOR_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  // Full colour is 4:4:4 H.264; where the decoder has no such profile the core
  // turns it off, so offering the switch would offer nothing.
  const [fullColorDecodable, setFullColorDecodable] = useState(true);
  useEffect(() => { canDecodeFullColor().then(setFullColorDecodable); }, []);
  const [use_cpu, setUseCpu] = useConditionalSetting(
    USE_CPU_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  const [videoStreamingMode, setVideoStreamingMode] = useConditionalSetting(
    VIDEO_STREAMING_MODE_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  const [forceAlignedResolution, setForceAlignedResolution] = useConditionalSetting(
    FORCE_ALIGNED_RESOLUTION_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  const [use_browser_cursors, setUseBrowserCursors] = useConditionalSetting(
    USE_BROWSER_CURSORS_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  const [rawPointerMotion, setRawPointerMotion] = useConditionalSetting(
    RAW_POINTER_MOTION_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  const [macCmdAsCtrl, setMacCmdAsCtrl] = useConditionalSetting(
    MAC_CMD_AS_CTRL_SPEC, serverSettings, conditionalCtx, [serverSettings]);
  /**
   * The cursor value the core reports as in effect (multi-monitor forces
   * browser cursors on), `null` until reported; displayed over the stored
   * preference so the toggle cannot lie about the live state.
   */
  const [effectiveCursor, setEffectiveCursor] = useState(null);
  const [antiAliasing, setAntiAliasing] = useState(() => {
    const saved = localStorage.getItem(getPrefixedKey("antiAliasingEnabled"));
    return saved !== null ? saved === "true" : true;
  });
  const [enableBinaryClipboard, setEnableBinaryClipboard] = useState(() => {
    const saved = localStorage.getItem(getPrefixedKey("enable_binary_clipboard"));
    return saved !== null ? saved === 'true' : DEFAULT_ENABLE_BINARY_CLIPBOARD;
  });
  const [presetValue, setPresetValue] = useState("");
  const [clientFps, setClientFps] = useState(0);
  const [audioLevel, setAudioLevel] = useState(0);
  const audioMeterRef = useRef(null);
  const [bandwidthMbps, setBandwidthMbps] = useState(0);
  const [latencyMs, setLatencyMs] = useState(0);
  const [cpuPercent, setCpuPercent] = useState(0);
  const [gpuPercent, setGpuPercent] = useState(0);
  const [sysMemPercent, setSysMemPercent] = useState(0);
  const [gpuMemPercent, setGpuMemPercent] = useState(0);
  const [sysMemUsed, setSysMemUsed] = useState(null);
  const [sysMemTotal, setSysMemTotal] = useState(null);
  const [gpuMemUsed, setGpuMemUsed] = useState(null);
  const [gpuMemTotal, setGpuMemTotal] = useState(null);
  const [hoveredItem, setHoveredItem] = useState(null);
  const [tooltipPosition, setTooltipPosition] = useState({ x: 0, y: 0 });
  const [isVideoActive, setIsVideoActive] = useState(true);
  const [isAudioActive, setIsAudioActive] = useState(true);
  const [isMicrophoneActive, setIsMicrophoneActive] = useState(false);
  const [isWebcamActive, setIsWebcamActive] = useState(false);
  const [isGamepadEnabled, setIsGamepadEnabled] = useState(true);
  const [dashboardClipboardContent, setDashboardClipboardContent] =
    useState("");
  /**
   * Large server clipboards arrive as a bounded, truncated preview; editing
   * it would echo the cut-down text back over the real server clipboard on
   * blur, so truncated content renders read-only.
   */
  const [dashboardClipboardTruncated, setDashboardClipboardTruncated] =
    useState(false);
  const [audioInputDevices, setAudioInputDevices] = useState([]);
  const [audioOutputDevices, setAudioOutputDevices] = useState([]);
  const [selectedInputDeviceId, setSelectedInputDeviceId] = useState("default");
  const [selectedOutputDeviceId, setSelectedOutputDeviceId] =
    useState("default");
  const [isOutputSelectionSupported, setIsOutputSelectionSupported] =
    useState(false);
  const [audioDeviceError, setAudioDeviceError] = useState(null);
  const [isLoadingAudioDevices, setIsLoadingAudioDevices] = useState(false);
  const [gamepadStates, setGamepadStates] = useState({});
  const [hasReceivedGamepadData, setHasReceivedGamepadData] = useState(false);
  const [sectionsOpen, setSectionsOpen] = useState({
    settings: false,
    audioSettings: false,
    screenSettings: false,
    stats: false,
    clipboard: false,
    // A phone lands on gamepads: the reason to open the dashboard on touch at all.
    gamepads: isMobileClient,
    files: false,
    apps: false,
    sharing: false,
    shortcuts: false,
  });
  const [notifications, setNotifications] = useState([]);
  const notificationTimeouts = useRef({});
  const [isFilesModalOpen, setIsFilesModalOpen] = useState(false);
  const [isFilesModalLoading, setIsFilesModalLoading] = useState(true);
  const [isAppsModalOpen, setIsAppsModalOpen] = useState(false);
  const [keyboardButtonPosition, setKeyboardButtonPosition] = useState({ bottom: 20, right: 20 });
  const dragInfo = useRef({
    isDragging: false,
    hasDragged: false,
    pointerId: null,
    startX: 0,
    startY: 0,
    initialBottom: 0,
    initialRight: 0,
  });
  /**
   * Toggle handle position as a percentage of the viewport height, so a
   * resize keeps it proportional; persisted across reloads.
   */
  const [toggleHandleTopPct, setToggleHandleTopPct] = useState(() => {
    const stored = parseFloat(localStorage.getItem(getPrefixedKey("sidebarToggleTopPct")));
    return Number.isFinite(stored) ? clampToggleHandleTopPct(stored) : 50;
  });
  const toggleDragInfo = useRef({
    isDragging: false,
    hasDragged: false,
    pointerId: null,
    startX: 0,
    startY: 0,
    initialTopPct: 50,
    lastTopPct: 50,
  });
  const isWebrtc = streamMode === STREAM_MODE_WEBRTC;
  /**
   * Filters an encoder list to what this transport can play: on the
   * WebSocket transport only encoders this engine can decode (JPEG alone
   * without WebCodecs). The static lists seed the picker; the server's own
   * allowed list replaces them as soon as settings arrive.
   */
  const offeredEncoders = useCallback(
    (list) => (isWebrtc ? list : decodableEncoders(list)), [isWebrtc]);
  const [dynamicEncoderOptions, setDynamicEncoderOptions] = useState(
    () => offeredEncoders(isWebrtc ? encoderOptionsWR : encoderOptions));
  /** Audio bitrate stops the slider indexes into: the server's allowed enum, else the local list. */
  const audioBitrateChoices = (serverSettings?.audio_bitrate?.allowed?.map((v) => parseInt(v, 10))) || audioBitrateOptions;

  const DEBOUNCE_DELAY = 500;

  /**
   * One debounced poster for the component's lifetime, so a burst of slider
   * moves coalesces into a single post. 同一窗口内的多个 patch 合并而不是互相
   * 覆盖：手动分辨率与桌面 DPI 常常在同一次交互里一起变。
   */
  const postQueue = useRef({ pending: {}, timeoutId: undefined });
  const debouncedPostSetting = useCallback((setting) => {
    const queue = postQueue.current;
    queue.pending = { ...queue.pending, ...setting };
    clearTimeout(queue.timeoutId);
    queue.timeoutId = setTimeout(() => {
      const merged = queue.pending;
      queue.pending = {};
      queue.timeoutId = undefined;
      window.postMessage(
        { type: "settings", settings: merged },
        window.location.origin
      );
    }, DEBOUNCE_DELAY);
  }, []);

  /** The two push channels a spec can propagate through; each spec decides which. */
  const conditionalIo = {
    postSetting: (obj) => debouncedPostSetting(obj),
    postToCore: (obj) => window.postMessage(obj, window.location.origin),
  };
  /**
   * Uniform write path for conditional settings: optimistic setState, an
   * optional persist (explicit choices pin, derived ones do not), and
   * propagation through the spec.
   * @param {object} spec
   * @param {any} uiValue The value as the UI holds it.
   * @param {Function} setValue The setting's state setter.
   * @param {{persist?: boolean}} [opts]
   */
  const writeConditional = (spec, uiValue, setValue, opts = {}) => {
    setValue(uiValue);
    if (opts.persist) {
      localStorage.setItem(getPrefixedKey(spec.storageKey),
        spec.serialize ? spec.serialize(uiValue) : String(uiValue));
      localStorage.setItem(explicitChoiceKey(spec), "true");
    }
    spec.propagate(spec.toServer ? spec.toServer(uiValue) : uiValue, conditionalCtx, conditionalIo);
  };

  /**
   * Seeds every plain setting from the server's payload, with a stored value
   * taking precedence when the server allows it; the conditional settings
   * sync through their `useConditionalSetting` hooks instead. This writes
   * state instead of deriving during render because every value stays
   * editable afterwards; recomputing each render would discard the user's
   * edits. `scaling_dpi` resolves an operator override (which the server
   * refuses to let clients clobber), then the stored pick, then the derived
   * local-display default, the order the cores send on every connect
   * independent of the resolution mode; a derived value that differs from the
   * server's is posted.
   */
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    if (!serverSettings) return;
    const getStoredInt = (key) => parseInt(localStorage.getItem(getPrefixedKey(key)), 10);
    const getStoredBool = (key, fallback = false) => {
      const stored = localStorage.getItem(getPrefixedKey(key));
      return stored !== null ? stored === 'true' : fallback;
    };
    const s_encoder = serverSettings.encoder;
    if (s_encoder) {
      const allowed = offeredEncoders(s_encoder.allowed);
      const stored = localStorage.getItem(getPrefixedKey("encoder"));
      const final = allowed.includes(stored) ? stored
        : (allowed.includes(s_encoder.value) || allowed.length === 0) ? s_encoder.value : allowed[0];
      setEncoder(final);
      setDynamicEncoderOptions(allowed);
    }
    const s_framerate = serverSettings.framerate;
    if (s_framerate) {
      const stored = getStoredInt("framerate");
      const final = !isNaN(stored)
        ? Math.max(s_framerate.min, Math.min(s_framerate.max, stored))
        : s_framerate.default;
      setFramerate(final);
    }
    const s_video_bitrate = serverSettings.video_bitrate;
    if (s_video_bitrate) {
      const stored = parseInt(localStorage.getItem(getPrefixedKey("video_bitrate")), 10);
      const final = !isNaN(stored)
        ? Math.max(s_video_bitrate.min, Math.min(s_video_bitrate.max, stored))
        : s_video_bitrate.default;
      setVideoBitrate(final);
    }
    const s_audio_bitrate = serverSettings.audio_bitrate;
    if (s_audio_bitrate) {
      const stored = getStoredInt("audio_bitrate");
      // allowed holds strings; compare as string and keep the result numeric.
      let final = s_audio_bitrate.allowed?.includes(String(stored)) ? stored : parseInt(s_audio_bitrate.value, 10);
      // A NaN would persist and break the slider; the server's highest allowed value is the fallback.
      if (Number.isNaN(final)) {
        const allowed = s_audio_bitrate.allowed;
        const maxAllowed = parseInt(allowed?.[allowed.length - 1], 10);
        final = Number.isNaN(maxAllowed) ? 320000 : maxAllowed;
      }
      setAudioBitrate(final);
    }
    const s_video_crf = serverSettings.video_crf;
    if (s_video_crf) {
      const stored = getStoredInt("video_crf");
      const final = !isNaN(stored)
        ? Math.max(s_video_crf.min, Math.min(s_video_crf.max, stored))
        : s_video_crf.default;
      setVideoCRF(final);
    }
    const s_jpeg_quality = serverSettings.jpeg_quality;
    if (s_jpeg_quality) {
      const stored = getStoredInt("jpeg_quality");
      const final = !isNaN(stored)
        ? Math.max(s_jpeg_quality.min, Math.min(s_jpeg_quality.max, stored))
        : s_jpeg_quality.default;
      setJpegQuality(final);
    }
    const s_paint_over_jpeg_quality = serverSettings.paint_over_jpeg_quality;
    if (s_paint_over_jpeg_quality) {
      const stored = getStoredInt("paint_over_jpeg_quality");
      const final = !isNaN(stored)
        ? Math.max(s_paint_over_jpeg_quality.min, Math.min(s_paint_over_jpeg_quality.max, stored))
        : s_paint_over_jpeg_quality.default;
      setPaintOverJpegQuality(final);
    }
    const s_video_paintover_crf = serverSettings.video_paintover_crf;
    if (s_video_paintover_crf) {
      const stored = getStoredInt("video_paintover_crf");
      const final = !isNaN(stored)
        ? Math.max(s_video_paintover_crf.min, Math.min(s_video_paintover_crf.max, stored))
        : s_video_paintover_crf.default;
      setVideoPaintoverCRF(final);
    }
    const s_video_paintover_burst = serverSettings.video_paintover_burst_frames;
    if (s_video_paintover_burst) {
      const stored = getStoredInt("video_paintover_burst_frames");
      const final = !isNaN(stored)
        ? Math.max(s_video_paintover_burst.min, Math.min(s_video_paintover_burst.max, stored))
        : s_video_paintover_burst.default;
      setVideoPaintoverBurstFrames(final);
    }
    const s_scaling_dpi = serverSettings.scaling_dpi;
    if (s_scaling_dpi) {
      const stored = getStoredInt("scaling_dpi");
      const storedAllowed = (s_scaling_dpi.allowed || []).includes(String(stored));
      const serverVal = normalizeDpiChoice(s_scaling_dpi.value);
      // 桌面 DPI 只由自己的档位决定，分辨率不派生它。
      const final = s_scaling_dpi.overridden ? serverVal
        : storedAllowed ? stored
        : serverVal;
      setSelectedDpi(normalizeDpiChoice(final, DEFAULT_DPI));
    }
    const s_render_scale = serverSettings.render_scale;
    if (s_render_scale) {
      const stored = getStoredInt("render_scale");
      const storedAllowed = (s_render_scale.allowed || []).includes(String(stored));
      const serverVal = normalizeRenderScale(s_render_scale.value);
      setSelectedRenderScale(storedAllowed ? stored : serverVal);
    }
    const s_enable_binary_clipboard = serverSettings.enable_binary_clipboard;
    if (s_enable_binary_clipboard) {
      const final = s_enable_binary_clipboard.locked ? s_enable_binary_clipboard.value : getStoredBool("enable_binary_clipboard", s_enable_binary_clipboard.value);
      setEnableBinaryClipboard(final);
    }
    const s_ui_title = serverSettings.ui_title;
    if (s_ui_title) {
        setUiTitle(s_ui_title.value);
    }
    const s_ui_show_logo = serverSettings.ui_show_logo;
    if (s_ui_show_logo) {
        setUiShowLogo(s_ui_show_logo.value);
    }
  }, [serverSettings, debouncedPostSetting, offeredEncoders]);
  /* eslint-enable react-hooks/set-state-in-effect */

  /**
   * Rate control: the hook only sets local state, so when the resolved
   * default diverges from what the server is applying (a transport switch
   * seeds the session with the previous mode's value) this pushes it so the
   * encoder follows. Pinned, locked or operator-overridden values resolve to
   * the server's value and post nothing. The core persists every mode it is
   * told to apply and resends it on the next connect, so without an explicit
   * pick the stored value is an echo, not a choice: it is dropped once it
   * stops matching what the ladder resolves, or it would outlive the
   * derivation, and an operator override with it.
   */
  useEffect(() => {
    if (!serverSettings) return;
    if (serverSettings.enable_rate_control?.value === false) return;
    const rcKey = RATE_CONTROL_SPEC.storageKey;
    const resolved = resolveSpec(
      RATE_CONTROL_SPEC, serverSettings, conditionalCtx, readRateControlStored);
    if (!isExplicitChoice(RATE_CONTROL_SPEC)
      && readStored(rcKey) !== null && readStored(rcKey) !== resolved) {
      localStorage.removeItem(getPrefixedKey(rcKey));
    }
    if (isSettingPinned(RATE_CONTROL_SPEC, serverSettings, readRateControlStored)) return;
    const serverValue = serverSettings[RATE_CONTROL_SPEC.serverKey]?.value;
    if (resolved && serverValue !== undefined && resolved !== serverValue) {
      writeConditional(RATE_CONTROL_SPEC, resolved, setRateControlMode, { persist: false });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverSettings]);

  /**
   * Paint-over: pushes the default the resolved rate control implies so the
   * encoder agrees, and drops the unmarked stored echo once the ladder moves
   * on, the same shape as the rate-control derivation.
   */
  useEffect(() => {
    if (!serverSettings) return;
    const key = USE_PAINT_OVER_QUALITY_SPEC.storageKey;
    const resolved = resolveSpec(
      USE_PAINT_OVER_QUALITY_SPEC, serverSettings, { ...conditionalCtx, rateControlMode }, readPaintOverStored);
    if (!isExplicitChoice(USE_PAINT_OVER_QUALITY_SPEC)
      && readStored(key) !== null
      && readStored(key) !== String(resolved)) {
      localStorage.removeItem(getPrefixedKey(key));
    }
    if (isSettingPinned(USE_PAINT_OVER_QUALITY_SPEC, serverSettings, readPaintOverStored)) return;
    const serverValue = serverSettings.use_paint_over_quality?.value;
    if (resolved !== undefined && serverValue !== undefined && resolved !== serverValue) {
      writeConditional(USE_PAINT_OVER_QUALITY_SPEC, resolved, setUsePaintOverQuality, { persist: false });
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverSettings, rateControlMode]);

  /** 远端桌面 DPI：持久化以便跨刷新保留；不影响渲染倍率。 */
  const handleDpiScalingChange = (event) => {
    applyDesktopDpi(normalizeDpiChoice(event.target.value), true);
  };
  /** 渲染倍率：同上，只写自己。 */
  const handleRenderScaleChange = (event) => {
    applyRenderScale(normalizeRenderScale(event.target.value), true);
  };
  const handleAdaptiveFrameDropToggle = () => {
    writeConditional(ADAPTIVE_FRAME_DROP_SPEC, !adaptiveFrameDrop,
      setAdaptiveFrameDrop, { persist: true });
  };

  const DRAG_THRESHOLD = 10;

  const handlePointerDown = (e) => {
    dragInfo.current.isDragging = true;
    dragInfo.current.hasDragged = false;
    dragInfo.current.pointerId = e.pointerId;
    dragInfo.current.startX = e.clientX;
    dragInfo.current.startY = e.clientY;
    dragInfo.current.initialBottom = keyboardButtonPosition.bottom;
    dragInfo.current.initialRight = keyboardButtonPosition.right;
    e.currentTarget.setPointerCapture(e.pointerId);
  };

  const handlePointerMove = (e) => {
    if (!dragInfo.current.isDragging) return;

    const dx = e.clientX - dragInfo.current.startX;
    const dy = e.clientY - dragInfo.current.startY;

    if (!dragInfo.current.hasDragged && (Math.abs(dx) > DRAG_THRESHOLD || Math.abs(dy) > DRAG_THRESHOLD)) {
      dragInfo.current.hasDragged = true;
    }

    if (dragInfo.current.hasDragged) {
      setKeyboardButtonPosition({
        bottom: dragInfo.current.initialBottom - dy,
        right: dragInfo.current.initialRight - dx,
      });
    }
  };

  const handlePointerUp = (e) => {
    if (e.currentTarget.hasPointerCapture(dragInfo.current.pointerId)) {
      e.currentTarget.releasePointerCapture(e.pointerId);
    }
    dragInfo.current.isDragging = false;
    dragInfo.current.pointerId = null;
  };

  const onKeyboardButtonClick = (e) => {
    if (dragInfo.current.hasDragged) {
      e.preventDefault();
      e.stopPropagation();
      dragInfo.current.hasDragged = false;
      return;
    }
    handleShowVirtualKeyboard();
  };

  const handleTogglePointerDown = (e) => {
    toggleDragInfo.current.isDragging = true;
    toggleDragInfo.current.hasDragged = false;
    toggleDragInfo.current.pointerId = e.pointerId;
    toggleDragInfo.current.startX = e.clientX;
    toggleDragInfo.current.startY = e.clientY;
    toggleDragInfo.current.initialTopPct = toggleHandleTopPct;
    toggleDragInfo.current.lastTopPct = toggleHandleTopPct;
    e.currentTarget.setPointerCapture(e.pointerId);
  };

  const handleTogglePointerMove = (e) => {
    if (!toggleDragInfo.current.isDragging) return;

    const dx = e.clientX - toggleDragInfo.current.startX;
    const dy = e.clientY - toggleDragInfo.current.startY;

    if (!toggleDragInfo.current.hasDragged && (Math.abs(dx) > DRAG_THRESHOLD || Math.abs(dy) > DRAG_THRESHOLD)) {
      toggleDragInfo.current.hasDragged = true;
    }

    if (toggleDragInfo.current.hasDragged) {
      const vh = window.innerHeight || 1;
      const newTopPct = clampToggleHandleTopPct(
        toggleDragInfo.current.initialTopPct + (dy / vh) * 100
      );
      toggleDragInfo.current.lastTopPct = newTopPct;
      setToggleHandleTopPct(newTopPct);
    }
  };

  /**
   * Ends a handle drag and persists its position. `pointerId` is null when
   * the pointerup had no matching pointerdown (capture lost), and
   * `hasPointerCapture(null)` coerces to id 0 and could release a foreign
   * capture, so capture is only released for the tracked pointer.
   */
  const handleTogglePointerUp = (e) => {
    const pid = toggleDragInfo.current.pointerId;
    if (pid !== null && e.currentTarget.hasPointerCapture(pid)) {
      e.currentTarget.releasePointerCapture(pid);
    }
    const didDrag = toggleDragInfo.current.hasDragged;
    const finalPct = toggleDragInfo.current.lastTopPct;
    toggleDragInfo.current.isDragging = false;
    toggleDragInfo.current.pointerId = null;
    if (didDrag) {
      try {
        localStorage.setItem(getPrefixedKey("sidebarToggleTopPct"), finalPct.toString());
      } catch {
        // A blocked/full storage write only loses persistence for this drag.
      }
    }
  };

  const onToggleHandleClick = (e) => {
    if (toggleDragInfo.current.hasDragged) {
      e.preventDefault();
      e.stopPropagation();
      toggleDragInfo.current.hasDragged = false;
      return;
    }
    toggleSidebar();
  };

  const toggleAppsModal = () => setIsAppsModalOpen(!isAppsModalOpen);
  const toggleFilesModal = () => {
    // The frame reloads whenever the modal reopens, so the spinner comes back
    // with it; its own onLoad clears it.
    if (!isFilesModalOpen) {
      setIsFilesModalLoading(true);
    }
    setIsFilesModalOpen(!isFilesModalOpen);
  };
  /**
   * Pops the on-screen keyboard by focusing the core's `#keyboard-input-assist`
   * input; the next touch on the stream overlay blurs it again.
   */
  const handleShowVirtualKeyboard = useCallback(() => {
    console.log("Dashboard: Directly handling virtual keyboard pop.");
    const kbdAssistInput = document.getElementById('keyboard-input-assist');
    const mainInteractionOverlay = document.getElementById('overlayInput');
    if (kbdAssistInput) {
      kbdAssistInput.removeAttribute('aria-hidden');
      kbdAssistInput.value = '';
      kbdAssistInput.focus();
      console.log("Focused #keyboard-input-assist element to pop keyboard.");
      if (mainInteractionOverlay) {
        mainInteractionOverlay.addEventListener(
          "touchstart",
          () => {
            if (document.activeElement === kbdAssistInput) {
              kbdAssistInput.blur();
              console.log("Blurred #keyboard-input-assist on main overlay touch.");
              kbdAssistInput.setAttribute('aria-hidden', 'true');
            }
          }, {
            once: true,
            passive: true
          }
        );
      } else {
         console.warn("Could not find #overlayInput to attach blur listener.");
      }
    } else {
      console.error("Could not find #keyboard-input-assist element to focus.");
    }
  }, []);

  /**
   * Lists the audio devices for the audio section, taking a momentary
   * microphone permission so labels are readable. Output routing goes through
   * whatever the active core plays on: the WebRTC core's `<video>` element
   * (`HTMLMediaElement.setSinkId`) or the WebSocket core's AudioContext
   * (`AudioContext.setSinkId`, which Firefox lacks), so the one in use is
   * probed or the output picker would render and do nothing. The selections
   * are left alone: the core keeps the devices this dashboard picked for the
   * life of the page, so a reopened section shows them rather than defaulting.
   */
  const populateAudioDevices = useCallback(async () => {
    console.log("Dashboard: Attempting to populate audio devices...");
    setIsLoadingAudioDevices(true);
    setAudioDeviceError(null);
    setAudioInputDevices([]);
    setAudioOutputDevices([]);
    const supportsSinkId = isWebrtc
      ? "setSinkId" in HTMLMediaElement.prototype
      : typeof AudioContext !== "undefined" && "setSinkId" in AudioContext.prototype;
    setIsOutputSelectionSupported(supportsSinkId);
    console.log(
      "Dashboard: Output device selection supported:",
      supportsSinkId
    );
    try {
      console.log(
        "Dashboard: Requesting temporary microphone permission for device listing..."
      );
      const tempStream = await navigator.mediaDevices.getUserMedia({
        audio: true,
      });
      tempStream.getTracks().forEach((track) => track.stop());
      console.log("Dashboard: Temporary permission granted/available.");
      console.log("Dashboard: Enumerating media devices...");
      const devices = await navigator.mediaDevices.enumerateDevices();
      console.log("Dashboard: Devices found:", devices);
      const inputs = [];
      const outputs = [];
      devices.forEach((device, index) => {
        if (!device.deviceId) {
          console.warn(
            "Dashboard: Skipping device with missing deviceId:",
            device
          );
          return;
        }
        const label =
          device.label ||
          (device.kind === "audioinput"
            ? t("sections.audio.defaultInputLabelFallback", {
                index: index + 1,
              })
            : t("sections.audio.defaultOutputLabelFallback", {
                index: index + 1,
              }));
        if (device.kind === "audioinput") {
          inputs.push({ deviceId: device.deviceId, label: label });
        } else if (device.kind === "audiooutput" && supportsSinkId) {
          outputs.push({ deviceId: device.deviceId, label: label });
        }
      });
      setAudioInputDevices(inputs);
      setAudioOutputDevices(outputs);
      console.log(
        `Dashboard: Populated ${inputs.length} inputs, ${outputs.length} outputs.`
      );
    } catch (err) {
      console.error(
        "Dashboard: Error getting media devices or permissions:",
        err
      );
      let userMessageKey = "sections.audio.deviceErrorDefault";
      let errorVars = { errorName: err.name || "Unknown error" };
      if (err.name === "NotAllowedError")
        userMessageKey = "sections.audio.deviceErrorPermission";
      else if (err.name === "NotFoundError")
        userMessageKey = "sections.audio.deviceErrorNotFound";
      setAudioDeviceError(t(userMessageKey, errorVars));
    } finally {
      setIsLoadingAudioDevices(false);
    }
  }, [t, isWebrtc]);

  /** Folds or unfolds a section; opening the audio section enumerates devices. */
  const toggleSection = useCallback(
    (sectionKey) => {
      const isOpening = !sectionsOpen[sectionKey];
      setSectionsOpen((prev) => ({ ...prev, [sectionKey]: !prev[sectionKey] }));
      if (sectionKey === "audioSettings" && isOpening) {
        populateAudioDevices();
      }
    },
    [sectionsOpen, populateAudioDevices]
  );
  const baseUrl = typeof window !== 'undefined' ? window.location.href.split('#')[0] : '';
  const sharingLinks = [
    {
      id: "shared",
      label: t("sections.sharing.viewerLabel"),
      tooltip: t("sections.sharing.viewerTooltip"),
      hash: "#shared",
    },
    ...[2, 3, 4].map((n) => ({
      id: `player${n}`,
      label: t("sections.sharing.controllerLabel", { n }),
      tooltip: t("sections.sharing.controllerTooltip", { n }),
      hash: `#player${n}`,
    })),
  ];
  /** Copies a sharing link and reports the outcome as a notification. */
  const handleCopyLink = async (textToCopy, label) => {
    if (!navigator.clipboard) {
      console.warn("Clipboard API not available.");
      return;
    }
    try {
      await navigator.clipboard.writeText(textToCopy);
      const id = `copy-success-${label.toLowerCase().replace(/\s+/g, '-')}`;
      setNotifications(prev => {
        const filtered = prev.filter(n => n.id !== id);
        const newNotifs = [...filtered, {
          id,
          fileName: t("notifications.copiedTitle", { label: label }),
          status: 'end',
          message: t("notifications.copiedMessage", { textToCopy: textToCopy }),
          timestamp: Date.now(),
          fadingOut: false,
        }];
        return newNotifs.slice(-MAX_NOTIFICATIONS);
      });
      scheduleNotificationRemoval(id, NOTIFICATION_TIMEOUT_SUCCESS);
    } catch (err) {
      console.error("Failed to copy link: ", err);
      const id = `copy-error-${label.toLowerCase().replace(/\s+/g, '-')}`;
      setNotifications(prev => {
        const filtered = prev.filter(n => n.id !== id);
        const newNotifs = [...filtered, {
          id,
          fileName: t("notifications.copyFailedTitle", { label: label }),
          status: 'error',
          message: t('notifications.copyFailedError'),
          timestamp: Date.now(),
          fadingOut: false,
        }];
        return newNotifs.slice(-MAX_NOTIFICATIONS);
      });
      scheduleNotificationRemoval(id, NOTIFICATION_TIMEOUT_ERROR);
    }
  };
  /**
   * Re-derives rate control after an encoder or software-encoding change.
   * Rate control follows those unless pinned by an explicit client or server
   * choice, and a derived change is not persisted, so it keeps following.
   * @param {object} ctxOverrides The value just chosen, ahead of the re-render that would put it in `conditionalCtx`.
   */
  const rederiveRateControl = (ctxOverrides) => {
    if (!rateControlEnabled
      || isSettingPinned(RATE_CONTROL_SPEC, serverSettings, readRateControlStored)) return;
    const rcResolved = resolveSpec(
      RATE_CONTROL_SPEC, serverSettings,
      { ...conditionalCtx, ...ctxOverrides }, readRateControlStored);
    if (rcResolved !== rateControlMode) {
      writeConditional(RATE_CONTROL_SPEC, rcResolved, setRateControlMode, { persist: false });
    }
  };
  /**
   * Encoder pick, one knob for both transports; the server switches the
   * pipeline encoder on it. The choice is persisted immediately so
   * `conditionalCtx.activeEncoder`, which reads localStorage, does not lag
   * during the post debounce and let a `serverSettings` sync re-derive rate
   * control off the stale encoder.
   */
  const handleEncoderChange = (event) => {
    const selectedEncoder = event.target.value;
    setEncoder(selectedEncoder);
    localStorage.setItem(getPrefixedKey("encoder"), selectedEncoder);
    debouncedPostSetting({ encoder: selectedEncoder });
    rederiveRateControl({ activeEncoder: selectedEncoder });
  };
  const handleWebcamEncoderChange = (event) => {
    const preference = event.target.value;
    setWebcamEncoderChoice(preference);
    localStorage.setItem(getPrefixedKey("webcam_encoder"), preference);
    debouncedPostSetting({ webcam_encoder: preference });
  };
  // Derived, not synced: the server default stands in for a missing choice,
  // locked overrides it.
  const wceServer = serverSettings?.webcam_encoder;
  const wceServerValue = webcamEncoderOptions.includes(wceServer?.value) ? wceServer.value : null;
  const wceChoice = webcamEncoderOptions.includes(webcamEncoderChoice) ? webcamEncoderChoice : null;
  const webcamEncoder = (wceServer?.locked && wceServerValue) || wceChoice || wceServerValue || "auto";
  const handleFramerateChange = (event) => {
    const selectedFramerate = parseInt(event.target.value, 10);
    setFramerate(selectedFramerate);
    debouncedPostSetting({ framerate: selectedFramerate });
  };
  /** Video bitrate slider: its value is an index into `videoBitrateOptions`. */
  const handleVideoBitrateChange = (event) => {
    const index = parseInt(event.target.value, 10);
    const selectedVideoBitrate = videoBitrateOptions[index];
    if (selectedVideoBitrate === undefined) return;
    setVideoBitrate(selectedVideoBitrate)
    debouncedPostSetting({ video_bitrate: selectedVideoBitrate})
  };
  const handleAudioBitrateChange = (selectedAudioBitrate) => {
    if (Number.isNaN(selectedAudioBitrate)) selectedAudioBitrate = DEFAULT_AUDIO_BITRATE;
    setAudioBitrate(selectedAudioBitrate)
    debouncedPostSetting({ audio_bitrate: selectedAudioBitrate})
  }
  const handleJpegQualityChange = (event) => {
    const selectedQuality = parseInt(event.target.value, 10);
    setJpegQuality(selectedQuality);
    debouncedPostSetting({ jpeg_quality: selectedQuality });
  };
  const handlePaintOverJpegQualityChange = (event) => {
    const selectedQuality = parseInt(event.target.value, 10);
    setPaintOverJpegQuality(selectedQuality);
    debouncedPostSetting({ paint_over_jpeg_quality: selectedQuality });
  };
  const handleVideoCRFChange = (event) => {
    const selectedCRF = parseInt(event.target.value, 10);
    setVideoCRF(selectedCRF);
    debouncedPostSetting({ video_crf: selectedCRF });
  };
  const handleH264PaintoverCRFChange = (event) => {
    const selectedCRF = parseInt(event.target.value, 10);
    setVideoPaintoverCRF(selectedCRF);
    debouncedPostSetting({ video_paintover_crf: selectedCRF });
  };
  const handleH264PaintoverBurstChange = (event) => {
    const selectedFrames = parseInt(event.target.value, 10);
    setVideoPaintoverBurstFrames(selectedFrames);
    debouncedPostSetting({ video_paintover_burst_frames: selectedFrames });
  };
  const handleH264FullColorToggle = () => {
    writeConditional(VIDEO_FULLCOLOR_SPEC, !videoFullColor, setVideoFullColor, { persist: true });
  };
  const handleUsePaintOverQualityToggle = () => {
    writeConditional(USE_PAINT_OVER_QUALITY_SPEC, !usePaintOverQuality, setUsePaintOverQuality, { persist: true });
  };
  const handleUseCpuToggle = () => {
    writeConditional(USE_CPU_SPEC, !use_cpu, setUseCpu, { persist: true });
    rederiveRateControl({ useCpu: !use_cpu });
  };
  const handleH264StreamingModeToggle = () => {
    writeConditional(VIDEO_STREAMING_MODE_SPEC, !videoStreamingMode, setVideoStreamingMode, { persist: true });
  };
  /** Rate control pick: an explicit choice, persisted so encoder changes stop overriding it. */
  const handleRateControlChange = (event) => {
    writeConditional(RATE_CONTROL_SPEC, event.target.value, setRateControlMode, { persist: true });
  };
  const handleAudioInputChange = (event) => {
    const deviceId = event.target.value;
    setSelectedInputDeviceId(deviceId);
    window.postMessage(
      { type: "audioDeviceSelected", context: "input", deviceId: deviceId },
      window.location.origin
    );
  };
  const handleAudioOutputChange = (event) => {
    const deviceId = event.target.value;
    setSelectedOutputDeviceId(deviceId);
    window.postMessage(
      { type: "audioDeviceSelected", context: "output", deviceId: deviceId },
      window.location.origin
    );
  };
  const handlePresetChange = (event) => {
    const selectedValue = event.target.value;
    setPresetValue(selectedValue);
    if (!selectedValue) return;
    const parts = selectedValue.split("x");
    if (parts.length === 2) {
      const width = parseInt(parts[0], 10),
        height = parseInt(parts[1], 10);
      if (!isNaN(width) && width > 0 && !isNaN(height) && height > 0) {
        const evenWidth = roundDownToEven(width),
          evenHeight = roundDownToEven(height);
        setManualWidth(evenWidth.toString());
        setManualHeight(evenHeight.toString());
        localStorage.setItem(getPrefixedKey("manual_width"), evenWidth.toString());
        localStorage.setItem(getPrefixedKey("manual_height"), evenHeight.toString());
        window.postMessage(
          { type: "setManualResolution", width: evenWidth, height: evenHeight },
          window.location.origin
        );
      } else
        console.error(
          "Dashboard: Error parsing selected resolution preset:",
          selectedValue
        );
    }
  };
  /**
   * A half-typed size stays in component state: the stored `manual_width`
   * and `manual_height` mean "a manual resolution is applied", which the
   * manual-resolution re-derivations read, so only Set, a preset, or Reset
   * may write them.
   */
  const handleManualWidthChange = (event) => {
    setManualWidth(event.target.value);
    setPresetValue("");
  };
  const handleManualHeightChange = (event) => {
    setManualHeight(event.target.value);
    setPresetValue("");
  };
  const handleScaleLocallyToggle = () => {
    const newState = !scaleLocally;
    setScaleLocally(newState);
    window.postMessage(
      { type: "setScaleLocally", value: newState },
      window.location.origin
    );
  };
  const handleForceAlignedResolutionToggle = () => {
    writeConditional(FORCE_ALIGNED_RESOLUTION_SPEC, !forceAlignedResolution, setForceAlignedResolution, { persist: true });
  };
  const handleAntiAliasingToggle = () => {
    const newState = !antiAliasing;
    setAntiAliasing(newState);
    window.postMessage(
      { type: "setAntiAliasing", value: newState },
      window.location.origin
    );
  };
  /**
   * Browser cursors toggle. The core owns persistence: the new preference is
   * propagated and the core reports the effective value back. The next value
   * derives from the displayed one: while multi-monitor forces the toggle on
   * the base preference may be off, and negating the base would silently
   * persist the forced value over the user's real choice.
   */
  const handleUseBrowserCursorsToggle = () => {
    writeConditional(USE_BROWSER_CURSORS_SPEC, !(effectiveCursor ?? use_browser_cursors), setUseBrowserCursors, { persist: false });
  };
  /** Raw pointer motion toggle; the core owns persistence, as for browser cursors. */
  const handleRawPointerMotionToggle = () => {
    writeConditional(RAW_POINTER_MOTION_SPEC, !rawPointerMotion, setRawPointerMotion, { persist: false });
  };
  /** Command-as-Control toggle; the core owns persistence, as above. */
  const handleMacCmdAsCtrlToggle = () => {
    writeConditional(MAC_CMD_AS_CTRL_SPEC, !macCmdAsCtrl, setMacCmdAsCtrl, { persist: false });
  };
  const handleEnableBinaryClipboardToggle = () => {
    const newState = !enableBinaryClipboard;
    setEnableBinaryClipboard(newState);
    debouncedPostSetting({ enable_binary_clipboard: newState });
  };
  const handleSetManualResolution = () => {
    const width = parseInt(manual_width.trim(), 10),
      height = parseInt(manual_height.trim(), 10);
    if (isNaN(width) || width <= 0 || isNaN(height) || height <= 0) {
      alert(t("alerts.invalidResolution"));
      return;
    }
    const evenWidth = roundDownToEven(width),
      evenHeight = roundDownToEven(height);
    setManualWidth(evenWidth.toString());
    setManualHeight(evenHeight.toString());
    setPresetValue("");
    localStorage.setItem(getPrefixedKey("manual_width"), evenWidth.toString());
    localStorage.setItem(getPrefixedKey("manual_height"), evenHeight.toString());
    window.postMessage(
      { type: "setManualResolution", width: evenWidth, height: evenHeight },
      window.location.origin
    );
  };
  const handleResetResolution = () => {
    setManualWidth("");
    setManualHeight("");
    setPresetValue("");
    localStorage.removeItem(getPrefixedKey("manual_width"));
    localStorage.removeItem(getPrefixedKey("manual_height"));
    window.postMessage(
      { type: "resetResolutionToWindow" },
      window.location.origin
    );
  };
  const handleVideoToggle = () =>
    window.postMessage(
      { type: "pipelineControl", pipeline: "video", enabled: !isVideoActive },
      window.location.origin
    );
  const handleAudioToggle = () =>
    window.postMessage(
      { type: "pipelineControl", pipeline: "audio", enabled: !isAudioActive },
      window.location.origin
    );
  const handleMicrophoneToggle = () =>
    window.postMessage(
      {
        type: "pipelineControl",
        pipeline: "microphone",
        enabled: !isMicrophoneActive,
      },
      window.location.origin
    );
  const handleWebcamToggle = () =>
    window.postMessage(
      {
        type: "pipelineControl",
        pipeline: "webcam",
        enabled: !isWebcamActive,
      },
      window.location.origin
    );
  const handleGamepadToggle = () =>
    window.postMessage(
      { type: "gamepadControl", enabled: !isGamepadEnabled },
      window.location.origin
    );
  /**
   * Leaves fullscreen through whichever prefixed API exists. Entering is
   * handed to the core, which owns what each mode locks; exiting is the
   * browser's own call either way.
   */
  const exitFullscreen = () => {
    const exit = document.exitFullscreen || document.mozCancelFullScreen
      || document.webkitExitFullscreen || document.msExitFullscreen;
    if (exit) Promise.resolve(exit.call(document)).catch(() => {});
  };
  const handleGamingModeRequest = () => {
    if (document.fullscreenElement) exitFullscreen();
    else window.postMessage({ type: "requestGamingMode" }, window.location.origin);
  };
  const handleBrowserFullscreen = () => {
    if (document.fullscreenElement) exitFullscreen();
    else window.postMessage({ type: "requestFullscreen" }, window.location.origin);
  };
  const handleClipboardChange = (event) =>
    setDashboardClipboardContent(event.target.value);
  const clipboardImageInputRef = useRef(null);
  /**
   * Hands a picked image to the core's `clipboardImageUpdate` path (a File
   * is a Blob), which sends it through the binary clipboard exactly like a
   * focus-synced local clipboard image; any other file raises a warning
   * notification. Same contract as the wish dashboard.
   */
  const handleClipboardImageUpload = (event) => {
    const file = event.target.files && event.target.files[0];
    if (file && file.type.startsWith("image/")) {
      window.postMessage(
        { type: "clipboardImageUpdate", imageBlob: file },
        window.location.origin
      );
    } else if (file) {
      window.postMessage(
        {
          type: "fileUpload",
          payload: {
            status: "warning",
            fileName: "clipboard-image",
            message: t("notifications.clipboardImageRejected", {
              name: file.name,
              mime: file.type || "unknown",
            }),
          },
        },
        window.location.origin
      );
    }
    // Cleared so the same file can be picked again.
    event.target.value = "";
  };
  /** Pushes the edited clipboard text to the server on blur, never a truncated preview. */
  const handleClipboardBlur = (event) => {
    if (dashboardClipboardTruncated) return;
    window.postMessage(
      { type: "clipboardUpdateFromUI", text: event.target.value },
      window.location.origin
    );
  };
  const toggleTheme = () => {
    const newTheme = theme === "dark" ? "light" : "dark";
    setTheme(newTheme);
    localStorage.setItem("theme", newTheme);
  };
  /**
   * Switches the transport through `/api/switch`, then posts `mode` so the
   * core reloads into it. `window.__selkiesModeSwitching` is set before the
   * request because the server tears down the old peer (WebSocket close code
   * 4000) before it responds, and without the flag the active core would
   * surface a spurious "Server disconnected" alert. The request carries this
   * client's own session token, which a controller's is enough for; a stored
   * master token overrides it, and where neither is accepted a 401 prompts for
   * the master token once, keeps it in sessionStorage and retries, dropping one
   * the server rejects so the next attempt re-prompts. A viewer is refused 403
   * and is not asked for anything. A failed switch clears the flag again, since
   * no reload follows and a kept flag would hide a real disconnect.
   */
  const handleStreamModeChange = async (event) => {
    const newMode = event.target.value;
    console.log("Change of stream mode requested:", newMode);
    window.__selkiesModeSwitching = true;
    try {
      const MASTER_TOKEN_KEY = "selkies_master_token";
      const doSwitch = () => {
        const headers = sessionAuthHeaders({ "Content-Type": "application/json" });
        let storedToken = null;
        try { storedToken = sessionStorage.getItem(MASTER_TOKEN_KEY); } catch { /* sessionStorage unavailable */ }
        if (storedToken) headers["Authorization"] = `Bearer ${storedToken}`;
        return fetch(`${getRoutePrefix()}/api/switch`, {
          method: "POST",
          headers,
          credentials: "same-origin",
          body: JSON.stringify({ mode: newMode }),
        });
      };
      let response = await doSwitch();
      if (response.status === 401) {
        const entered = (typeof window !== "undefined" && window.prompt)
          ? window.prompt("Switching the stream mode requires the Rakko Remote Desktop master token:")
          : null;
        if (entered && entered.trim()) {
          try { sessionStorage.setItem(MASTER_TOKEN_KEY, entered.trim()); } catch { /* sessionStorage unavailable */ }
          response = await doSwitch();
        }
      }

      if (!response.ok) {
        if (response.status === 401) { try { sessionStorage.removeItem(MASTER_TOKEN_KEY); } catch { /* sessionStorage unavailable */ } }
        throw new Error(`Request failed with status ${response.status}`);
      }
      await response.json();
      setStreamMode(newMode);
      window.postMessage(
        { type: "mode", mode: newMode },
        window.location.origin
      );
    } catch (error) {
        window.__selkiesModeSwitching = false;
        console.error("Error switching stream mode:", error);
    }
  }
  const handleMouseEnter = (e, itemKey) => {
    setHoveredItem(itemKey);
    setTooltipPosition({ x: e.clientX + 10, y: e.clientY + 10 });
  };
  const handleMouseLeave = () => setHoveredItem(null);

  /** Touch gamepad toggle: `TOUCH_GAMEPAD_SETUP` on first activation, `TOUCH_GAMEPAD_VISIBILITY` afterwards. */
  const handleToggleTouchGamepad = useCallback(() => {
    const newActiveState = !isTouchGamepadActive;
    setIsTouchGamepadActive(newActiveState);

    if (newActiveState && !isTouchGamepadSetup) {
      window.postMessage(
        {
          type: "TOUCH_GAMEPAD_SETUP",
          payload: { targetDivId: TOUCH_GAMEPAD_HOST_DIV_ID, visible: true },
        },
        window.location.origin
      );
      setIsTouchGamepadSetup(true);
      console.log(
        "Dashboard: Touch Gamepad SETUP sent, targetDivId:",
        TOUCH_GAMEPAD_HOST_DIV_ID,
        "visible: true"
      );
    } else if (isTouchGamepadSetup) {
      window.postMessage(
        {
          type: "TOUCH_GAMEPAD_VISIBILITY",
          payload: {
            visible: newActiveState,
            targetDivId: TOUCH_GAMEPAD_HOST_DIV_ID,
          },
        },
        window.location.origin
      );
      console.log(
        `Dashboard: Touch Gamepad VISIBILITY sent, targetDivId:`,
        TOUCH_GAMEPAD_HOST_DIV_ID,
        `visible: ${newActiveState}`
      );
    }
  }, [isTouchGamepadActive, isTouchGamepadSetup]);

  const handleToggleTrackpadMode = useCallback(() => {
    const newActiveState = !isTrackpadModeActive;
    setIsTrackpadModeActive(newActiveState);
    const message = newActiveState ? "touchinput:trackpad" : "touchinput:touch";
    console.log(`Dashboard: Toggling trackpad mode. Sending: ${message}`);
    window.postMessage({ type: message }, window.location.origin);
  }, [isTrackpadModeActive]);

  /** Native touch is what direct touch does, and the emulated gestures' options do not apply. */
  const nativeTouchActive = touchOptions.native && touchOptions.nativeAvailable;
  /** Sends one direct-touch option to the core, which stores it and answers with `touchOptionsUpdate`. */
  const setTouchOption = useCallback((key, value) => {
    setTouchOptions((prev) => ({ ...prev, [key]: value }));
    window.postMessage({ type: "touchinput:options", options: { [key]: value } }, window.location.origin);
  }, []);

  /** Tooltip text for a stats gauge. */
  const getTooltipContent = useCallback(
    (itemKey) => {
      const memNA = t("sections.stats.tooltipMemoryNA");
      switch (itemKey) {
        case "cpu":
          return t("sections.stats.tooltipCpu", {
            value: cpuPercent.toFixed(1),
          });
        case "gpu":
          return t("sections.stats.tooltipGpu", {
            value: gpuPercent.toFixed(1),
          });
        case "sysmem": {
          const fu =
            sysMemUsed !== null ? formatBytes(sysMemUsed, 2, raw) : memNA;
          const ft =
            sysMemTotal !== null ? formatBytes(sysMemTotal, 2, raw) : memNA;
          return fu !== memNA && ft !== memNA
            ? t("sections.stats.tooltipSysMem", { used: fu, total: ft })
            : `${t("sections.stats.sysMemLabel")}: ${memNA}`;
        }
        case "gpumem": {
          const gu =
            gpuMemUsed !== null ? formatBytes(gpuMemUsed, 2, raw) : memNA;
          const gt =
            gpuMemTotal !== null ? formatBytes(gpuMemTotal, 2, raw) : memNA;
          return gu !== memNA && gt !== memNA
            ? t("sections.stats.tooltipGpuMem", { used: gu, total: gt })
            : `${t("sections.stats.gpuMemLabel")}: ${memNA}`;
        }
        case "fps":
          return t("sections.stats.tooltipFps", { value: clientFps });
        case "audio":
          return t("sections.stats.tooltipAudioLevel", { value: audioLevel });
        case "bandwidth":
          return t("sections.stats.tooltipBandwidth", { value: bandwidthMbps.toFixed(2) }, `Bandwidth: ${bandwidthMbps.toFixed(2)} Mbps`);
        case "latency":
          return t("sections.stats.tooltipLatency", { value: latencyMs.toFixed(1) }, `Latency: ${latencyMs.toFixed(1)} ms`);
        default:
          return "";
      }
    },
    [
      t,
      raw,
      cpuPercent,
      gpuPercent,
      sysMemUsed,
      sysMemTotal,
      gpuMemUsed,
      gpuMemTotal,
      clientFps,
      audioLevel,
      bandwidthMbps,
      latencyMs,
    ]
  );

  const removeNotification = useCallback((id) => {
    setNotifications((prev) => prev.filter((n) => n.id !== id));
    if (notificationTimeouts.current[id]) {
      clearTimeout(notificationTimeouts.current[id].fadeTimer);
      clearTimeout(notificationTimeouts.current[id].removeTimer);
      delete notificationTimeouts.current[id];
    }
  }, []);

  /** Fades a notification out shortly before `delay` and removes it at `delay`. */
  const scheduleNotificationRemoval = useCallback(
    (id, delay) => {
      if (notificationTimeouts.current[id]) {
        clearTimeout(notificationTimeouts.current[id].fadeTimer);
        clearTimeout(notificationTimeouts.current[id].removeTimer);
      }
      const fadeTimer = setTimeout(
        () =>
          setNotifications((prev) =>
            prev.map((n) => (n.id === id ? { ...n, fadingOut: true } : n))
          ),
        delay - NOTIFICATION_FADE_DURATION
      );
      const removeTimer = setTimeout(() => removeNotification(id), delay);
      notificationTimeouts.current[id] = { fadeTimer, removeTimer };
    },
    [removeNotification]
  );

  const handleUploadClick = () =>
    window.dispatchEvent(new CustomEvent("requestFileUpload"));

  /**
   * Polls the core's `window` stats into the gauges. The stats only render
   * inside the open sidebar, so the fifteen or so setState calls, each a full
   * Sidebar re-render, are skipped while it is closed or the tab is hidden.
   */
  useEffect(() => {
    const readStats = () => {
      if (!isOpen || document.hidden) return;
      const cs = window.system_stats,
        su = cs?.mem_used ?? null,
        st = cs?.mem_total ?? null;
      setCpuPercent(cs?.cpu_percent ?? 0);
      setSysMemUsed(su);
      setSysMemTotal(st);
      setSysMemPercent(
        su !== null && st !== null && st > 0 ? (su / st) * 100 : 0
      );
      const cgs = window.gpu_stats,
        gp = cgs?.gpu_percent ?? cgs?.utilization_gpu ?? 0;
      setGpuPercent(gp);
      const gu =
        cgs?.mem_used ?? cgs?.memory_used ?? cgs?.used_gpu_memory_bytes ?? null;
      const gt =
        cgs?.mem_total ??
        cgs?.memory_total ??
        cgs?.total_gpu_memory_bytes ??
        null;
      setGpuMemUsed(gu);
      setGpuMemTotal(gt);
      setGpuMemPercent(
        gu !== null && gt !== null && gt > 0 ? (gu / gt) * 100 : 0
      );
      setClientFps(window.fps ?? 0);
      // x141 is the websockets worklet's own scale (RMS x141, a full-scale sine
      // reads 100), applied to the WebRTC analyser's raw RMS so both match.
      const coreLevel = window.currentAudioLevel;
      const level = typeof coreLevel === "number"
        ? coreLevel
        : (readStreamAudioLevel(audioMeterRef) ?? 0) * 141;
      setAudioLevel(Math.min(100, Math.round(level)));
      const netStats = window.network_stats;
      setBandwidthMbps(netStats?.bandwidth_mbps ?? 0);
      setLatencyMs(netStats?.latency_ms ?? 0);
    };
    const intervalId = setInterval(readStats, STATS_READ_INTERVAL_MS);
    return () => clearInterval(intervalId);
  }, [isOpen]);

  /** The core message listener; the module docblock lists the message types handled. */
  useEffect(() => {
    const handleWindowMessage = (event) => {
      if (event.origin !== window.location.origin) return;
      const message = event.data;
      if (typeof message === "object" && message !== null) {
        if (message.type === "pipelineStatusUpdate") {
          if (message.video !== undefined) setIsVideoActive(message.video);
          if (message.audio !== undefined) setIsAudioActive(message.audio);
          if (message.microphone !== undefined)
            setIsMicrophoneActive(message.microphone);
          if (message.webcam !== undefined)
            setIsWebcamActive(message.webcam);
        } else if (message.type === "effectiveCursorState" && typeof message.value === "boolean") {
          setEffectiveCursor(message.value);
        } else if (message.type === 'clientRoleUpdate') {
          const viewer = message.role === 'viewer';
          setIsViewerRole(viewer);
          // A viewer gets no sidebar: the handle goes, and one opened before the demotion folds.
          if (viewer) {
            setIsToggleVisible(false);
            setIsOpen(false);
          }
        } else if (message.type === "toggleDashboard") {
          if (!isViewerRole) setIsOpen((prev) => !prev);
        } else if (message.type === "toggleTouchGamepad") {
          handleToggleTouchGamepad();
        } else if (message.type === "gamepadControl") {
          if (message.enabled !== undefined)
            setIsGamepadEnabled(message.enabled);
        } else if (message.type === "sidebarButtonStatusUpdate") {
          if (message.video !== undefined) setIsVideoActive(message.video);
          if (message.audio !== undefined) setIsAudioActive(message.audio);
          if (message.microphone !== undefined)
            setIsMicrophoneActive(message.microphone);
          if (message.webcam !== undefined)
            setIsWebcamActive(message.webcam);
          if (message.gamepad !== undefined)
            setIsGamepadEnabled(message.gamepad);
        } else if (message.type === "clipboardContentUpdate") {
          if (typeof message.text === "string") {
            setDashboardClipboardContent(message.text);
            setDashboardClipboardTruncated(message.truncated === true);
          }
        } else if (message.type === "audioDeviceSelected") {
          if (message.deviceId) {
            if (message.context === "input")
              setSelectedInputDeviceId(message.deviceId);
            else if (message.context === "output")
              setSelectedOutputDeviceId(message.deviceId);
          }
        } else if (
          message.type === "gamepadButtonUpdate" ||
          message.type === "gamepadAxisUpdate"
        ) {
          if (!hasReceivedGamepadData) setHasReceivedGamepadData(true);
          const gpIndex = message.gamepadIndex;
          if (gpIndex === undefined || gpIndex === null) return;
          setGamepadStates((prev) => {
            const ns = { ...prev };
            if (!ns[gpIndex]) ns[gpIndex] = { buttons: {}, axes: {} };
            else
              ns[gpIndex] = {
                buttons: { ...(ns[gpIndex].buttons || {}) },
                axes: { ...(ns[gpIndex].axes || {}) },
              };
            if (message.type === "gamepadButtonUpdate")
              ns[gpIndex].buttons[message.buttonIndex] = message.value || 0;
            else
              ns[gpIndex].axes[message.axisIndex] = Math.max(
                -1,
                Math.min(1, message.value || 0)
              );
            return ns;
          });
        } else if (message.type === "fileUpload") {
          const {
            status,
            fileName,
            progress,
            fileSize,
            message: errMsg,
            code,
          } = message.payload;
          // Settles the pending optimistic apps update first; a stale launch
          // match is lifecycle noise, not a notice.
          if (code === "commandFailed" && !resolveFailedAppCommand(errMsg))
            return;
          // An unknown or absent code keeps the raw message for third-party
          // consumers: the translator answers a miss with the key itself.
          const codeKey =
            typeof code === "string" &&
            (code.startsWith("clipboard") || code === "commandFailed" || code.startsWith("keyboardLock"))
              ? `notifications.${code}`
              : null;
          const codeMsg = codeKey ? t(codeKey, { detail: errMsg }) : null;
          const localizedMsg = codeMsg && codeMsg !== codeKey ? codeMsg : errMsg;
          const id = fileName;
          setNotifications((prev) => {
            const exIdx = prev.findIndex((n) => n.id === id);
            if (exIdx === -1) {
              if (prev.length < MAX_NOTIFICATIONS && status === "start")
                return [
                  ...prev,
                  {
                    id,
                    fileName,
                    status: "progress",
                    progress: 0,
                    fileSize,
                    message: null,
                    timestamp: Date.now(),
                    fadingOut: false,
                  },
                ];
              if (prev.length < MAX_NOTIFICATIONS && status === "warning") {
                scheduleNotificationRemoval(id, NOTIFICATION_TIMEOUT_SUCCESS);
                return [
                  ...prev,
                  {
                    id,
                    fileName: t("notifications.warningPrefix"),
                    status: "warn",
                    message: localizedMsg,
                    timestamp: Date.now(),
                    fadingOut: false,
                  }
                ];
              } else return prev;
            } else if (exIdx !== -1) {
              const un = [...prev],
                cn = un[exIdx];
              if (notificationTimeouts.current[id]) {
                clearTimeout(notificationTimeouts.current[id].fadeTimer);
                clearTimeout(notificationTimeouts.current[id].removeTimer);
                delete notificationTimeouts.current[id];
              }
              if (status === "progress")
                un[exIdx] = {
                  ...cn,
                  status: "progress",
                  progress,
                  timestamp: Date.now(),
                  fadingOut: false,
                };
              else if (status === "end") {
                un[exIdx] = {
                  ...cn,
                  status: "end",
                  progress: 100,
                  message: null,
                  timestamp: Date.now(),
                  fadingOut: false,
                };
                scheduleNotificationRemoval(id, NOTIFICATION_TIMEOUT_SUCCESS);
              } else if (status === "error") {
                const text = errMsg
                  ? `${t("notifications.errorPrefix")} ${errMsg}`
                  : t("notifications.unknownError");
                un[exIdx] = {
                  ...cn,
                  status: "error",
                  progress: 100,
                  message: text,
                  timestamp: Date.now(),
                  fadingOut: false,
                };
                scheduleNotificationRemoval(id, NOTIFICATION_TIMEOUT_ERROR);
              } else if (status === "warning") {
                  un[exIdx] = {
                    ...cn,
                    fileName: t("notifications.warningPrefix"),
                    status: "warn",
                    message: localizedMsg,
                    timestamp: Date.now(),
                    fadingOut: false,
                  };
                  scheduleNotificationRemoval(id, NOTIFICATION_TIMEOUT_ERROR);
              }
              return un;
            } else return prev;
          });
        } else if (message.type === "serverSettings") {
            const encoders = message.payload?.encoder?.allowed
            if (encoders && Array.isArray(encoders)) {
              const newEncoderOptions = offeredEncoders(
                Array.isArray(encoders) && encoders.length > 0
                  ? encoders
                  : (isWebrtc? encoderOptionsWR: encoderOptions));
              setDynamicEncoderOptions(newEncoderOptions);
          }
        } else if (message.type === "trackpadModeUpdate") {
          if (typeof message.enabled === 'boolean') {
            setIsTrackpadModeActive(message.enabled);
          }
        } else if (message.type === "touchOptionsUpdate") {
          if (message.options && typeof message.options === 'object') {
            setTouchOptions((prev) => ({ ...prev, ...message.options }));
          }
        } else if (message.type === "scalingDpiFollowed") {
          // The core's derived pick; a stored pick is the user's and stays.
          if (Number.isFinite(message.value) && readStored("scaling_dpi") === null) {
            setSelectedDpi(message.value);
          }
        }
      }
    };
    window.addEventListener("message", handleWindowMessage);
    window.postMessage({ type: "touchinput:options" }, window.location.origin);
    return () => {
      window.removeEventListener("message", handleWindowMessage);
      Object.values(notificationTimeouts.current).forEach((timers) => {
        clearTimeout(timers.fadeTimer);
        clearTimeout(timers.removeTimer);
      });
      notificationTimeouts.current = {};
    };
  }, [
    hasReceivedGamepadData,
    scheduleNotificationRemoval,
    removeNotification,
    handleToggleTouchGamepad,
    t,
    dynamicEncoderOptions,
    isOpen,
    isWebrtc,
    offeredEncoders,
    isViewerRole,
  ]);

  const gaugeSize = 80,
    gaugeStrokeWidth = 8,
    gaugeRadius = gaugeSize / 2 - gaugeStrokeWidth / 2;
  const gaugeCircumference = 2 * Math.PI * gaugeRadius,
    gaugeCenter = gaugeSize / 2;
  const cpuOffset = calculateGaugeOffset(
    cpuPercent,
    gaugeRadius,
    gaugeCircumference
  );
  const gpuOffset = calculateGaugeOffset(
    gpuPercent,
    gaugeRadius,
    gaugeCircumference
  );
  const sysMemOffset = calculateGaugeOffset(
    sysMemPercent,
    gaugeRadius,
    gaugeCircumference
  );
  const gpuMemOffset = calculateGaugeOffset(
    gpuMemPercent,
    gaugeRadius,
    gaugeCircumference
  );
  const fpsPercent = Math.min(
    100,
    (clientFps / (framerate || DEFAULT_FRAMERATE)) * 100
  );
  const fpsOffset = calculateGaugeOffset(
    fpsPercent,
    gaugeRadius,
    gaugeCircumference
  );
  const audioLevelOffset = calculateGaugeOffset(
    audioLevel,
    gaugeRadius,
    gaugeCircumference
  );
  /**
   * Full scale of the bandwidth gauge: the traffic the session is configured
   * for (video target in kbps plus audio in bps), not an arbitrary link speed.
   */
  const maxBandwidthMbps = Math.max(0.1, videoBitrate / 1000 + audioBitrate / 1_000_000);
  const MAX_LATENCY_MS = 1000;
  const bandwidthPercent = Math.min(100, (bandwidthMbps / maxBandwidthMbps) * 100);
  const bandwidthOffset = calculateGaugeOffset(
    bandwidthPercent,
    gaugeRadius,
    gaugeCircumference
  );
  const latencyPercent = Math.min(100, (latencyMs / MAX_LATENCY_MS) * 100);
  const latencyOffset = calculateGaugeOffset(
    latencyPercent,
    gaugeRadius,
    gaugeCircumference
  );
  const translatedCommonResolutions = commonResolutionValues.map(
    (value, index) => ({
      value: value,
      text:
        index === 0
          ? t("sections.screen.resolutionPresetSelect")
          : raw?.resolutionPresets?.[value] || value,
    })
  );

  /** One encoder knob serves both transports; CBR/CRF applies to every H.264 encoder on both. */
  const activeEncoder = encoder;
  const H264_ENCODERS = ["h264enc", "h264enc-striped", "nvh264enc"];
  const showFPS = [
    "jpeg",
    "h264enc-striped",
    "h264enc",
  ].includes(encoder);
  const showCRF = H264_ENCODERS.includes(activeEncoder);
  const showH264Options = H264_ENCODERS.includes(activeEncoder);
  const showJpegOptions = encoder === 'jpeg';
  const showPaintOverQualityToggle = showH264Options || showJpegOptions;
  /**
   * The mode the encoder is actually using, which picks the quality slider:
   * the server's when rate control is disabled.
   */
  const appliedRateControlMode = rateControlEnabled
    ? rateControlMode
    : (serverSettings?.rate_control_mode?.value ?? rateControlMode);

  /**
   * CBR slider stops within the server's range: the sub-Mbps steps, 1000-kbps
   * steps to 100000, then the coarse steps to 1000000.
   */
  const videoBitrateOptions = (() => {
    const min = serverSettings?.video_bitrate?.min ?? 100;
    const max = serverSettings?.video_bitrate?.max ?? 1000000;
    const stops = SUB_MBPS_BITRATE_STEPS.filter((v) => v >= min && v <= max);
    for (let v = Math.max(1000, Math.ceil(min / 1000) * 1000); v <= Math.min(100000, Math.floor(max / 1000) * 1000); v += 1000) stops.push(v);
    stops.push(...COARSE_MBPS_BITRATE_STEPS.filter((v) => v >= min && v <= max));
    return stops.length ? stops : [min];
  })();
  const bitrateSliderIndex = (() => {
    const exact = videoBitrateOptions.indexOf(videoBitrate);
    if (exact >= 0) return exact;
    const above = videoBitrateOptions.findIndex((v) => v >= videoBitrate);
    return above >= 0 ? above : videoBitrateOptions.length - 1;
  })();
  const formatBitrate = (v) => `${v / 1000} Mbps`;
  if (serverSettings && serverSettings.ui_show_sidebar?.value === false) {
    return null;
  }
  const sidebarClasses = `sidebar ${isOpen ? "is-open" : ""} theme-${theme}`;
  const showCoreButtons = !isSecondaryDisplay && (renderableSettings.coreButtons ?? true);
  // Touch-only tiles sharing the action row: they wrap below the core five at
  // the same size instead of forming a differently sized bar of their own.
  const showKeyboardTile =
    (isMobile || hasDetectedTouch) && (renderableSettings.softButtons ?? true);
  const showTrackpadTile =
    (isMobile || hasDetectedTouch) && (renderableSettings.trackpad ?? true);
  const filteredSharingLinks = sharingLinks.filter(link => {
    if (link.id === 'shared') return renderableSettings.enableShared ?? true;
    if (link.id === 'player2') return renderableSettings.enablePlayer2 ?? true;
    if (link.id === 'player3') return renderableSettings.enablePlayer3 ?? true;
    if (link.id === 'player4') return renderableSettings.enablePlayer4 ?? true;
    return false;
  });

  return (
    <>
      {isToggleVisible && !isGamingMode && (
        <div
          className='toggle-handle'
          onClick={onToggleHandleClick}
          onPointerDown={handleTogglePointerDown}
          onPointerMove={handleTogglePointerMove}
          onPointerUp={handleTogglePointerUp}
          onPointerCancel={handleTogglePointerUp}
          style={{ top: `${toggleHandleTopPct}%`, touchAction: 'none' }}
          title={isOpen ? t("closeDashboardTitle") : t("openDashboardTitle")}
        >
          <div className="toggle-indicator"></div>
        </div>
      )}
      {availablePlacements && (() => {
        const handleArrowClick = (e, direction, screen) => {
          e.stopPropagation();
          launchWindow(direction, screen);
        };
        return (
          <div className={`screen-placement-overlay theme-${theme}`} onClick={() => setAvailablePlacements(null)}>
            {availablePlacements.up !== undefined && (
              <button className="screen-placement-arrow up" onClick={(e) => handleArrowClick(e, 'up', availablePlacements.up)}>▲</button>
            )}
            {availablePlacements.down !== undefined && (
              <button className="screen-placement-arrow down" onClick={(e) => handleArrowClick(e, 'down', availablePlacements.down)}>▼</button>
            )}
            {availablePlacements.left !== undefined && (
              <button className="screen-placement-arrow left" onClick={(e) => handleArrowClick(e, 'left', availablePlacements.left)}>◄</button>
            )}
            {availablePlacements.right !== undefined && (
              <button className="screen-placement-arrow right" onClick={(e) => handleArrowClick(e, 'right', availablePlacements.right)}>►</button>
            )}
          </div>
        );
      })()}
      <div className={sidebarClasses}>
          <div className="sidebar-header">
            {uiShowLogo ? (
              <a
                className="sidebar-brand"
                href="https://github.com/selkies-project/selkies"
                target="_blank"
                rel="noopener noreferrer"
              >
                <img className="sidebar-brand-mark" src={brandWordmarkUrl} alt={uiTitle} />
              </a>
            ) : (
              <a
                href="https://github.com/selkies-project/selkies"
                target="_blank"
                rel="noopener noreferrer"
              >
                <h2>{uiTitle}</h2>
              </a>
            )}
            <div className="header-controls">
            <div
              className={`theme-toggle ${theme}`}
              onClick={toggleTheme}
              title={t("toggleThemeTitle")}
            >
              <svg className="icon moon-icon" viewBox="0 0 24 24">
                <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path>
              </svg>
              <svg className="icon sun-icon" viewBox="0 0 24 24">
                <circle cx="12" cy="12" r="5"></circle>
                <line x1="12" y1="1" x2="12" y2="3"></line>
                <line x1="12" y1="21" x2="12" y2="23"></line>
                <line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line>
                <line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line>
                <line x1="1" y1="12" x2="3" y2="12"></line>
                <line x1="21" y1="12" x2="23" y2="12"></line>
                <line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line>
                <line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line>
              </svg>
            </div>
            {(renderableSettings.fullscreen ?? true) && (
              <button
                className="header-action-button fullscreen-button"
                onClick={handleBrowserFullscreen}
                title={t("fullscreenTitle")}
              >
                <FullscreenIcon />
              </button>
            )}
            {(renderableSettings.gamingMode ?? true) && (
              <button
                className="header-action-button gaming-mode-button"
                onClick={handleGamingModeRequest}
                title={`${t("gamingModeTitle", "Gaming Mode")} \u2014 ${t("gamingModeHint", "Fullscreen with the pointer and keyboard locked")}`}
              >
                <GamingModeIcon />
              </button>
            )}
          </div>
        </div>

        {(showCoreButtons || showKeyboardTile || showTrackpadTile) && (
          <div className="sidebar-action-buttons">
            {showCoreButtons && (renderableSettings.videoToggle ?? true) && (
              <button
                className={`action-button ${isVideoActive ? "active" : ""}`}
                onClick={handleVideoToggle}
                title={t(
                  isVideoActive
                    ? "buttons.videoStreamDisableTitle"
                    : "buttons.videoStreamEnableTitle"
                )}
              >
                <ScreenIcon />
              </button>
            )}
            {showCoreButtons && (renderableSettings.audioToggle ?? true) && (
              <button
                className={`action-button ${isAudioActive ? "active" : ""}`}
                onClick={handleAudioToggle}
                title={t(
                  isAudioActive
                    ? "buttons.audioStreamDisableTitle"
                    : "buttons.audioStreamEnableTitle"
                )}
              >
                <SpeakerIcon />
              </button>
            )}
            {showCoreButtons && (renderableSettings.microphoneToggle ?? true) && (
              <button
                className={`action-button ${isMicrophoneActive ? "active" : ""}`}
                onClick={handleMicrophoneToggle}
                title={t(
                  isMicrophoneActive
                    ? "buttons.microphoneDisableTitle"
                    : "buttons.microphoneEnableTitle"
                )}
              >
                <MicrophoneIcon />
              </button>
            )}
            {showCoreButtons && (renderableSettings.webcamToggle ?? true) && (
              <button
                className={`action-button ${isWebcamActive ? "active" : ""}`}
                onClick={handleWebcamToggle}
                title={t(
                  isWebcamActive
                    ? "buttons.webcamDisableTitle"
                    : "buttons.webcamEnableTitle"
                )}
              >
                <WebcamIcon />
              </button>
            )}
            {showCoreButtons && (renderableSettings.gamepadToggle ?? true) && (
              <button
                className={`action-button ${isGamepadEnabled ? "active" : ""}`}
                onClick={handleGamepadToggle}
                title={t(
                  isGamepadEnabled
                    ? "buttons.gamepadDisableTitle"
                    : "buttons.gamepadEnableTitle"
                )}
              >
                <GamepadIcon />
              </button>
            )}
            {showKeyboardTile && (
              <button
                className={`action-button keyboard-toggle-button ${isKeyboardButtonVisible ? "active" : ""}`}
                onClick={toggleKeyboardButtonVisibility}
                title={t("keyboardButtonToggleTitle", "Keyboard Button")}
              >
                <KeyboardIcon />
              </button>
            )}
            {showTrackpadTile && (
              <button
                className={`action-button trackpad-mode-button ${isTrackpadModeActive ? "active" : ""}`}
                onClick={handleToggleTrackpadMode}
                title={t("trackpadModeTitle", "Trackpad Mode")}
              >
                <TrackpadIcon />
              </button>
            )}
          </div>
        )}
        
        {(isMobile || hasDetectedTouch) && (renderableSettings.softButtons ?? true) && (
            <div className="sidebar-mobile-key-actions">
              <button
                className={`mobile-key-button ${heldKeys.Control ? "active" : ""}`}
                onClick={() => handleHoldKeyClick('Control', 'ControlLeft')}
                onMouseDown={(e) => e.preventDefault()}
              >
                CTL
              </button>
              <button
                className={`mobile-key-button ${heldKeys.Alt ? "active" : ""}`}
                onClick={() => handleHoldKeyClick('Alt', 'AltLeft')}
                onMouseDown={(e) => e.preventDefault()}
              >
                ALT
              </button>
              <button
                className={`mobile-key-button ${heldKeys.Meta ? "active" : ""}`}
                onClick={() => handleHoldKeyClick('Meta', 'MetaLeft')}
                onMouseDown={(e) => e.preventDefault()}
              >
                WIN
              </button>
              <button
                className="mobile-key-button"
                onClick={() => handleOnceKeyClick('Tab', 'Tab')}
                onMouseDown={(e) => e.preventDefault()}
              >
                TAB
              </button>
              <button
                className="mobile-key-button"
                onClick={() => handleOnceKeyClick('Escape', 'Escape')}
                onMouseDown={(e) => e.preventDefault()}
              >
                ESC
              </button>
            </div>
        )}

        {/* Viewers can't apply stream settings (the server ignores their
            SETTINGS payloads); hide the posting sections instead of rendering
            controls that silently do nothing. */}
        {!isViewerRole && (renderableSettings.videoSettings ?? true) && (
          <div className="sidebar-section">
            <div
              className="sidebar-section-header"
              onClick={() => toggleSection("settings")}
              role="button"
              aria-expanded={sectionsOpen.settings}
              aria-controls="settings-content"
              tabIndex="0"
              onKeyDown={(e) =>
                (e.key === "Enter" || e.key === " ") && toggleSection("settings")
              }
            >
              <h3>{t("sections.video.title")}</h3>
              <span className="section-toggle-icon">
                {sectionsOpen.settings ? <CaretUpIcon /> : <CaretDownIcon />}
              </span>
            </div>
            {sectionsOpen.settings && (
                <div className="sidebar-section-content" id="settings-content">
                  {((renderableSettings.enableDualMode ?? window.__SELKIES_DUAL_MODE__) ?? false) && !isViewerRole && (
                    <div className="dev-setting-item">
                      {" "}
                      <label htmlFor="streamModeSelect">
                        {t("streamingModeTitle", "Streaming Mode")}
                      </label>{" "}
                      <select
                        id="streamModeSelect"
                        value={streamMode}
                        onChange={handleStreamModeChange}
                      >
                        {" "}
                        {STREAMING_MODES.map((mode) => (
                          <option key={mode} value={mode}>
                            {displayLabel(mode)}
                          </option>
                        ))}{" "}
                      </select>{" "}
                    </div>
                  )}
                {(renderableSettings.encoder ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="encoderSelect">
                      {t("sections.video.encoderLabel")}
                    </label>
                    <select
                      id="encoderSelect"
                      value={encoder}
                      onChange={handleEncoderChange}
                      disabled={!serverSettings || dynamicEncoderOptions.length <= 1}
                    >
                      {dynamicEncoderOptions.map((enc) => (
                        <option key={enc} value={enc}>
                          {displayLabel(enc)}
                        </option>
                      ))}
                    </select>
                  </div>
                )}
                {!isWebrtc && (renderableSettings.webcamEncoder ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="webcamEncoderSelect">
                      {t("sections.video.webcamEncoderLabel")}
                    </label>
                    <select
                      id="webcamEncoderSelect"
                      value={webcamEncoder}
                      onChange={handleWebcamEncoderChange}
                      disabled={!serverSettings || !!serverSettings.webcam_encoder?.locked}
                    >
                      {webcamEncoderOptions.map((pref) => (
                        <option key={pref} value={pref}>
                          {displayLabel(pref)}
                        </option>
                      ))}
                    </select>
                  </div>
                )}
                {rateControlEnabled && showH264Options && (
                  <div className="dev-setting-item">
                    <label htmlFor="rateControlSelect">
                      {t("sections.video.rateControlLabel")}
                    </label>
                    <select
                      id="rateControlSelect"
                      value={rateControlMode}
                      onChange={handleRateControlChange}
                      disabled={!serverSettings || serverSettings.rate_control_mode?.allowed?.length <= 1}
                    >
                      {(serverSettings?.rate_control_mode?.allowed || rateControlOptions).map((rc) => (
                        <option key={rc} value={rc}>
                          {displayLabel(rc)}
                        </option>
                      ))}
                    </select>
                  </div>
                )}
                {(isWebrtc || showFPS) && (renderableSettings.framerate ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="framerateSlider">
                      {t("sections.video.framerateLabel", {
                        framerate: framerate,
                      })}
                    </label>
                    <input
                      type="range"
                      id="framerateSlider"
                      min={serverSettings?.framerate?.min || 8}
                      max={serverSettings?.framerate?.max || 240}
                      step="1"
                      value={framerate}
                      onChange={handleFramerateChange}
                      disabled={!serverSettings || serverSettings.framerate?.min === serverSettings.framerate?.max}
                    />
                  </div>
                )}
                {showH264Options && appliedRateControlMode === RATE_CONTROL_CBR && (renderableSettings.video_bitrate ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="videoBitrateSlider">
                      {t("sections.video.bitrateLabel", {
                        bitrate: formatBitrate(videoBitrate),
                      })}
                    </label>
                    <input
                      type="range"
                      id="videoBitrateSlider"
                      min={0}
                      max={videoBitrateOptions.length - 1}
                      step="1"
                      value={bitrateSliderIndex}
                      onChange={handleVideoBitrateChange}
                      disabled={!serverSettings || serverSettings.video_bitrate?.min === serverSettings.video_bitrate?.max}
                    />
                  </div>
                )}
                {!isWebrtc && showJpegOptions && (
                  <>
                    {(renderableSettings.jpeg_quality ?? true) && (
                      <div className="dev-setting-item">
                        <label htmlFor="jpegQualitySlider">
                          {t("sections.video.jpegQualityLabel", {
                            jpegQuality: jpeg_quality,
                          })}
                        </label>
                        <input
                          type="range"
                          id="jpegQualitySlider"
                          min={serverSettings?.jpeg_quality?.min || 1}
                          max={serverSettings?.jpeg_quality?.max || 100}
                          step="1"
                          value={jpeg_quality}
                          onChange={handleJpegQualityChange}
                          disabled={!serverSettings || serverSettings.jpeg_quality?.min === serverSettings.jpeg_quality?.max}
                        />
                      </div>
                    )}
                  </>
                )}
                {showCRF && appliedRateControlMode === RATE_CONTROL_CRF && (renderableSettings.video_crf ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="videoCRFSlider">
                      {t("sections.video.crfLabel", { crf: video_crf })}
                    </label>
                    <input
                      type="range"
                      id="videoCRFSlider"
                      min={serverSettings?.video_crf?.min || 5}
                      max={serverSettings?.video_crf?.max || 50}
                      step="1"
                      value={video_crf}
                      onChange={handleVideoCRFChange}
                      disabled={!serverSettings || serverSettings.video_crf?.min === serverSettings.video_crf?.max}
                      style={{ direction: 'rtl' }}
                    />
                  </div>
                )}
                {showPaintOverQualityToggle && (renderableSettings.usePaintOverQuality ?? true) && (
                  <div className="dev-setting-item toggle-item">
                    <label htmlFor="usePaintOverQualityToggle">
                      {t("sections.video.usePaintOverQualityLabel", "Use Paint-Over Quality")}
                    </label>
                    <button
                      id="usePaintOverQualityToggle"
                      className={`toggle-button-sidebar ${usePaintOverQuality ? "active" : ""}`}
                      onClick={handleUsePaintOverQualityToggle}
                      aria-pressed={usePaintOverQuality}
                      disabled={!serverSettings || serverSettings.use_paint_over_quality?.locked}
                      title={t(usePaintOverQuality ? "buttons.usePaintOverQualityDisableTitle" : "buttons.usePaintOverQualityEnableTitle")}
                    >
                      <span className="toggle-button-sidebar-knob"></span>
                    </button>
                  </div>
                )}
                {showCRF && usePaintOverQuality && (renderableSettings.videoPaintoverCRF ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="videoPaintoverCRFSlider">
                      {t("sections.video.paintoverCrfLabel", { crf: videoPaintoverCRF })}
                    </label>
                    <input
                      type="range"
                      id="videoPaintoverCRFSlider"
                      min={serverSettings?.video_paintover_crf?.min || 5}
                      max={serverSettings?.video_paintover_crf?.max || 50}
                      step="1"
                      value={videoPaintoverCRF}
                      onChange={handleH264PaintoverCRFChange}
                      disabled={!serverSettings || serverSettings.video_paintover_crf?.min === serverSettings.video_paintover_crf?.max}
                      style={{ direction: 'rtl' }}
                    />
                  </div>
                )}
                {showH264Options && usePaintOverQuality && (renderableSettings.videoPaintoverBurstFrames ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="videoPaintoverBurstSlider">
                      {t("sections.video.paintoverBurstLabel", { frames: videoPaintoverBurstFrames }, `Paint-over Burst Frames: ${videoPaintoverBurstFrames}`)}
                    </label>
                    <input
                      type="range"
                      id="videoPaintoverBurstSlider"
                      min={serverSettings?.video_paintover_burst_frames?.min || 1}
                      max={serverSettings?.video_paintover_burst_frames?.max || 30}
                      step="1"
                      value={videoPaintoverBurstFrames}
                      onChange={handleH264PaintoverBurstChange}
                      disabled={!serverSettings || serverSettings.video_paintover_burst_frames?.min === serverSettings.video_paintover_burst_frames?.max}
                    />
                  </div>
                )}
                {!isWebrtc && showJpegOptions && usePaintOverQuality && (renderableSettings.paint_over_jpeg_quality ?? true) && (
                  <div className="dev-setting-item">
                    <label htmlFor="paintOverJpegQualitySlider">
                      {t("sections.video.paintOverJpegQualityLabel", {
                        paintOverJpegQuality: paint_over_jpeg_quality,
                      })}
                    </label>
                    <input
                      type="range"
                      id="paintOverJpegQualitySlider"
                      min={serverSettings?.paint_over_jpeg_quality?.min || 1}
                      max={serverSettings?.paint_over_jpeg_quality?.max || 100}
                      step="1"
                      value={paint_over_jpeg_quality}
                      onChange={handlePaintOverJpegQualityChange}
                      disabled={!serverSettings || serverSettings.paint_over_jpeg_quality?.min === serverSettings.paint_over_jpeg_quality?.max}
                    />
                  </div>
                )}
                {showH264Options && (renderableSettings.videoStreamingMode ?? true) && (
                  <div className="dev-setting-item toggle-item">
                    <label 
                      htmlFor="videoStreamingModeToggle"
                      title={t("sections.video.streamingModeDetails")}
                    >
                      {t("sections.video.streamingModeLabel", "Turbo")}
                    </label>
                    <button
                      id="videoStreamingModeToggle"
                      className={`toggle-button-sidebar ${videoStreamingMode ? "active" : ""}`}
                      onClick={handleH264StreamingModeToggle}
                      aria-pressed={videoStreamingMode}
                      disabled={!serverSettings || serverSettings.video_streaming_mode?.locked}
                      title={t(videoStreamingMode ? "buttons.videoStreamingModeDisableTitle" : "buttons.videoStreamingModeEnableTitle")}
                    >
                      <span className="toggle-button-sidebar-knob"></span>
                    </button>
                  </div>
                )}
                {!isWebrtc && serverSettings?.adaptive_frame_drop
                  && (renderableSettings.adaptiveFrameDrop ?? true) && (
                  <div className="dev-setting-item toggle-item">
                    <label
                      htmlFor="adaptiveFrameDropToggle"
                      title={t("sections.video.adaptiveFrameDropDetails")}
                    >
                      {t("sections.video.adaptiveFrameDropLabel", "Adaptive frame drop")}
                    </label>
                    <button
                      id="adaptiveFrameDropToggle"
                      className={`toggle-button-sidebar ${adaptiveFrameDrop ? "active" : ""}`}
                      onClick={handleAdaptiveFrameDropToggle}
                      aria-pressed={adaptiveFrameDrop}
                      disabled={!serverSettings || serverSettings.adaptive_frame_drop?.locked}
                      title={t("sections.video.adaptiveFrameDropDetails")}
                    >
                      <span className="toggle-button-sidebar-knob"></span>
                    </button>
                  </div>
                )}
                {showH264Options && (renderableSettings.videoFullColor ?? true) && fullColorDecodable && (
                  <div className="dev-setting-item toggle-item">
                    <label htmlFor="videoFullColorToggle">
                      {t("sections.video.fullColorLabel")}
                    </label>
                    <button
                      id="videoFullColorToggle"
                      className={`toggle-button-sidebar ${videoFullColor ? "active" : ""}`}
                      onClick={handleH264FullColorToggle}
                      aria-pressed={videoFullColor}
                      disabled={!serverSettings || serverSettings.video_fullcolor?.locked}
                      title={t(videoFullColor ? "buttons.videoFullColorDisableTitle" : "buttons.videoFullColorEnableTitle")}
                    >
                      <span className="toggle-button-sidebar-knob"></span>
                    </button>
                  </div>
                )}
                {/* use_cpu only matters for full-frame h264enc; the server forces it true
                    for jpeg and striped on both transports. */}
                {activeEncoder === 'h264enc' && (renderableSettings.use_cpu ?? true) && (
                  <div className="dev-setting-item toggle-item">
                    <label htmlFor="useCpuToggle">
                      {t("sections.video.useCpuLabel", "CPU Encoding")}
                    </label>
                    <button
                      id="useCpuToggle"
                      className={`toggle-button-sidebar ${use_cpu ? "active" : ""}`}
                      onClick={handleUseCpuToggle}
                      aria-pressed={use_cpu}
                      disabled={!serverSettings || serverSettings.use_cpu?.locked}
                      title={t(use_cpu ? "buttons.useCpuDisableTitle" : "buttons.useCpuEnableTitle")}
                    >
                      <span className="toggle-button-sidebar-knob"></span>
                    </button>
                  </div>
                )}
              </div>
            )}
          </div>
        )}

        {!isViewerRole && (renderableSettings.screenSettings ?? true) && (
          <div className="sidebar-section">
            <div
              className="sidebar-section-header"
              onClick={() => toggleSection("screenSettings")}
              role="button"
              aria-expanded={sectionsOpen.screenSettings}
              aria-controls="screen-settings-content"
              tabIndex="0"
              onKeyDown={(e) =>
                (e.key === "Enter" || e.key === " ") &&
                toggleSection("screenSettings")
              }
            >
              <h3>{t("sections.screen.title")}</h3>
              <span className="section-toggle-icon">
                {sectionsOpen.screenSettings ? (
                  <CaretUpIcon />
                ) : (
                  <CaretDownIcon />
                )}
              </span>
            </div>
            {sectionsOpen.screenSettings && (
              <div
                className="sidebar-section-content"
                id="screen-settings-content"
              >
                {!isSecondaryDisplay && (
                  <>
                    {serverSettings?.second_screen?.value && (
                      <button
                        className="resolution-button toggle-button"
                        onClick={handleAddScreenClick}
                        style={{ marginBottom: "10px" }}
                        title={t("sections.screen.addScreenTitle", "Add a second screen")}
                      >
                        {t("sections.screen.addScreenButton", "Add Screen +")}
                      </button>
                    )}
                    {(renderableSettings.forceAlignedResolution ?? true) && (
                      <div className="dev-setting-item toggle-item">
                        <label
                          htmlFor="forceAlignedResolutionToggle"
                          title={t("sections.screen.forceAlignedResolutionDetails", "Forces the display resolution to be a multiple of 16 pixels")}
                        >
                          {t("sections.screen.forceAlignedResolutionLabel", "Force Aligned Resolution")}
                        </label>
                        <button
                          id="forceAlignedResolutionToggle"
                          className={`toggle-button-sidebar ${forceAlignedResolution ? "active" : ""}`}
                          onClick={handleForceAlignedResolutionToggle}
                          aria-pressed={forceAlignedResolution}
                          disabled={!serverSettings || serverSettings.force_aligned_resolution?.locked}
                          title={t(forceAlignedResolution ? "sections.screen.forceAlignedResolutionDisableTitle" : "sections.screen.forceAlignedResolutionEnableTitle", forceAlignedResolution ? "Disable Force Aligned Resolution" : "Enable Force Aligned Resolution")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    <div className="dev-setting-item toggle-item">
                      <label htmlFor="antiAliasingToggle">
                        {t("sections.screen.antiAliasingLabel", "Anti-aliasing")}
                      </label>
                      <button
                        id="antiAliasingToggle"
                        className={`toggle-button-sidebar ${antiAliasing ? "active" : ""}`}
                        onClick={handleAntiAliasingToggle}
                        aria-pressed={antiAliasing}
                        title={t(antiAliasing ? "sections.screen.antiAliasingDisableTitle" : "sections.screen.antiAliasingEnableTitle",
                                  antiAliasing ? "Disable anti-aliasing (force pixelated)" : "Enable anti-aliasing (smooth on scaling)")}
                      >
                        <span className="toggle-button-sidebar-knob"></span>
                      </button>
                    </div>
                    {(renderableSettings.use_browser_cursors ?? true) && (
                      <div className="dev-setting-item toggle-item">
                        <label htmlFor="useBrowserCursorsToggle">
                          {t("sections.screen.useNativeCursorStylesLabel", "Use CSS cursors")}
                        </label>
                        <button
                          id="useBrowserCursorsToggle"
                          className={`toggle-button-sidebar ${(effectiveCursor !== null ? effectiveCursor : use_browser_cursors) ? "active" : ""}`}
                          onClick={handleUseBrowserCursorsToggle}
                          aria-pressed={effectiveCursor !== null ? effectiveCursor : use_browser_cursors}
                          title={t(use_browser_cursors ? "sections.screen.useNativeCursorStylesDisableTitle" : "sections.screen.useNativeCursorStylesEnableTitle",
                                  use_browser_cursors ? "Use canvas cursor rendering (Paint to canvas)" : "Use CSS cursor rendering (Replace system cursors)")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    {(renderableSettings.rawPointerMotion ?? true) && (
                      <div className="dev-setting-item toggle-item">
                        <label htmlFor="rawPointerMotionToggle">
                          {t("sections.screen.rawPointerMotionLabel", "Raw pointer motion")}
                        </label>
                        <button
                          id="rawPointerMotionToggle"
                          className={`toggle-button-sidebar ${rawPointerMotion ? "active" : ""}`}
                          onClick={handleRawPointerMotionToggle}
                          aria-pressed={rawPointerMotion}
                          title={t(rawPointerMotion ? "sections.screen.rawPointerMotionDisableTitle" : "sections.screen.rawPointerMotionEnableTitle",
                                  rawPointerMotion ? "Keep this device's pointer acceleration under pointer lock"
                                    : "Ask the browser for unaccelerated movement under pointer lock (granted on Windows and macOS, refused on Linux and Android)")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    {(renderableSettings.macCmdAsCtrl ?? false) && (
                      <div className="dev-setting-item toggle-item">
                        <label htmlFor="macCmdAsCtrlToggle">
                          {t("sections.screen.macCmdAsCtrlLabel", "Command sends Control")}
                        </label>
                        <button
                          id="macCmdAsCtrlToggle"
                          className={`toggle-button-sidebar ${macCmdAsCtrl ? "active" : ""}`}
                          onClick={handleMacCmdAsCtrlToggle}
                          aria-pressed={macCmdAsCtrl}
                          title={t(macCmdAsCtrl ? "sections.screen.macCmdAsCtrlDisableTitle" : "sections.screen.macCmdAsCtrlEnableTitle",
                                  macCmdAsCtrl ? "Send Command as the Super key the session's window manager may bind"
                                    : "Send Command chords as their Control chords, so Cmd+C copies remotely")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    {(isMobile || hasDetectedTouch) && touchOptions.nativeAvailable && (
                      <div className="dev-setting-item toggle-item">
                        <label htmlFor="touchNativeToggle">
                          {t("sections.screen.touchNativeLabel", "Native touch")}
                        </label>
                        <button
                          id="touchNativeToggle"
                          className={`toggle-button-sidebar ${touchOptions.native ? "active" : ""}`}
                          onClick={() => setTouchOption("native", !touchOptions.native)}
                          aria-pressed={touchOptions.native}
                          title={t("sections.screen.touchNativeTitle", "Send fingers to the remote desktop as a touchscreen, so apps scroll, zoom and drag windows themselves; turn off for apps that select text when dragged")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    {(isMobile || hasDetectedTouch) && !nativeTouchActive && (
                      <div className="dev-setting-item toggle-item">
                        <label htmlFor="touchSwipeScrollToggle">
                          {t("sections.screen.touchSwipeScrollLabel", "Swipe to scroll")}
                        </label>
                        <button
                          id="touchSwipeScrollToggle"
                          className={`toggle-button-sidebar ${touchOptions.swipeScroll ? "active" : ""}`}
                          onClick={() => setTouchOption("swipeScroll", !touchOptions.swipeScroll)}
                          aria-pressed={touchOptions.swipeScroll}
                          title={t("sections.screen.touchSwipeScrollTitle", "One finger scrolls; double-tap and hold, or hold until the ring fills, then move, to drag")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    {(isMobile || hasDetectedTouch) && !nativeTouchActive && (
                      <div className="dev-setting-item toggle-item">
                        <label htmlFor="touchInertiaToggle">
                          {t("sections.screen.touchInertiaLabel", "Scroll inertia")}
                        </label>
                        <button
                          id="touchInertiaToggle"
                          className={`toggle-button-sidebar ${touchOptions.inertia ? "active" : ""}`}
                          onClick={() => setTouchOption("inertia", !touchOptions.inertia)}
                          aria-pressed={touchOptions.inertia}
                          title={t("sections.screen.touchInertiaTitle", "Keep scrolling after a flick")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    {(isMobile || hasDetectedTouch) && !nativeTouchActive && (
                      <div className="dev-setting-item toggle-item">
                        <label htmlFor="touchPinchZoomToggle">
                          {t("sections.screen.touchPinchZoomLabel", "Pinch to zoom view")}
                        </label>
                        <button
                          id="touchPinchZoomToggle"
                          className={`toggle-button-sidebar ${touchOptions.pinchZoom ? "active" : ""}`}
                          onClick={() => setTouchOption("pinchZoom", !touchOptions.pinchZoom)}
                          aria-pressed={touchOptions.pinchZoom}
                          title={t("sections.screen.touchPinchZoomTitle", "Pinch to zoom the local view of the stream; the remote desktop's size is unchanged")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    {(isMobile || hasDetectedTouch) && !nativeTouchActive && (
                      <div className="dev-setting-item">
                        <label htmlFor="touchLongPressSelect">
                          {t("sections.screen.touchLongPressLabel", "Long press for right-click")}
                        </label>
                        <select
                          id="touchLongPressSelect"
                          value={String(touchOptions.longPressMs)}
                          onChange={(e) => setTouchOption("longPressMs", parseInt(e.target.value, 10))}
                          title={t("sections.screen.touchLongPressTitle", "How long to hold before the ring fills and lifting right-clicks")}
                        >
                          {[400, 600, 800, 1000].map((ms) => (
                            <option key={ms} value={String(ms)}>{`${ms} ms`}</option>
                          ))}
                        </select>
                      </div>
                    )}
                    {(renderableSettings.renderScale ?? true) && (
                      <div className="dev-setting-item">
                        <label htmlFor="renderScaleSelect">
                          {t("sections.screen.renderScaleLabel", "Render Scale")}
                        </label>
                        <select
                          id="renderScaleSelect"
                          value={selectedRenderScale}
                          onChange={handleRenderScaleChange}
                          title={conditionalCtx.manualActive
                            ? t("sections.screen.renderScaleDisabledManualTitle",
                                "A manual resolution is the exact framebuffer; there is nothing left to multiply")
                            : t("sections.screen.renderScaleDetails",
                                "Supersamples the stream; the remote desktop's own size is unchanged")}
                          disabled={!serverSettings
                            || serverSettings.render_scale?.locked === true
                            || conditionalCtx.manualActive}
                        >
                          {(serverSettings?.render_scale?.allowed
                            || renderScaleOptions.map((option) => String(option.value))
                          ).map((value) => (
                            <option key={value} value={value}>
                              {formatRenderScaleLabel(value)}
                            </option>
                          ))}
                        </select>
                      </div>
                    )}
                    {(renderableSettings.uiScaling ?? true) && (
                      <div className="dev-setting-item">
                        <label htmlFor="uiScalingSelect">
                          {t("sections.screen.desktopDpiLabel", "Desktop DPI")}
                        </label>
                        <select
                          id="uiScalingSelect"
                          value={selectedDpi}
                          onChange={handleDpiScalingChange}
                          title={t("sections.screen.desktopDpiDetails",
                            "Size of the remote desktop's own fonts and icons; the stream's sharpness is unchanged")}
                          disabled={!serverSettings || serverSettings.scaling_dpi?.allowed?.length <= 1
                            || serverSettings.scaling_dpi?.overridden === true}
                        >
                          {(serverSettings?.scaling_dpi?.allowed
                            || dpiScalingOptions.map((option) => String(option.value))
                          ).map((dpiValue) => (
                            <option key={dpiValue} value={dpiValue}>
                              {formatDpiLabel(dpiValue)}
                            </option>
                          ))}
                        </select>
                      </div>
                    )}
                  </>
                )}
                {(!serverSettings?.manual_resolution?.locked) && (
                  <>
                    <div className="dev-setting-item">
                      <label htmlFor="resolutionPresetSelect">
                        {t("sections.screen.presetLabel")}
                      </label>
                      <select
                        id="resolutionPresetSelect"
                        value={presetValue}
                        onChange={handlePresetChange}
                      >
                        {translatedCommonResolutions.map((res, i) => (
                          <option key={i} value={res.value} disabled={i === 0}>
                            {res.text}
                          </option>
                        ))}
                      </select>
                    </div>
                    <div className="resolution-manual-inputs">
                      <div className="dev-setting-item manual-input-item">
                        <label htmlFor="manualWidthInput">
                          {t("sections.screen.widthLabel")}
                        </label>
                        <input
                          className="allow-native-input"
                          type="number"
                          id="manualWidthInput"
                          min="1"
                          step="2"
                          placeholder={t("sections.screen.widthPlaceholder")}
                          value={manual_width}
                          onChange={handleManualWidthChange}
                        />
                      </div>
                      <div className="dev-setting-item manual-input-item">
                        <label htmlFor="manualHeightInput">
                          {t("sections.screen.heightLabel")}
                        </label>
                        <input
                          className="allow-native-input"
                          type="number"
                          id="manualHeightInput"
                          min="1"
                          step="2"
                          placeholder={t("sections.screen.heightPlaceholder")}
                          value={manual_height}
                          onChange={handleManualHeightChange}
                        />
                      </div>
                    </div>
                    <div className="resolution-action-buttons">
                      <button
                        className="resolution-button"
                        onClick={handleSetManualResolution}
                      >
                        {t("sections.screen.setManualButton")}
                      </button>
                      <button
                        className="resolution-button reset-button"
                        onClick={handleResetResolution}
                      >
                        {t("sections.screen.resetButton")}
                      </button>
                    </div>
                  </>
                )}
                <button
                  className={`resolution-button toggle-button ${
                    scaleLocally ? "active" : ""
                  }`}
                  onClick={handleScaleLocallyToggle}
                  style={{ marginTop: "10px" }}
                  title={t(
                    scaleLocally
                      ? "sections.screen.scaleLocallyTitleDisable"
                      : "sections.screen.scaleLocallyTitleEnable"
                  )}
                >
                  {t("sections.screen.scaleLocallyLabel")}{" "}
                  {t(
                    scaleLocally
                      ? "sections.screen.scaleLocallyOn"
                      : "sections.screen.scaleLocallyOff"
                  )}
                </button>
              </div>
            )}
          </div>
        )}

        {!isSecondaryDisplay && (
          <>
            {(renderableSettings.audioSettings ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("audioSettings")}
                  role="button"
                  aria-expanded={sectionsOpen.audioSettings}
                  aria-controls="audio-settings-content"
                  tabIndex="0"
                  onKeyDown={(e) => (e.key === "Enter" || e.key === " ") &&
                    toggleSection("audioSettings")}
                >
                  <h3>{t("sections.audio.title")}</h3>
                  <span className="section-toggle-icon">
                    {isLoadingAudioDevices ? (
                      <SpinnerIcon />
                    ) : sectionsOpen.audioSettings ? (
                      <CaretUpIcon />
                    ) : (
                      <CaretDownIcon />
                    )}
                  </span>
                </div>
                {sectionsOpen.audioSettings && (
                  <div
                    className="sidebar-section-content"
                    id="audio-settings-content"
                  >
                    {audioDeviceError && (
                      <div className="error-message">{audioDeviceError}</div>
                    )}
                    <div className="dev-setting-item">
                      <label htmlFor="audioInputSelect">
                        {t("sections.audio.inputLabel")}
                      </label>
                      <select
                        id="audioInputSelect"
                        value={selectedInputDeviceId}
                        onChange={handleAudioInputChange}
                        disabled={isLoadingAudioDevices || !!audioDeviceError}
                        className="audio-device-select"
                      >
                        {audioInputDevices.map((d) => (
                          <option key={d.deviceId} value={d.deviceId}>
                            {d.label}
                          </option>
                        ))}
                      </select>
                    </div>
                    {isOutputSelectionSupported && (
                      <div className="dev-setting-item">
                        <label htmlFor="audioOutputSelect">
                          {t("sections.audio.outputLabel")}
                        </label>
                        <select
                          id="audioOutputSelect"
                          value={selectedOutputDeviceId}
                          onChange={handleAudioOutputChange}
                          disabled={isLoadingAudioDevices || !!audioDeviceError}
                          className="audio-device-select"
                        >
                          {audioOutputDevices.map((d) => (
                            <option key={d.deviceId} value={d.deviceId}>
                              {d.label}
                            </option>
                          ))}
                        </select>
                      </div>
                    )}
                    {(renderableSettings.audio_bitrate ?? true) && (
                      <div className="dev-setting-item">
                        <label htmlFor="audioBitrateSlider">
                          {t("sections.audio.bitrateLabel", {
                            bitrate: audioBitrate/ 1000,
                          })}
                        </label>
                        <input
                          type="range"
                          id="audioBitrateSlider"
                          min={0}
                          max={audioBitrateChoices.length - 1}
                          step={1}
                          value={Math.max(0, audioBitrateChoices.indexOf(audioBitrate))}
                          onChange={(e) => handleAudioBitrateChange(audioBitrateChoices[parseInt(e.target.value, 10)])}
                          disabled={!serverSettings || (serverSettings.audio_bitrate?.allowed?.length ?? 0) <= 1}
                        />
                      </div>
                    )}
                    {!isOutputSelectionSupported &&
                      !isLoadingAudioDevices &&
                      !audioDeviceError && (
                        <p className="device-support-notice">
                          {t("sections.audio.outputNotSupported")}
                        </p>
                      )}
                  </div>
                )}
              </div>
            )}
            {(renderableSettings.stats ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("stats")}
                  role="button"
                  aria-expanded={sectionsOpen.stats}
                  aria-controls="stats-content"
                  tabIndex="0"
                  onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && toggleSection("stats")}
                >
                  <h3>{t("sections.stats.title")}</h3>
                  <span className="section-toggle-icon">
                    {sectionsOpen.stats ? <CaretUpIcon /> : <CaretDownIcon />}
                  </span>
                </div>
                {sectionsOpen.stats && (
                  <div className="sidebar-section-content" id="stats-content">
                    <div className="stats-gauges">
                      <div
                        className="gauge-container"
                        onMouseEnter={(e) => handleMouseEnter(e, "cpu")}
                        onMouseLeave={handleMouseLeave}
                      >
                        <svg
                          width={gaugeSize}
                          height={gaugeSize}
                          viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                        >
                          <circle
                            stroke="var(--item-border)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter} />
                          <circle
                            stroke="var(--sidebar-header-color)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter}
                            transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                            style={{
                              strokeDasharray: gaugeCircumference,
                              strokeDashoffset: cpuOffset,
                              transition: "stroke-dashoffset 0.3s ease-in-out",
                              strokeLinecap: "round",
                            }} />
                          <text
                            x={gaugeCenter}
                            y={gaugeCenter}
                            textAnchor="middle"
                            dominantBaseline="central"
                            fontSize={`${gaugeSize / 5}px`}
                            fill="var(--sidebar-text)"
                            fontWeight="bold"
                          >
                            {Math.round(
                              Math.max(0, Math.min(100, cpuPercent || 0))
                            )}%
                          </text>
                        </svg>
                        <div className="gauge-label">
                          {t("sections.stats.cpuLabel")}
                        </div>
                      </div>
                      <div
                        className="gauge-container"
                        onMouseEnter={(e) => handleMouseEnter(e, "sysmem")}
                        onMouseLeave={handleMouseLeave}
                      >
                        <svg
                          width={gaugeSize}
                          height={gaugeSize}
                          viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                        >
                          <circle
                            stroke="var(--item-border)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter} />
                          <circle
                            stroke="var(--sidebar-header-color)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter}
                            transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                            style={{
                              strokeDasharray: gaugeCircumference,
                              strokeDashoffset: sysMemOffset,
                              transition: "stroke-dashoffset 0.3s ease-in-out",
                              strokeLinecap: "round",
                            }} />
                          <text
                            x={gaugeCenter}
                            y={gaugeCenter}
                            textAnchor="middle"
                            dominantBaseline="central"
                            fontSize={`${gaugeSize / 5}px`}
                            fill="var(--sidebar-text)"
                            fontWeight="bold"
                          >
                            {Math.round(
                              Math.max(0, Math.min(100, sysMemPercent || 0))
                            )}
                            %
                          </text>
                        </svg>
                        <div className="gauge-label">
                          {t("sections.stats.sysMemLabel")}
                        </div>
                      </div>
                      {window.gpu_stats && (
                        <>
                          <div
                            className="gauge-container"
                            onMouseEnter={(e) => handleMouseEnter(e, "gpu")}
                            onMouseLeave={handleMouseLeave}
                          >
                            <svg
                              width={gaugeSize}
                              height={gaugeSize}
                              viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                            >
                              <circle
                                stroke="var(--item-border)"
                                fill="transparent"
                                strokeWidth={gaugeStrokeWidth}
                                r={gaugeRadius}
                                cx={gaugeCenter}
                                cy={gaugeCenter} />
                              <circle
                                stroke="var(--sidebar-header-color)"
                                fill="transparent"
                                strokeWidth={gaugeStrokeWidth}
                                r={gaugeRadius}
                                cx={gaugeCenter}
                                cy={gaugeCenter}
                                transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                                style={{
                                  strokeDasharray: gaugeCircumference,
                                  strokeDashoffset: gpuOffset,
                                  transition: "stroke-dashoffset 0.3s ease-in-out",
                                  strokeLinecap: "round",
                                }} />
                              <text
                                x={gaugeCenter}
                                y={gaugeCenter}
                                textAnchor="middle"
                                dominantBaseline="central"
                                fontSize={`${gaugeSize / 5}px`}
                                fill="var(--sidebar-text)"
                                fontWeight="bold"
                              >
                                {Math.round(
                                  Math.max(0, Math.min(100, gpuPercent || 0))
                                )}%
                              </text>
                            </svg>
                            <div className="gauge-label">
                              {t("sections.stats.gpuLabel")}
                            </div>
                          </div>
                          <div
                            className="gauge-container"
                            onMouseEnter={(e) => handleMouseEnter(e, "gpumem")}
                            onMouseLeave={handleMouseLeave}
                          >
                            <svg
                              width={gaugeSize}
                              height={gaugeSize}
                              viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                            >
                              <circle
                                stroke="var(--item-border)"
                                fill="transparent"
                                strokeWidth={gaugeStrokeWidth}
                                r={gaugeRadius}
                                cx={gaugeCenter}
                                cy={gaugeCenter} />
                              <circle
                                stroke="var(--sidebar-header-color)"
                                fill="transparent"
                                strokeWidth={gaugeStrokeWidth}
                                r={gaugeRadius}
                                cx={gaugeCenter}
                                cy={gaugeCenter}
                                transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                                style={{
                                  strokeDasharray: gaugeCircumference,
                                  strokeDashoffset: gpuMemOffset,
                                  transition: "stroke-dashoffset 0.3s ease-in-out",
                                  strokeLinecap: "round",
                                }} />
                              <text
                                x={gaugeCenter}
                                y={gaugeCenter}
                                textAnchor="middle"
                                dominantBaseline="central"
                                fontSize={`${gaugeSize / 5}px`}
                                fill="var(--sidebar-text)"
                                fontWeight="bold"
                              >
                                {Math.round(
                                  Math.max(0, Math.min(100, gpuMemPercent || 0))
                                )}
                                %
                              </text>
                            </svg>
                            <div className="gauge-label">
                              {t("sections.stats.gpuMemLabel")}
                            </div>
                          </div>
                        </>
                      )}
                      <div
                        className="gauge-container"
                        onMouseEnter={(e) => handleMouseEnter(e, "fps")}
                        onMouseLeave={handleMouseLeave}
                      >
                        <svg
                          width={gaugeSize}
                          height={gaugeSize}
                          viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                        >
                          <circle
                            stroke="var(--item-border)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter} />
                          <circle
                            stroke="var(--sidebar-header-color)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter}
                            transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                            style={{
                              strokeDasharray: gaugeCircumference,
                              strokeDashoffset: fpsOffset,
                              transition: "stroke-dashoffset 0.3s ease-in-out",
                              strokeLinecap: "round",
                            }} />
                          <text
                            x={gaugeCenter}
                            y={gaugeCenter}
                            textAnchor="middle"
                            dominantBaseline="central"
                            fontSize={`${gaugeSize / 5}px`}
                            fill="var(--sidebar-text)"
                            fontWeight="bold"
                          >
                            {clientFps}
                          </text>
                        </svg>
                        <div className="gauge-label">
                          {t("sections.stats.fpsLabel")}
                        </div>
                      </div>
                      {(<div
                        className="gauge-container"
                        onMouseEnter={(e) => handleMouseEnter(e, "audio")}
                        onMouseLeave={handleMouseLeave}
                      >
                        <svg
                          width={gaugeSize}
                          height={gaugeSize}
                          viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                        >
                          <circle
                            stroke="var(--item-border)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter} />
                          <circle
                            stroke="var(--sidebar-header-color)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter}
                            transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                            style={{
                              strokeDasharray: gaugeCircumference,
                              strokeDashoffset: audioLevelOffset,
                              transition: "stroke-dashoffset 0.3s ease-in-out",
                              strokeLinecap: "round",
                            }} />
                          <text
                            x={gaugeCenter}
                            y={gaugeCenter}
                            textAnchor="middle"
                            dominantBaseline="central"
                            fontSize={`${gaugeSize / 5}px`}
                            fill="var(--sidebar-text)"
                            fontWeight="bold"
                          >
                            {audioLevel}
                          </text>
                        </svg>
                        <div className="gauge-label">
                          {t("sections.stats.audioLabel")}
                        </div>
                      </div>)}
                      <div
                        className="gauge-container"
                        onMouseEnter={(e) => handleMouseEnter(e, "bandwidth")}
                        onMouseLeave={handleMouseLeave}
                      >
                        <svg
                          width={gaugeSize}
                          height={gaugeSize}
                          viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                        >
                          <circle
                            stroke="var(--item-border)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter} />
                          <circle
                            stroke="var(--sidebar-header-color)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter}
                            transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                            style={{
                              strokeDasharray: gaugeCircumference,
                              strokeDashoffset: bandwidthOffset,
                              transition: "stroke-dashoffset 0.3s ease-in-out",
                              strokeLinecap: "round",
                            }} />
                          <text
                            x={gaugeCenter}
                            y={gaugeCenter}
                            textAnchor="middle"
                            dominantBaseline="central"
                            fontSize={`${gaugeSize / 5}px`}
                            fill="var(--sidebar-text)"
                            fontWeight="bold"
                          >
                            {Math.round(bandwidthMbps)}
                          </text>
                        </svg>
                        <div className="gauge-label">
                          {t("sections.stats.bandwidthLabel", "Bandwidth")}
                        </div>
                      </div>
                      <div
                        className="gauge-container"
                        onMouseEnter={(e) => handleMouseEnter(e, "latency")}
                        onMouseLeave={handleMouseLeave}
                      >
                        <svg
                          width={gaugeSize}
                          height={gaugeSize}
                          viewBox={`0 0 ${gaugeSize} ${gaugeSize}`}
                        >
                          <circle
                            stroke="var(--item-border)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter} />
                          <circle
                            stroke="var(--sidebar-header-color)"
                            fill="transparent"
                            strokeWidth={gaugeStrokeWidth}
                            r={gaugeRadius}
                            cx={gaugeCenter}
                            cy={gaugeCenter}
                            transform={`rotate(-90 ${gaugeCenter} ${gaugeCenter})`}
                            style={{
                              strokeDasharray: gaugeCircumference,
                              strokeDashoffset: latencyOffset,
                              transition: "stroke-dashoffset 0.3s ease-in-out",
                              strokeLinecap: "round",
                            }} />
                          <text
                            x={gaugeCenter}
                            y={gaugeCenter}
                            textAnchor="middle"
                            dominantBaseline="central"
                            fontSize={`${gaugeSize / 5}px`}
                            fill="var(--sidebar-text)"
                            fontWeight="bold"
                          >
                            {Math.round(latencyMs)}
                          </text>
                        </svg>
                        <div className="gauge-label">
                          {t("sections.stats.latencyLabel", "Latency")}
                        </div>
                      </div>
                    </div>
                  </div>
                )}
              </div>
            )}

            {(renderableSettings.clipboard ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("clipboard")}
                  role="button"
                  aria-expanded={sectionsOpen.clipboard}
                  aria-controls="clipboard-content"
                  tabIndex="0"
                  onKeyDown={(e) =>
                    (e.key === "Enter" || e.key === " ") && toggleSection("clipboard")
                  }
                >
                  <h3>{t("sections.clipboard.title")}</h3>
                  <span className="section-toggle-icon">
                    {sectionsOpen.clipboard ? <CaretUpIcon /> : <CaretDownIcon />}
                  </span>
                </div>
                {sectionsOpen.clipboard && (
                  <div className="sidebar-section-content" id="clipboard-content">
                    {(renderableSettings.binaryClipboard ?? true) && (
                      <div className="dev-setting-item toggle-item">
                        <label 
                          htmlFor="enableBinaryClipboardToggle"
                          title={t("sections.clipboard.binaryModeDetails")}
                        >
                          {t("sections.clipboard.binaryModeLabel", "Image Support")}
                        </label>
                        <button
                          id="enableBinaryClipboardToggle"
                          className={`toggle-button-sidebar ${enableBinaryClipboard ? "active" : ""}`}
                          onClick={handleEnableBinaryClipboardToggle}
                          aria-pressed={enableBinaryClipboard}
                          disabled={!serverSettings || serverSettings.enable_binary_clipboard?.locked}
                          title={t(enableBinaryClipboard ? "buttons.binaryClipboardDisableTitle" : "buttons.binaryClipboardEnableTitle")}
                        >
                          <span className="toggle-button-sidebar-knob"></span>
                        </button>
                      </div>
                    )}
                    <div className="dashboard-clipboard-item">
                      <label htmlFor="dashboardClipboardTextarea">
                        {t("sections.clipboard.label")}
                      </label>
                      <textarea
                        className="allow-native-input"
                        id="dashboardClipboardTextarea"
                        value={dashboardClipboardContent}
                        onChange={handleClipboardChange}
                        onBlur={handleClipboardBlur}
                        readOnly={dashboardClipboardTruncated}
                        rows="5"
                        placeholder={t("sections.clipboard.placeholder")}
                      />
                    </div>
                    {(renderableSettings.binaryClipboard ?? true) &&
                      enableBinaryClipboard && (
                        <div className="dashboard-clipboard-item">
                          <button
                            className="app-action-button install"
                            onClick={() => clipboardImageInputRef.current?.click()}
                          >
                            {t("sections.clipboard.uploadImage", "Upload Image")}
                          </button>
                          <input
                            ref={clipboardImageInputRef}
                            type="file"
                            accept="image/*"
                            onChange={handleClipboardImageUpload}
                            style={{ display: "none" }}
                          />
                        </div>
                      )}
                  </div>
                )}
              </div>
            )}
          </>
        )}

        {!isSecondaryDisplay && (
          <>
            {(renderableSettings.files ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("files")}
                  role="button"
                  aria-expanded={sectionsOpen.files}
                  aria-controls="files-content"
                  tabIndex="0"
                  onKeyDown={(e) =>
                    (e.key === "Enter" || e.key === " ") && toggleSection("files")
                  }
                >
                  <h3>{t("sections.files.title")}</h3>
                  <span className="section-toggle-icon">
                    {sectionsOpen.files ? <CaretUpIcon /> : <CaretDownIcon />}
                  </span>
                </div>
                {sectionsOpen.files && (
                  <div className="sidebar-section-content" id="files-content">
                    {(renderableSettings.fileUpload ?? true) && (
                      <button
                        className="resolution-button"
                        onClick={handleUploadClick}
                        style={{ marginTop: "5px", marginBottom: "5px" }}
                        title={t("sections.files.uploadButtonTitle")}
                      >
                        {t("sections.files.uploadButton")}
                      </button>
                    )}
                    {(renderableSettings.fileDownload ?? true) && (
                      <button
                        className="resolution-button"
                        onClick={toggleFilesModal}
                        style={{ marginTop: "5px", marginBottom: "5px" }}
                        title={t(
                          "sections.files.downloadButtonTitle",
                          "Download Files"
                        )}
                      >
                        {t("sections.files.downloadButtonTitle", "Download Files")}
                      </button>
                    )}
                  </div>
                )}
              </div>
            )}

            {(renderableSettings.apps ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("apps")}
                  role="button"
                  aria-expanded={sectionsOpen.apps}
                  aria-controls="apps-content"
                  tabIndex="0"
                  onKeyDown={(e) =>
                    (e.key === "Enter" || e.key === " ") && toggleSection("apps")
                  }
                >
                  <h3>{t("sections.apps.title", "Apps")}</h3>
                  <span className="section-toggle-icon">
                    {sectionsOpen.apps ? <CaretUpIcon /> : <CaretDownIcon />}
                  </span>
                </div>
                {sectionsOpen.apps && (
                  <div className="sidebar-section-content" id="apps-content">
                    <button
                      className="resolution-button"
                      onClick={toggleAppsModal}
                      style={{ marginTop: "5px", marginBottom: "5px" }}
                      title={t("sections.apps.openButtonTitle", "Manage Apps")}
                    >
                      <AppsIcon />
                      <span style={{ marginLeft: "8px" }}>
                        {t("sections.apps.openButton", "Manage Apps")}
                      </span>
                    </button>
                  </div>
                )}
              </div>
            )}

            {(renderableSettings.sharing ?? true) && (renderableSettings.enableSharing ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("sharing")}
                  role="button"
                  aria-expanded={sectionsOpen.sharing}
                  aria-controls="sharing-content"
                  tabIndex="0"
                  onKeyDown={(e) =>
                    (e.key === "Enter" || e.key === " ") &&
                    toggleSection("sharing")
                  }
                >
                  <h3>{t("sections.sharing.title", "Sharing")}</h3>
                  <span className="section-toggle-icon">
                    {sectionsOpen.sharing ? <CaretUpIcon /> : <CaretDownIcon />}
                  </span>
                </div>
                {sectionsOpen.sharing && (
                  <div className="sidebar-section-content" id="sharing-content">
                    {filteredSharingLinks.map((link) => {
                      const fullUrl = `${baseUrl}${link.hash}`;
                      return (
                        <div
                          key={link.id}
                          className="sharing-link-item"
                          title={link.tooltip}
                        >
                          <span className="sharing-link-label">
                            {link.label}
                          </span>
                          <div className="sharing-link-actions">
                            <a
                              href={fullUrl}
                              target="_blank"
                              rel="noopener noreferrer"
                              className="sharing-link"
                              title={t("sections.sharing.openLinkTitle", { label: link.label })}
                            >
                              {fullUrl}
                            </a>
                            <button
                              type="button"
                              onClick={() => handleCopyLink(fullUrl, link.label)}
                              className="copy-button"
                              title={t("sections.sharing.copyLinkTitle", { label: link.label })}
                            >
                              <CopyIcon />
                            </button>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )}
              </div>
            )}

            {(renderableSettings.gamepads ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("gamepads")}
                  role="button"
                  aria-expanded={sectionsOpen.gamepads}
                  aria-controls="gamepads-content"
                  tabIndex="0"
                  onKeyDown={(e) =>
                    (e.key === "Enter" || e.key === " ") &&
                    toggleSection("gamepads")
                  }
                >
                  <h3>{t("sections.gamepads.title", "Gamepads")}</h3>
                  <span className="section-toggle-icon" aria-hidden="true">
                    {sectionsOpen.gamepads ? <CaretUpIcon /> : <CaretDownIcon />}
                  </span>
                </div>
                {sectionsOpen.gamepads && (
                  <div className="sidebar-section-content" id="gamepads-content">
                    <div
                      className="dev-setting-item"
                      style={{ marginBottom: "10px" }}
                    >
                      <button
                        className={`resolution-button toggle-button ${
                          isTouchGamepadActive ? "active" : ""
                        }`}
                        onClick={handleToggleTouchGamepad}
                        title={t(
                          isTouchGamepadActive
                            ? "sections.gamepads.touchDisableTitle"
                            : "sections.gamepads.touchEnableTitle",
                          isTouchGamepadActive
                            ? "Disable Touch Gamepad"
                            : "Enable Touch Gamepad"
                        )}
                      >
                        <GamepadIcon />
                        <span style={{ marginLeft: "8px" }}>
                          {t(
                            isTouchGamepadActive
                              ? "sections.gamepads.touchActiveLabel"
                              : "sections.gamepads.touchInactiveLabel",
                            isTouchGamepadActive
                              ? "Touch Gamepad: ON"
                              : "Touch Gamepad: OFF"
                          )}
                        </span>
                      </button>
                    </div>

                    {isMobile && isTouchGamepadActive ? (
                      <p>
                        {t(
                          "sections.gamepads.physicalHiddenForTouch",
                          "Physical gamepad display is hidden while touch gamepad is active."
                        )}
                      </p>
                    ) : (
                      <>
                        {Object.keys(gamepadStates).length > 0 ? (
                          Object.keys(gamepadStates)
                            .sort((a, b) => parseInt(a, 10) - parseInt(b, 10))
                            .map((gpIndexStr) => {
                              const gpIndex = parseInt(gpIndexStr, 10);
                              return (
                                <GamepadVisualizer
                                  key={gpIndex}
                                  gamepadIndex={gpIndex}
                                  gamepadState={gamepadStates[gpIndex]}
                                />
                              );
                            })
                        ) : (
                          <p className="no-gamepads-message">
                            {isMobile
                              ? t(
                                  "sections.gamepads.noActivityMobileOrEnableTouch",
                                  "No physical gamepads. Enable touch gamepad or connect a controller."
                                )
                              : t(
                                  "sections.gamepads.noActivity",
                                  "No physical gamepad activity detected."
                                )}
                          </p>
                        )}
                      </>
                    )}
                  </div>
                )}
              </div>
            )}

            {(renderableSettings.shortcuts ?? true) && (
              <div className="sidebar-section">
                <div
                  className="sidebar-section-header"
                  onClick={() => toggleSection("shortcuts")}
                  role="button"
                  aria-expanded={sectionsOpen.shortcuts}
                  aria-controls="shortcuts-content"
                  tabIndex="0"
                  onKeyDown={(e) =>
                    (e.key === "Enter" || e.key === " ") &&
                    toggleSection("shortcuts")
                  }
                >
                  <h3>{t("sections.shortcuts.title", "Shortcuts")}</h3>
                  <span className="section-toggle-icon">
                    {sectionsOpen.shortcuts ? <CaretUpIcon /> : <CaretDownIcon />}
                  </span>
                </div>
                {sectionsOpen.shortcuts && (
                  <div className="sidebar-section-content" id="shortcuts-content">
                    {[
                      { combo: "Ctrl + Shift + F", label: t("sections.shortcuts.fullscreen", "Toggle fullscreen") },
                      { combo: "Ctrl + Shift + X", label: t("sections.shortcuts.gamingMode", "Toggle gaming mode") },
                      { combo: "Ctrl + Shift + M", label: t("sections.shortcuts.openMenu", "Open or close the dashboard") },
                      { combo: "Ctrl + Shift + G", label: t("sections.shortcuts.toggleGamepad", "Toggle the virtual gamepad") },
                      { combo: "Ctrl + Shift + Left Click", label: t("sections.shortcuts.pointerLock", "Lock the pointer to the stream") },
                    ].map((sc) => (
                      <div
                        key={sc.combo}
                        className="shortcut-item"
                        style={{
                          display: "flex",
                          flexDirection: "column",
                          alignItems: "center",
                          gap: "2px",
                          padding: "6px 0",
                          textAlign: "center",
                        }}
                      >
                        <kbd
                          style={{
                            fontFamily: "monospace",
                            whiteSpace: "normal",
                            overflowWrap: "anywhere",
                            maxWidth: "100%",
                            textAlign: "center",
                            padding: "2px 6px",
                            borderRadius: "4px",
                            border: "1px solid var(--item-border)",
                          }}
                        >
                          {sc.combo}
                        </kbd>
                        <span>{sc.label}</span>
                      </div>
                    ))}
                    <div style={{ marginTop: "8px", textAlign: "center" }}>
                      <a
                        className="cite-link"
                        href="https://docs.selkies.io/citation/"
                        target="_blank"
                        rel="noopener noreferrer"
                      >
                        {t("sections.shortcuts.citeNotice", "Cite our paper academically")}
                        {" ↗"}
                      </a>
                    </div>
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>


      {hoveredItem && (
        <div
          className="gauge-tooltip"
          style={{
            left: `${tooltipPosition.x}px`,
            top: `${tooltipPosition.y}px`,
          }}
        >
          {getTooltipContent(hoveredItem)}
        </div>
      )}

      <div className={`notification-container theme-${theme}`}>
        {notifications.map((n) => (
          <div
            key={n.id}
            className={`notification-item ${n.status} ${
              n.fadingOut ? "fade-out" : ""
            }`}
            role="alert"
            aria-live="polite"
          >
            <div className="notification-header">
              <span className="notification-filename" title={n.fileName}>
                {n.fileName}
              </span>
              <button
                className="notification-close-button"
                onClick={() => removeNotification(n.id)}
                aria-label={t("notifications.closeButtonAlt", {
                  fileName: n.fileName,
                })}
              >
                &times;
              </button>
            </div>
            <div className="notification-body">
              {n.status === "progress" && (
                <>
                  <span className="notification-status-text">
                    {t("notifications.uploading", { progress: n.progress })}
                  </span>
                  <div className="notification-progress-bar-outer">
                    <div
                      className="notification-progress-bar-inner"
                      style={{ width: `${n.progress}%` }}
                    />
                  </div>
                </>
              )}
              {n.status === "end" && (
                <>
                  <span className="notification-status-text">
                    {n.message ? n.message : t("notifications.uploadComplete")}
                  </span>
                  <div className="notification-progress-bar-outer">
                    <div
                      className="notification-progress-bar-inner"
                      style={{ width: `100%` }}
                    />
                  </div>
                </>
              )}
              {n.status === "error" && (
                <>
                  <span className="notification-status-text error-text">
                    {t("notifications.uploadFailed")}
                  </span>
                  <div className="notification-progress-bar-outer">
                    <div
                      className="notification-progress-bar-inner"
                      style={{ width: `100%` }}
                    />
                  </div>
                  {n.message && (
                    <p className="notification-error-message">{n.message}</p>
                  )}
                </>
              )}
              {n.status === "warn" && (
                <>
                  {" "}
                  <span className="notification-status-text warn-text">
                    {n.message ? n.message : t("notifications.warningPrefix")}
                  </span>{" "}
                </>
              )}
            </div>
          </div>
        ))}
      </div>

      {isFilesModalOpen && (
        <div className={`files-modal theme-${theme}`}>
          <div className="files-modal-header">
            <button
              className="files-modal-close"
              onClick={toggleFilesModal}
              aria-label={t("filesModal.closeAlt")}
            >
              &times;
            </button>
          </div>
          {isFilesModalLoading && (
            <div className="files-modal-loading">
              <SpinnerIcon />
              <p>{t("filesModal.loading", "Loading files...")}</p>
            </div>
          )}
          <iframe
            src={withSessionToken("./api/files/")}
            title={t("filesModal.iframeTitle")}
            onLoad={() => setIsFilesModalLoading(false)}
            style={{ opacity: isFilesModalLoading ? 0 : 1 }}
          />
        </div>
      )}
      {isAppsModalOpen && (
        <AppsModal isOpen={isAppsModalOpen} onClose={toggleAppsModal} t={t}
          commandsAvailable={serverSettings?.command_enabled?.value === true}
          commandsKnown={serverSettings != null}
          installedFromServer={serverSettings?.apps_installed?.value} />
      )}

      {isViewerRole && (
        <PlayerGamepadButton touchOnly isActive={isTouchGamepadActive} onToggle={handleToggleTouchGamepad} />
      )}
      {!isViewerRole && (isMobile || hasDetectedTouch) && isKeyboardButtonVisible && (renderableSettings.keyboardButton ?? true) && (
        <button
          className={`virtual-keyboard-button theme-${theme} allow-native-input`}
          onClick={onKeyboardButtonClick}
          onPointerDown={handlePointerDown}
          onPointerMove={handlePointerMove}
          onPointerUp={handlePointerUp}
          onPointerCancel={handlePointerUp}
          style={{
            position: 'fixed',
            right: `${keyboardButtonPosition.right}px`,
            bottom: `${keyboardButtonPosition.bottom}px`,
            touchAction: 'none',
          }}
          title={t("buttons.virtualKeyboardButtonTitle", "Pop Keyboard")}
          aria-label={t("buttons.virtualKeyboardButtonTitle", "Pop Keyboard")}
        >
          <KeyboardIcon />
        </button>
      )}
    </>
  );
}

export default Sidebar;
