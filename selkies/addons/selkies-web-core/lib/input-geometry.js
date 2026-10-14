/**
 * 纯函数式的输入几何变换。
 *
 * 所有输入都在 CSS 像素和远端 framebuffer 像素之间转换；本模块不读取
 * window、DOM 或 devicePixelRatio，因此可以用伪造的矩形数据做文本单元测试。
 */

const isPositive = (value) => Number.isFinite(value) && value > 0;

/**
 * 计算 sink 在可见 CSS 矩形中实际绘制的内容区域。
 *
 * @param {{left:number, top:number, width:number, height:number}} rect
 * @param {number} streamWidth 远端 framebuffer 宽度
 * @param {number} streamHeight 远端 framebuffer 高度
 * @param {string} [objectFit='contain'] CSS object-fit
 * @returns {{boxLeft:number, boxTop:number, boxW:number, boxH:number,
 *   sinkW:number, sinkH:number, scaleX:number, scaleY:number}|null}
 */
export function streamGeometryFromSink(rect, streamWidth, streamHeight, objectFit = 'contain') {
    const left = Number(rect?.left);
    const top = Number(rect?.top);
    const width = Number(rect?.width);
    const height = Number(rect?.height);
    const sinkW = Number(streamWidth);
    const sinkH = Number(streamHeight);
    if (![left, top, width, height].every(Number.isFinite)
        || !isPositive(width) || !isPositive(height)
        || !isPositive(sinkW) || !isPositive(sinkH)) {
        return null;
    }

    let boxLeft = left;
    let boxTop = top;
    let boxW = width;
    let boxH = height;
    if (objectFit !== 'fill') {
        const fit = Math.min(width / sinkW, height / sinkH);
        if (!isPositive(fit)) return null;
        boxW = sinkW * fit;
        boxH = sinkH * fit;
        boxLeft += (width - boxW) / 2;
        boxTop += (height - boxH) / 2;
    }
    if (!isPositive(boxW) || !isPositive(boxH)) return null;
    return {
        boxLeft, boxTop, boxW, boxH, sinkW, sinkH,
        scaleX: sinkW / boxW,
        scaleY: sinkH / boxH,
    };
}

/**
 * 把 client 坐标映射到远端 framebuffer，保留小数交给调用者最后统一取整。
 *
 * @param {number} clientX
 * @param {number} clientY
 * @param {{boxLeft:number, boxTop:number, scaleX:number, scaleY:number}} geometry
 * @returns {{x:number, y:number}|null}
 */
export function mapClientToStream(clientX, clientY, geometry) {
    if (!geometry || !Number.isFinite(clientX) || !Number.isFinite(clientY)
        || !isPositive(geometry.scaleX) || !isPositive(geometry.scaleY)) {
        return null;
    }
    return {
        x: (clientX - geometry.boxLeft) * geometry.scaleX,
        y: (clientY - geometry.boxTop) * geometry.scaleY,
    };
}

/**
 * 把 pointer-lock 的 CSS 相对位移变成远端像素位移。
 *
 * @param {number} deltaX
 * @param {number} deltaY
 * @param {{scaleX:number, scaleY:number}} geometry
 * @returns {{x:number, y:number}|null}
 */
export function mapRelativeToStream(deltaX, deltaY, geometry) {
    if (!geometry || !Number.isFinite(deltaX) || !Number.isFinite(deltaY)
        || !isPositive(geometry.scaleX) || !isPositive(geometry.scaleY)) {
        return null;
    }
    return { x: deltaX * geometry.scaleX, y: deltaY * geometry.scaleY };
}
