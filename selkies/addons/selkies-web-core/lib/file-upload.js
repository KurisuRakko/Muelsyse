/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

/**
 * File uploads, shared by both transports.
 *
 * Every upload is HTTP POSTs to `/api/upload` rather than a stream of chunks
 * over the WebSocket or a data channel: the browser's native HTTP path and
 * the server's C-accelerated aiohttp saturate the link, whereas per-message
 * chunk processing is bounded by pure-Python per-chunk work, and an upload
 * cannot stall or kill the realtime session socket. The destination path
 * rides URL-encoded in the `X-Upload-Path` header, the secure-mode session
 * token as a Bearer header, and progress is reported to the dashboards as
 * `{type: 'fileUpload'}` window messages with the statuses `start`,
 * `progress`, `end`, `error` and `warning`.
 *
 * Files at or under `UPLOAD_CHUNK_BYTES` go up as one plain POST (the whole
 * Blob, no extra headers, the shape every server accepts). Larger files are
 * sliced with `Blob.slice`, never read into memory, into sequential POSTs of
 * at most `UPLOAD_CHUNK_BYTES` so no single request body exceeds a fronting
 * proxy's per-request cap (Cloudflare rejects bodies over 100 MB). Each slice
 * carries the same `X-Upload-Path` plus `X-Upload-Id` (an opaque per-file
 * transfer id), `X-Upload-Offset` (the slice's absolute byte offset),
 * `X-Upload-Total` (the final file size in bytes) and, on the last slice,
 * `X-Upload-Final: 1`. The server appends slices to a `.part` file and
 * atomically renames it into place on the final one. Progress is cumulative
 * across slices, so the dashboards render one smooth bar per file.
 *
 * One upload operation (a file-picker set or a dropped tree) runs at a time:
 * sequential POSTs keep server-side writes ordered and the progress UI
 * coherent.
 *
 * A drop can also be placed where it landed. When the core's `dropPoint`
 * maps the drop event to a frame-buffer position (the server advertised a
 * drop helper, and the point lies on the stream), every upload of that drop
 * carries `X-Upload-Drop: <id>` so the server stages it apart from the
 * file-manager directory, and once all of them have been tried a JSON POST
 * to `/api/drop` (`{id, x, y, entries}`, entries being the dropped top-level
 * names that uploaded at least one file) asks the server to drop them into
 * the remote desktop at that point. A failed file leaves the rest of the drop
 * to be placed without it; the server itself falls back to the file-manager
 * directory when the desktop refuses the drop, and hands it a drop that is
 * never placed once that sits idle.
 * @module
 */
import { sessionAuthHeaders } from './session-token.js';

const UPLOAD_CHUNK_BYTES = 64 * 1024 * 1024;

/**
 * @typedef {object} FileUploader
 * @property {(file: File, pathToSend: string) => Promise<void>} uploadFileObject
 *     Uploads one file to the given destination path, reporting progress.
 * @property {() => void} handleRequestFileUpload Opens the hidden file picker.
 * @property {(event: Event) => Promise<void>} handleFileInputChange Uploads
 *     the picker's files sequentially.
 * @property {(ev: DragEvent) => void} handleDragOver Sets the drop effect.
 * @property {(ev: DragEvent) => Promise<void>} handleDrop Uploads dropped
 *     files and directory trees sequentially.
 */

/**
 * Creates the upload handlers a core wires to its page.
 * @param {object} [options]
 * @param {() => boolean} [options.canUpload] Per-core gate; a shared or
 *     viewer session returns `false` and every entry point refuses.
 * @param {(ev: DragEvent) => ({x: number, y: number}|null)} [options.dropPoint]
 *     Frame-buffer position to place a drop at, or `null` for a plain upload.
 * @returns {FileUploader}
 */
export function createFileUploader({ canUpload = () => true, dropPoint = () => null } = {}) {
    let operationInFlight = false;

    function post(payload) {
        window.postMessage({ type: 'fileUpload', payload }, window.location.origin);
    }

    function beginOperation() {
        if (operationInFlight) {
            console.warn("Simultaneous uploading of files with distinct upload operations is not supported yet");
            post({ status: 'warning', fileName: '_N/A_', message: "Please let the ongoing upload complete." });
            return false;
        }
        operationInFlight = true;
        return true;
    }

    /**
     * One POST of a File or Blob slice. Resolves on 2xx and rejects with the
     * dashboard-facing message otherwise; upload progress is relayed to
     * `onProgress` raw so the caller can accumulate across slices.
     * @param {string} url The upload endpoint.
     * @param {string} pathToSend Destination path.
     * @param {Blob} body The bytes.
     * @param {object|null} extraHeaders Slice headers, if any.
     * @param {(e: ProgressEvent) => void} onProgress Upload progress listener.
     * @returns {Promise<void>}
     */
    function postUploadBody(url, pathToSend, body, extraHeaders, onProgress) {
        return new Promise((resolve, reject) => {
            const xhr = new XMLHttpRequest();
            xhr.open('POST', url, true);
            xhr.withCredentials = true;
            xhr.setRequestHeader('Content-Type', 'application/octet-stream');
            xhr.setRequestHeader('X-Upload-Path', encodeURIComponent(pathToSend));
            for (const [name, value] of Object.entries(sessionAuthHeaders(extraHeaders))) {
                xhr.setRequestHeader(name, value);
            }
            xhr.upload.onprogress = onProgress;
            xhr.onload = () => {
                if (xhr.status >= 200 && xhr.status < 300) {
                    resolve();
                } else {
                    reject(new Error(`upload failed (${xhr.status}): ${String(xhr.responseText || '').slice(0, 160)}`));
                }
            };
            xhr.onerror = () => {
                reject(new Error(`network error uploading ${pathToSend}`));
            };
            xhr.send(body);
        });
    }

    /**
     * Uploads one file, as a single POST or as slices by size, reporting
     * `start`, cumulative `progress` and `end` or `error`.
     * @param {File} file The file.
     * @param {string} pathToSend Destination path.
     * @param {object|null} [dropHeaders] Headers every POST of this file
     *     carries (the drop id of a placed drop).
     * @throws {Error} The upload failure, after reporting it.
     */
    async function uploadFileObject(file, pathToSend, dropHeaders = null) {
        post({ status: 'start', fileName: pathToSend, fileSize: file.size });
        const report = (status, extra) =>
            post({ status, fileName: pathToSend, fileSize: file.size, ...extra });
        const percentOf = (sentBytes) => (file.size > 0)
            ? Math.min(100, Math.round((sentBytes / file.size) * 100)) : 0;
        try {
            const url = new URL('api/upload', window.location.href).href;
            if (file.size <= UPLOAD_CHUNK_BYTES) {
                await postUploadBody(url, pathToSend, file, dropHeaders, (e) => {
                    const progress = (e.lengthComputable && file.size > 0)
                        ? Math.min(100, Math.round((e.loaded / e.total) * 100)) : 0;
                    report('progress', { progress });
                });
            } else {
                const transferId = (window.crypto && crypto.randomUUID)
                    ? crypto.randomUUID()
                    : `${Date.now()}-${Math.random().toString(36).slice(2)}`;
                for (let offset = 0; offset < file.size;) {
                    const end = Math.min(offset + UPLOAD_CHUNK_BYTES, file.size);
                    const headers = {
                        ...dropHeaders,
                        'X-Upload-Id': transferId,
                        'X-Upload-Offset': String(offset),
                        'X-Upload-Total': String(file.size),
                    };
                    if (end >= file.size) headers['X-Upload-Final'] = '1';
                    const sentBefore = offset;
                    await postUploadBody(url, pathToSend, file.slice(offset, end), headers, (e) => {
                        if (!e.lengthComputable) return;
                        report('progress', { progress: percentOf(sentBefore + e.loaded) });
                    });
                    offset = end;
                    report('progress', { progress: percentOf(offset) });
                }
            }
            report('progress', { progress: 100 });
            report('end');
        } catch (error) {
            const msg = (error && error.message) ? error.message : `error during upload of ${pathToSend}: ${error}`;
            report('error', { message: msg });
            throw error;
        }
    }

    function getFileFromEntry(fileEntry) {
        return new Promise((resolve, reject) => fileEntry.file(resolve, reject));
    }

    /**
     * Uploads a dropped file or, recursively, a dropped directory. The
     * entry's `fullPath` preserves a dropped directory's internal structure;
     * the fallback rebuilds it from the recursion for browsers without one.
     * @param {FileSystemEntry} entry The dropped entry.
     * @param {string} [basePathFallback] Parent path when `fullPath` is absent.
     * @param {{headers: (object|null), uploaded: number}} [drop] The drop
     *     this entry belongs to; `uploaded` counts its files that arrived.
     */
    async function handleDroppedEntry(entry, basePathFallback = "", drop = { headers: null, uploaded: 0 }) {
        let pathToSend;
        if (entry.fullPath && typeof entry.fullPath === 'string' && entry.fullPath !== entry.name &&
            (entry.fullPath.includes('/') || entry.fullPath.includes('\\'))) {
            pathToSend = entry.fullPath;
            if (pathToSend.startsWith('/')) {
                pathToSend = pathToSend.substring(1);
            }
        } else {
            pathToSend = basePathFallback ? `${basePathFallback}/${entry.name}` : entry.name;
        }

        if (entry.isFile) {
            try {
                const file = await getFileFromEntry(entry);
                await uploadFileObject(file, pathToSend, drop.headers);
                drop.uploaded++;
            } catch (err) {
                console.error(`Error processing file ${pathToSend}: ${err}`);
                post({ status: 'error', fileName: pathToSend, message: `Error processing file: ${err.message || err}` });
            }
        } else if (entry.isDirectory) {
            const dirReader = entry.createReader();
            let entries;
            do {
                entries = await new Promise((resolve, reject) => dirReader.readEntries(resolve, reject));
                for (const subEntry of entries) {
                    await handleDroppedEntry(subEntry, pathToSend, drop);
                }
            } while (entries.length > 0);
        }
    }

    function handleRequestFileUpload() {
        if (!canUpload()) {
            console.log("File upload blocked (shared/viewer session).");
            return;
        }
        const hiddenInput = document.getElementById('globalFileInput');
        if (!hiddenInput) {
            console.error("Global file input not found!");
            return;
        }
        hiddenInput.click();
    }

    async function handleFileInputChange(event) {
        const files = event.target.files;
        if (!canUpload() || !files || files.length === 0) {
            event.target.value = null;
            return;
        }
        if (!beginOperation()) {
            event.target.value = null;
            return;
        }
        console.log(`File input changed, processing ${files.length} files sequentially.`);
        try {
            for (let i = 0; i < files.length; i++) {
                const file = files[i];
                await uploadFileObject(file, file.name);
            }
        } catch (error) {
            const errorMsg = `An error occurred during the file input upload process: ${error.message || error}`;
            console.error(errorMsg);
            post({ status: 'error', fileName: 'N/A', message: errorMsg });
        } finally {
            event.target.value = null;
            operationInFlight = false;
        }
    }

    function handleDragOver(ev) {
        ev.preventDefault();
        ev.dataTransfer.dropEffect = canUpload() ? 'copy' : 'none';
    }

    /** A fresh drop id within the server's `[A-Za-z0-9-]{1,64}`. */
    function newDropId() {
        if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
        return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`;
    }

    /**
     * The drop event's placement point, or `null` for a plain upload; a
     * throwing or non-finite mapping is a plain upload too.
     * @param {DragEvent} ev The drop.
     * @returns {{x: number, y: number}|null}
     */
    function resolveDropPoint(ev) {
        try {
            const point = dropPoint(ev);
            if (point && Number.isFinite(point.x) && Number.isFinite(point.y)
                && point.x >= 0 && point.y >= 0) {
                return { x: point.x, y: point.y };
            }
        } catch (err) {
            console.warn(`Drop placement unavailable: ${err}`);
        }
        return null;
    }

    /**
     * Asks the server to place a fully uploaded drop at its point. The files
     * are already on the host either way, so the outcome is only logged:
     * `placed: false` means the server moved them into the file-manager
     * directory instead.
     * @param {string} id The drop id the uploads carried.
     * @param {{x: number, y: number}} point Frame-buffer position.
     * @param {string[]} entries Dropped top-level names.
     */
    async function placeDrop(id, point, entries) {
        try {
            const response = await fetch(new URL('api/drop', window.location.href).href, {
                method: 'POST',
                credentials: 'include',
                headers: sessionAuthHeaders({ 'Content-Type': 'application/json' }),
                body: JSON.stringify({ id, x: point.x, y: point.y, entries }),
            });
            const result = await response.json().catch(() => ({}));
            if (!response.ok) {
                throw new Error(`(${response.status}) ${result.message || ''}`);
            }
            if (result.placed === false) {
                console.info(`Drop not placed on the remote desktop (${result.reason || 'no reason given'}); files moved to the upload folder.`);
            }
        } catch (err) {
            const msg = `Placing the dropped files failed: ${err.message || err}`;
            console.error(msg);
            post({ status: 'error', fileName: entries.join(', '), message: msg });
        }
    }

    async function handleDrop(ev) {
        ev.preventDefault();
        ev.stopPropagation();
        if (!canUpload()) {
            console.log("File upload via drag-drop blocked (shared/viewer session).");
            return;
        }
        if (!beginOperation()) {
            return;
        }
        const point = resolveDropPoint(ev);
        const dropId = point ? newDropId() : null;
        const drop = { headers: dropId ? { 'X-Upload-Drop': dropId } : null, uploaded: 0 };
        const topNames = [];
        try {
            const entriesToProcess = [];
            if (ev.dataTransfer.items) {
                for (let i = 0; i < ev.dataTransfer.items.length; i++) {
                    const item = ev.dataTransfer.items[i];
                    if (item.kind !== 'file') continue;
                    let entry = null;
                    if (typeof item.webkitGetAsEntry === 'function') entry = item.webkitGetAsEntry();
                    else if (typeof item.getAsEntry === 'function') entry = item.getAsEntry();
                    if (entry) entriesToProcess.push(entry);
                }
            } else if (ev.dataTransfer.files.length > 0) {
                for (let i = 0; i < ev.dataTransfer.files.length; i++) {
                    const file = ev.dataTransfer.files[i];
                    try {
                        await uploadFileObject(file, file.name, drop.headers);
                        topNames.push(file.name);
                    } catch (err) {
                        console.error(`Error uploading ${file.name}: ${err}`);
                    }
                }
                if (dropId && topNames.length > 0) await placeDrop(dropId, point, topNames);
                return;
            }
            try {
                for (const entry of entriesToProcess) {
                    const uploadedBefore = drop.uploaded;
                    try {
                        await handleDroppedEntry(entry, "", drop);
                    } finally {
                        // An empty folder uploads nothing and has no staged entry to place.
                        if (drop.uploaded > uploadedBefore && !topNames.includes(entry.name)) topNames.push(entry.name);
                    }
                }
            } catch (error) {
                const errorMsg = `Error during sequential upload: ${error.message || error}`;
                post({ status: 'error', fileName: 'N/A', message: errorMsg });
            }
            if (dropId && topNames.length > 0) {
                await placeDrop(dropId, point, topNames);
            }
        } finally {
            operationInFlight = false;
        }
    }

    return {
        uploadFileObject,
        handleRequestFileUpload,
        handleFileInputChange,
        handleDragOver,
        handleDrop,
    };
}
