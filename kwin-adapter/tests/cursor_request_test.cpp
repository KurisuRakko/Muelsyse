/*
    SPDX-License-Identifier: GPL-2.0-or-later

    `op=cursor` 请求解析的离线单元测试。

    只依赖 Qt6 Core，可用下面的命令在任意机器上编译运行（不需要 KWin 会话）：

        g++ -std=c++20 tests/cursor_request_test.cpp -o cursor_request_test \
            $(pkg-config --cflags --libs Qt6Core)
        ./cursor_request_test
*/

#include "../src/selkies_kwin_adapter_protocol.h"

#include <QJsonDocument>
#include <QJsonObject>

#include <cstdio>

namespace
{

int failures = 0;

QJsonObject parseObject(const char *line)
{
    return QJsonDocument::fromJson(QByteArray(line)).object();
}

void expectOk(const char *line, bool hidden, int expectedIndex, const QString &expectedName)
{
    SelkiesAdapterProtocol::CursorRequest request;
    QString error;
    const bool ok = SelkiesAdapterProtocol::parseCursorRequest(parseObject(line), &request, &error);
    if (!ok) {
        std::printf("FAIL %s -> 应通过但被拒绝: %s\n", line, qPrintable(error));
        ++failures;
        return;
    }
    if (request.hidden != hidden) {
        std::printf("FAIL %s -> hidden 期望 %d 实际 %d\n", line, hidden ? 1 : 0, request.hidden ? 1 : 0);
        ++failures;
        return;
    }
    const int index = request.outputIndex.value_or(-1);
    if (index != expectedIndex) {
        std::printf("FAIL %s -> output_index 期望 %d 实际 %d\n", line, expectedIndex, index);
        ++failures;
        return;
    }
    const QString name = request.outputName.value_or(QString());
    if (name != expectedName) {
        std::printf("FAIL %s -> output_name 期望 %s 实际 %s\n",
                    line, qPrintable(expectedName), qPrintable(name));
        ++failures;
        return;
    }
    std::printf("PASS %s -> hidden=%d index=%d name=%s\n",
                line, request.hidden ? 1 : 0, index, qPrintable(name));
}

void expectError(const char *line)
{
    SelkiesAdapterProtocol::CursorRequest request;
    QString error;
    const bool ok = SelkiesAdapterProtocol::parseCursorRequest(parseObject(line), &request, &error);
    if (ok) {
        std::printf("FAIL %s -> 应被拒绝但通过了\n", line);
        ++failures;
        return;
    }
    if (error.isEmpty()) {
        std::printf("FAIL %s -> 拒绝时没有给出错误文本\n", line);
        ++failures;
        return;
    }
    std::printf("PASS %s -> %s\n", line, qPrintable(error));
}

} // namespace

int main()
{
    expectOk(R"({"op":"cursor","hidden":true})", true, -1, QString());
    expectOk(R"({"op":"cursor","hidden":false,"output_index":0})", false, 0, QString());
    expectOk(R"({"op":"cursor","hidden":true,"output_name":"Virtual-0"})", true, -1, QStringLiteral("Virtual-0"));
    expectOk(R"({"op":"cursor","hidden":true,"output_index":1,"output_name":"Virtual-1","extra":"ignored"})",
             true, 1, QStringLiteral("Virtual-1"));

    expectError(R"({"op":"cursor"})");
    expectError(R"({"op":"cursor","hidden":"true"})");
    expectError(R"({"op":"cursor","hidden":1})");
    expectError(R"({"op":"cursor","hidden":null})");
    expectError(R"({"op":"cursor","hidden":true,"output_index":-1})");
    expectError(R"({"op":"cursor","hidden":true,"output_index":1.5})");
    expectError(R"({"op":"cursor","hidden":true,"output_index":"0"})");
    expectError(R"({"op":"cursor","hidden":true,"output_name":""})");
    expectError(R"({"op":"cursor","hidden":true,"output_name":7})");

    if (failures != 0) {
        std::printf("cursor_request_test: %d 项失败\n", failures);
        return 1;
    }
    std::printf("cursor_request_test: 全部通过\n");
    return 0;
}
