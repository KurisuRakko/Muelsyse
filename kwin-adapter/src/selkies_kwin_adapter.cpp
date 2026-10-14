/*
    SPDX-License-Identifier: GPL-2.0-or-later
*/

#include "backends/virtual/virtual_backend.h"
#include "core/output.h"
#include "core/renderloop.h"
#include "main.h"
#include "plugin.h"
#include "selkies_kwin_adapter_protocol.h"

#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLocalServer>
#include <QLocalSocket>
#include <QLoggingCategory>

#include <sys/socket.h>
#include <unistd.h>

namespace KWin
{

Q_LOGGING_CATEGORY(SELKIES_KWIN_ADAPTER, "kwin.selkies.adapter", QtWarningMsg)

namespace
{

constexpr qsizetype MaxRequestBytes = 16 * 1024;
constexpr int MinDimension = 64;
constexpr int MaxWidth = 7680;
constexpr int MaxHeight = 4320;
constexpr qint64 MaxPixels = 16'777'216;

QString socketPath()
{
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    if (runtime.isEmpty()) {
        return {};
    }

    const QString root = QDir::cleanPath(runtime);
    const QString configured = qEnvironmentVariable("SELKIES_KWIN_ADAPTER_SOCKET");
    const QString path = QDir::cleanPath(configured.isEmpty() ? root + QStringLiteral("/selkies-kwin-adapter.sock") : configured);
    if (path == root || !path.startsWith(root + QLatin1Char('/'))) {
        return {};
    }
    return path;
}

bool validMode(int width, int height, int refreshRate)
{
    return width >= MinDimension && height >= MinDimension
        && width <= MaxWidth && height <= MaxHeight
        && qint64(width) * qint64(height) <= MaxPixels
        && refreshRate >= 30'000 && refreshRate <= 120'000;
}

bool isSameUser(QLocalSocket *socket)
{
    const qintptr descriptor = socket->socketDescriptor();
    if (descriptor < 0) {
        return false;
    }

    struct ucred credentials {
    };
    socklen_t length = sizeof(credentials);
    return getsockopt(static_cast<int>(descriptor), SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0
        && credentials.uid == geteuid();
}

QJsonObject errorResponse(const QString &message)
{
    return QJsonObject{
        {QStringLiteral("ok"), false},
        {QStringLiteral("error"), message},
    };
}

} // namespace

/**
 * KWin 内部的最小 Selkies 适配层。
 *
 * 该插件只准备 VirtualBackend 已有输出对象的下一个 mode，不创建桌面、视频流、
 * 音频流或远程命令接口。真正的 mode apply 仍通过 KDE output-management-v2 完成。
 */
class SelkiesKWinAdapter final : public Plugin
{
    Q_OBJECT

public:
    SelkiesKWinAdapter()
        : m_server(std::make_unique<QLocalServer>())
    {
        const QString path = socketPath();
        if (path.isEmpty()) {
            qCWarning(SELKIES_KWIN_ADAPTER) << "XDG_RUNTIME_DIR 或 socket 路径无效";
            return;
        }

        QLocalServer::removeServer(path);
        m_server->setSocketOptions(QLocalServer::UserAccessOption);
        connect(m_server.get(), &QLocalServer::newConnection, this, &SelkiesKWinAdapter::acceptConnections);
        if (!m_server->listen(path)) {
            qCWarning(SELKIES_KWIN_ADAPTER) << "无法监听" << path << m_server->errorString();
            return;
        }
        m_socketPath = path;
        qCInfo(SELKIES_KWIN_ADAPTER) << "已监听" << path;
    }

    ~SelkiesKWinAdapter() override
    {
        if (m_server) {
            m_server->close();
        }
        if (!m_socketPath.isEmpty()) {
            QLocalServer::removeServer(m_socketPath);
        }
    }

private Q_SLOTS:
    void acceptConnections()
    {
        while (m_server->hasPendingConnections()) {
            auto *socket = m_server->nextPendingConnection();
            m_buffers.insert(socket, {});
            connect(socket, &QLocalSocket::readyRead, this, &SelkiesKWinAdapter::readRequest);
            connect(socket, &QLocalSocket::disconnected, this, [this, socket] {
                m_buffers.remove(socket);
                socket->deleteLater();
            });
        }
    }

    void readRequest()
    {
        auto *socket = qobject_cast<QLocalSocket *>(sender());
        if (!socket || !isSameUser(socket)) {
            if (socket) {
                writeResponse(socket, errorResponse(QStringLiteral("socket peer uid 不匹配")));
                socket->disconnectFromServer();
            }
            return;
        }

        QByteArray &buffer = m_buffers[socket];
        buffer += socket->readAll();
        if (buffer.size() > MaxRequestBytes) {
            writeResponse(socket, errorResponse(QStringLiteral("请求过大")));
            socket->disconnectFromServer();
            return;
        }

        qsizetype newline = -1;
        while ((newline = buffer.indexOf('\n')) >= 0) {
            const QByteArray line = buffer.left(newline).trimmed();
            buffer.remove(0, newline + 1);
            handleRequest(socket, line);
            if (socket->state() != QLocalSocket::ConnectedState) {
                return;
            }
        }
    }

private:
    void writeResponse(QLocalSocket *socket, const QJsonObject &response)
    {
        socket->write(QJsonDocument(response).toJson(QJsonDocument::Compact));
        socket->write("\n");
        socket->flush();
    }

    QJsonObject status() const
    {
        const auto *backend = dynamic_cast<VirtualBackend *>(kwinApp()->outputBackend());
        if (!backend) {
            return errorResponse(QStringLiteral("当前 KWin backend 不是 virtual"));
        }

        QJsonArray outputs;
        const auto available = backend->outputs();
        for (int index = 0; index < available.size(); ++index) {
            const Output *output = available.at(index);
            QJsonArray modes;
            for (const auto &mode : output->modes()) {
                modes.append(QJsonObject{
                    {QStringLiteral("width"), mode->size().width()},
                    {QStringLiteral("height"), mode->size().height()},
                    {QStringLiteral("refresh_mhz"), static_cast<int>(mode->refreshRate())},
                });
            }
            outputs.append(QJsonObject{
                {QStringLiteral("index"), index},
                {QStringLiteral("name"), output->name()},
                {QStringLiteral("width"), output->modeSize().width()},
                {QStringLiteral("height"), output->modeSize().height()},
                {QStringLiteral("modes"), modes},
            });
        }
        return QJsonObject{
            {QStringLiteral("ok"), true},
            {QStringLiteral("backend"), QStringLiteral("virtual")},
            {QStringLiteral("outputs"), outputs},
        };
    }

    QJsonObject prepare(const QJsonObject &request)
    {
        auto *backend = dynamic_cast<VirtualBackend *>(kwinApp()->outputBackend());
        if (!backend) {
            return errorResponse(QStringLiteral("当前 KWin backend 不是 virtual"));
        }

        const int index = request.value(QStringLiteral("output_index")).toInt(-1);
        const int width = request.value(QStringLiteral("width")).toInt(0);
        const int height = request.value(QStringLiteral("height")).toInt(0);
        const int refreshRate = request.value(QStringLiteral("refresh_mhz")).toInt(60'000);
        if (!validMode(width, height, refreshRate)) {
            return errorResponse(QStringLiteral("目标 mode 超出安全范围"));
        }
        if (!backend->prepareOutputResize(index, QSize(width, height), refreshRate)) {
            return errorResponse(QStringLiteral("找不到目标 virtual output 或准备 mode 失败"));
        }

        return QJsonObject{
            {QStringLiteral("ok"), true},
            {QStringLiteral("output_index"), index},
            {QStringLiteral("width"), width},
            {QStringLiteral("height"), height},
            {QStringLiteral("refresh_mhz"), refreshRate},
        };
    }

    QJsonObject repaint() const
    {
        auto *backend = dynamic_cast<VirtualBackend *>(kwinApp()->outputBackend());
        if (!backend) {
            return errorResponse(QStringLiteral("当前 KWin backend 不是 virtual"));
        }

        int scheduled = 0;
        for (Output *output : backend->outputs()) {
            if (!output || !output->renderLoop()) {
                continue;
            }
            output->renderLoop()->scheduleRepaint();
            ++scheduled;
        }
        if (scheduled == 0) {
            return errorResponse(QStringLiteral("没有可重绘的 virtual output"));
        }
        qCInfo(SELKIES_KWIN_ADAPTER) << "已调度 output repaint" << scheduled;
        return QJsonObject{
            {QStringLiteral("ok"), true},
            {QStringLiteral("outputs"), scheduled},
        };
    }

    /**
     * 按输出切换“软件光标是否画进合成结果”。
     *
     * Selkies 的 CSS 光标模式需要视频里没有光标，但 screencast 的 cursor metadata
     * 必须照常提供，因此这里改的是 Output::setSoftwareCursorSuppressed()，而不是
     * Cursors::hideCursor()（后者会让 OutputScreenCastSource::includesCursor() 变成
     * false，把 metadata 一起停掉）。状态切换会同步触发 compositor 重新评估光标层，
     * 这里再显式调度一次重绘，保证下一帧就反映新状态。
     */
    QJsonObject cursor(const QJsonObject &request)
    {
        auto *backend = dynamic_cast<VirtualBackend *>(kwinApp()->outputBackend());
        if (!backend) {
            return errorResponse(QStringLiteral("当前 KWin backend 不是 virtual"));
        }

        SelkiesAdapterProtocol::CursorRequest parsed;
        QString parseError;
        if (!SelkiesAdapterProtocol::parseCursorRequest(request, &parsed, &parseError)) {
            return errorResponse(parseError);
        }

        const auto available = backend->outputs();
        if (parsed.outputIndex.has_value() && *parsed.outputIndex >= available.size()) {
            return errorResponse(QStringLiteral("output_index 超出当前输出数量"));
        }

        QJsonArray applied;
        int touched = 0;
        for (int index = 0; index < available.size(); ++index) {
            Output *output = available.at(index);
            if (!output) {
                continue;
            }
            const bool indexMatches = !parsed.outputIndex.has_value() || index == *parsed.outputIndex;
            const bool nameMatches = !parsed.outputName.has_value() || output->name() == *parsed.outputName;
            if (!indexMatches && !nameMatches) {
                continue;
            }
            if (!indexMatches || !nameMatches) {
                // 两个选择器给出后只有一个匹配：请求自相矛盾，明确报错而不是猜一个。
                return errorResponse(QStringLiteral("output_name 与 output_index 指向不同输出"));
            }

            output->setSoftwareCursorSuppressed(parsed.hidden);
            if (output->renderLoop()) {
                output->renderLoop()->scheduleRepaint();
            }
            applied.append(QJsonObject{
                {QStringLiteral("index"), index},
                {QStringLiteral("name"), output->name()},
                {QStringLiteral("hidden"), parsed.hidden},
            });
            ++touched;
        }

        if (touched == 0) {
            return errorResponse(QStringLiteral("没有匹配的 virtual output"));
        }

        qCInfo(SELKIES_KWIN_ADAPTER) << "光标抑制状态" << parsed.hidden << "已应用到" << touched << "个输出";
        return QJsonObject{
            {QStringLiteral("ok"), true},
            {QStringLiteral("hidden"), parsed.hidden},
            {QStringLiteral("outputs"), applied},
        };
    }

    void handleRequest(QLocalSocket *socket, const QByteArray &line)
    {
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(line, &parseError);
        if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
            writeResponse(socket, errorResponse(QStringLiteral("请求必须是单行 JSON 对象")));
            return;
        }

        const QJsonObject request = document.object();
        const QString operation = request.value(QStringLiteral("op")).toString();
        if (operation == QLatin1String("status")) {
            writeResponse(socket, status());
        } else if (operation == QLatin1String("prepare")) {
            writeResponse(socket, prepare(request));
        } else if (operation == QLatin1String("repaint")) {
            writeResponse(socket, repaint());
        } else if (operation == QLatin1String("cursor")) {
            writeResponse(socket, cursor(request));
        } else {
            writeResponse(socket, errorResponse(QStringLiteral("未知操作")));
        }
    }

    std::unique_ptr<QLocalServer> m_server;
    QString m_socketPath;
    QHash<QLocalSocket *, QByteArray> m_buffers;
};

class SelkiesKWinAdapterFactory final : public PluginFactory
{
    Q_OBJECT
    Q_PLUGIN_METADATA(IID PluginFactory_iid FILE "metadata.json")
    Q_INTERFACES(KWin::PluginFactory)

public:
    std::unique_ptr<Plugin> create() const override
    {
        if (kwinApp()->operationMode() != Application::OperationModeWayland) {
            return nullptr;
        }
        return std::make_unique<SelkiesKWinAdapter>();
    }
};

} // namespace KWin

#include "selkies_kwin_adapter.moc"
