/*
    SPDX-License-Identifier: GPL-2.0-or-later

    Selkies KWin adapter 的请求解析与校验。

    这一层刻意不依赖任何 KWin 头文件，只依赖 Qt6 Core/Json，因此可以在没有
    Wayland 会话的情况下离线编译并做单元测试；插件本体只负责把校验结果落到
    VirtualBackend 的输出对象上。
*/

#pragma once

#include <QJsonObject>
#include <QJsonValue>
#include <QString>

#include <optional>

/// 解析层的命名空间刻意不叫 `SelkiesKWinAdapter`：插件类本身就是
/// `KWin::SelkiesKWinAdapter`，同名会让类内的限定名解析到类而不是命名空间。
namespace SelkiesAdapterProtocol
{

/// `op=cursor` 的解析结果。
struct CursorRequest
{
    /// true：抑制该输出的软件光标层（CSS 光标模式）；false：恢复视频里的光标。
    bool hidden = false;
    /// 可选：目标输出在 `VirtualBackend::outputs()` 中的下标。
    std::optional<int> outputIndex;
    /// 可选：目标输出的名字（例如 "Virtual-0"）。
    std::optional<QString> outputName;
};

/**
 * 解析并严格校验 `op=cursor` 请求。
 *
 * 校验规则：
 * - `hidden` 必须是 JSON 布尔值，缺失或类型不符都判失败；
 * - `output_index`、`output_name` 可选，但给出来就必须是合法类型与非负/非空值；
 * - 未知字段忽略，便于将来扩展。
 *
 * 失败时不抛异常，只返回 false 并写入 `error`，由调用方回结构化错误响应。
 *
 * @param request 已解析成对象的单行 JSON 请求。
 * @param out 成功时写入解析结果，不得为空。
 * @param error 失败时写入可诊断的错误文本，不得为空。
 * @returns 校验通过返回 true。
 */
inline bool parseCursorRequest(const QJsonObject &request, CursorRequest *out, QString *error)
{
    if (!out || !error) {
        return false;
    }

    const QJsonValue hidden = request.value(QStringLiteral("hidden"));
    if (!hidden.isBool()) {
        *error = QStringLiteral("cursor 操作需要布尔字段 hidden");
        return false;
    }

    CursorRequest parsed;
    parsed.hidden = hidden.toBool();

    const QJsonValue index = request.value(QStringLiteral("output_index"));
    if (!index.isUndefined() && !index.isNull()) {
        if (!index.isDouble()) {
            *error = QStringLiteral("output_index 必须是整数");
            return false;
        }
        const double raw = index.toDouble();
        const int value = index.toInt(-1);
        if (value < 0 || raw != static_cast<double>(value)) {
            *error = QStringLiteral("output_index 必须是非负整数");
            return false;
        }
        parsed.outputIndex = value;
    }

    const QJsonValue name = request.value(QStringLiteral("output_name"));
    if (!name.isUndefined() && !name.isNull()) {
        if (!name.isString()) {
            *error = QStringLiteral("output_name 必须是字符串");
            return false;
        }
        const QString text = name.toString();
        if (text.isEmpty()) {
            *error = QStringLiteral("output_name 不能为空");
            return false;
        }
        parsed.outputName = text;
    }

    *out = parsed;
    return true;
}

} // namespace SelkiesAdapterProtocol
