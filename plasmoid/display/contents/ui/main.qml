pragma ComponentBehavior: Bound

/*
    Tray panel for the remote desktop's virtual display (resolution, scale,
    pin/follow, leases).

    All real work is done by ~/.local/bin/muelsyse-display (the CLI client of
    muelsyse-displayd); this applet only polls `status --json` and runs
    set / pin / follow / release. Controls never keep their own state: what
    they show always comes back from status.

    Only validated integers, whitelisted scale strings and regex-checked
    lease names ever reach a command line; strings from status are display-only.
*/

import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents3

PlasmoidItem {
    id: root

    // plasmashell's PATH has no ~/.local/bin; the executable engine runs
    // commands through a shell, so $HOME / ${…:-…} expand there.
    readonly property string tool: "\"${MUELSYSE_DISPLAY_CLI:-$HOME/.local/bin/muelsyse-display}\""
    readonly property string statusCmd: tool + " status --json"

    readonly property var presets: [[3840, 2160], [2560, 1440], [2560, 1600], [1920, 1080], [1920, 1200]]
    readonly property int customIndex: presets.length
    readonly property var scales: [1.0, 1.25, 1.5, 1.75, 2.0]
    readonly property var scaleArgs: ["1.0", "1.25", "1.5", "1.75", "2.0"]
    readonly property int minSide: 320
    readonly property int maxSide: 4080
    readonly property var leaseNameRe: /^[A-Za-z0-9_.-]{1,64}$/

    // Last good status (display-only strings); statusKnown false = unknown / failed.
    property bool statusKnown: false
    property bool daemonDown: false
    property string statusError: ""
    property int curW: 0
    property int curH: 0
    property real curScale: 0
    property bool pinned: false
    property var leases: []          // [{name, expires}]
    property string clients: "unknown"  // yes | no | unknown
    property bool uuWatching: false

    // Selection in the panel; follows status until the user touches a control.
    property bool userEdited: false
    property bool customPicked: false
    property int selW: 0
    property int selH: 0
    property int selScaleIdx: 0

    property bool forceMode: false     // one-shot: next apply passes --force
    property bool busy: false          // a set/pin/follow/release is running
    property string busyCmd: ""
    property string busyKind: ""       // set | pin | follow | release
    property string busyArg: ""        // lease name for release
    property string resultText: ""
    property bool resultIsError: false

    property bool statusRunning: false
    property bool statusAgain: false   // refresh requested while one was running

    // displayd 只有在确认网页端没人时才肯改（不确定也拒），这里同样只认 "no"。
    readonly property bool webBusy: clients !== "no"
    readonly property bool controlsEnabled: statusKnown && !daemonDown && !busy
    readonly property int presetIdx: presetIndex(selW, selH)
    readonly property bool customMode: customPicked || presetIdx < 0
    readonly property bool selValid: validSide(selW) && validSide(selH)
        && selScaleIdx >= 0 && selScaleIdx < scales.length
    readonly property bool selChanged: selW !== curW || selH !== curH
        || Math.abs(scales[selScaleIdx] - curScale) > 0.005

    Plasmoid.icon: "video-display"
    Plasmoid.status: daemonDown || (resultIsError && resultText !== "")
        ? PlasmaCore.Types.NeedsAttentionStatus
        : PlasmaCore.Types.ActiveStatus

    toolTipMainText: {
        if (daemonDown) {
            return "显示器：muelsyse-displayd 没在运行"
        }
        if (!statusKnown) {
            return "显示器：状态未知"
        }
        return "显示器 " + curW + "×" + curH + " · " + pct(curScale)
    }
    toolTipSubText: {
        if (daemonDown) {
            return "systemctl --user start muelsyse-displayd"
        }
        if (!statusKnown) {
            return statusError
        }
        return (pinned ? "已锁定" : "跟随网页端窗口") + "\n" + clientsText() + " · " + uuText()
    }

    switchWidth: Kirigami.Units.gridUnit * 16
    switchHeight: Kirigami.Units.gridUnit * 12

    onExpandedChanged: {
        if (root.expanded) {
            if (!busy) {
                userEdited = false
                forceMode = false
                resultText = ""
                resultIsError = false
                syncSelection()
            }
            refresh()
        }
    }

    // ---- helpers -------------------------------------------------------

    function pct(s) {
        return Math.round(s * 100) + "%"
    }

    function clientsText() {
        switch (clients) {
        case "yes": return "网页端：有人在看"
        case "no": return "网页端：没人"
        default: return "网页端：不确定"
        }
    }

    function uuText() {
        return uuWatching ? "UU：在看" : "UU：没在看"
    }

    function validSide(v) {
        return Number.isInteger(v) && v >= minSide && v <= maxSide && v % 2 === 0
    }

    function presetIndex(w, h) {
        for (let i = 0; i < presets.length; i++) {
            if (presets[i][0] === w && presets[i][1] === h) {
                return i
            }
        }
        return -1
    }

    function nearestScaleIdx(s) {
        let best = 0
        for (let i = 1; i < scales.length; i++) {
            if (Math.abs(scales[i] - s) < Math.abs(scales[best] - s)) {
                best = i
            }
        }
        return best
    }

    function shellQuote(s) {
        return "'" + s.replace(/'/g, "'\\''") + "'"
    }

    function syncSelection() {
        if (!statusKnown) {
            return
        }
        customPicked = false
        selW = curW
        selH = curH
        selScaleIdx = nearestScaleIdx(curScale)
    }

    function formatExpiry(sec) {
        if (typeof sec !== "number" || !isFinite(sec)) {
            return ""
        }
        return Qt.formatDateTime(new Date(sec * 1000), "MM-dd HH:mm")
    }

    // ---- status --------------------------------------------------------

    function refresh() {
        if (statusRunning) {
            statusAgain = true
            return
        }
        statusRunning = true
        executable.connectSource(statusCmd)
    }

    function intField(v) {
        return typeof v === "number" && Number.isInteger(v) ? v : NaN
    }

    function applyStatus(code, out, err) {
        if (code === 3) {
            daemonDown = true
            statusKnown = false
            statusError = "muelsyse-displayd 没在运行"
            return
        }
        daemonDown = false
        let d = null
        if (code === 0) {
            try {
                d = JSON.parse(out)
            } catch (e) {
                d = null
            }
        }
        const mode = d && typeof d === "object" ? d.mode : null
        const w = mode && typeof mode === "object" ? intField(mode.w) : NaN
        const h = mode && typeof mode === "object" ? intField(mode.h) : NaN
        const s = d && typeof d.scale === "number" ? d.scale : NaN
        if (!d || d.ok !== true || isNaN(w) || isNaN(h) || !isFinite(s)) {
            statusKnown = false
            statusError = code === 0 ? "无法解析显示器状态"
                : "读取显示器状态失败（退出码 " + code + "）" + (err ? "：" + err : "")
            return
        }
        curW = w
        curH = h
        curScale = s
        pinned = d.policy === "pinned"
        const sel = d.selkies && typeof d.selkies === "object" ? d.selkies : {}
        clients = sel.clients === "yes" || sel.clients === "no" ? sel.clients : "unknown"
        uuWatching = d.uu_watching === true
        const list = []
        if (Array.isArray(d.leases)) {
            for (const l of d.leases) {
                if (l && typeof l === "object" && typeof l.name === "string") {
                    list.push({ name: l.name, expires: formatExpiry(l.expires_at) })
                }
            }
        }
        leases = list
        statusKnown = true
        statusError = ""
        if (!userEdited && !busy) {
            syncSelection()
        }
    }

    // ---- actions -------------------------------------------------------

    // QML 方法调用必须把参数给全，少传会报 Insufficient arguments 并且什么都不做。
    function run(kind, args, arg) {
        if (busy || !statusKnown || daemonDown) {
            return
        }
        busy = true
        busyKind = kind
        busyArg = arg || ""
        busyCmd = tool + " " + args
        resultText = ""
        resultIsError = false
        executable.connectSource(busyCmd)
    }

    function applySelection() {
        if (!selValid || !selChanged || (webBusy && !forceMode)) {
            return
        }
        run("set", "set " + selW + "x" + selH + " --scale " + scaleArgs[selScaleIdx]
            + (forceMode ? " --force" : ""), "")
    }

    function setPinned(on) {
        if (on) {
            run("pin", "pin", "")
        } else {
            run("follow", "follow", "")
        }
    }

    function releaseLease(name) {
        if (!leaseNameRe.test(name)) {
            return
        }
        run("release", "release " + shellQuote(name), name)
    }

    // Same wording as scripts/muelsyse-display-menu.
    function rejectText(err, code) {
        const line = err.split("\n").find(l => l.startsWith("rejected:"))
        if (!line) {
            return "命令失败（退出码 " + code + "）" + (err ? "：" + err : "")
        }
        const rest = line.slice("rejected:".length).trim()
        const sp = rest.indexOf(" ")
        const reason = sp < 0 ? rest : rest.slice(0, sp)
        const detail = sp < 0 ? "" : rest.slice(sp + 1)
        if (reason === "selkies_active") {
            return "网页端正有人连着，请在网页端侧栏改分辨率，或先关掉网页端；也可以勾选「强制修改」"
        } else if (reason === "pinned") {
            return "当前已锁定，先改回跟随或直接在这里改"
        } else if (reason === "leased:sunshine") {
            return "Moonlight 正在串流（Sunshine 租约），结束后再改，或先释放租约；也可以勾选「强制修改」"
        } else if (reason.startsWith("leased:")) {
            return reason.slice("leased:".length) + " 持有租约，结束后再改，或先释放租约；也可以勾选「强制修改」"
        } else if (reason === "verify_failed") {
            return "切换后校验失败，已恢复原设置"
        } else if (reason === "busy") {
            return "正在处理别的请求，稍后再试"
        } else if (reason === "invalid") {
            return "参数不合法" + (detail ? "：" + detail : "")
        } else if (reason === "backend_error") {
            return "显示后端出错" + (detail ? "：" + detail : "")
        }
        return rest
    }

    function finishAction(code, out, err) {
        const kind = busyKind
        const wasUu = uuWatching
        busy = false
        busyCmd = ""
        if (code === 0) {
            resultIsError = false
            const m = out.match(/^applied (\d+)x(\d+) scale ([0-9.]+)/)
            if (kind === "pin") {
                // Bare pin only locks the current value; the CLI says unchanged.
                resultText = "已锁定当前设置"
            } else if (kind === "follow") {
                resultText = "已改回跟随网页端窗口"
            } else if (kind === "release") {
                resultText = out.startsWith("released") ? "已释放 " + busyArg + " 租约"
                    : busyArg + " 没有租约（可能已过期）"
            } else if (out.startsWith("unchanged")) {
                resultText = "已经是这个设置"
            } else if (m) {
                // displayd restarts UU on a scale change: UU keeps its stale
                // logical size otherwise, even across reconnects.
                resultText = "已切换到 " + m[1] + "×" + m[2] + "，缩放 " + pct(parseFloat(m[3]))
                    + (/ uu-restarted$/.test(out) ? "\nUU 已重启，请重新连接"
                       : wasUu ? "\nUU 画面若卡住请断开重连" : "")
            } else {
                resultText = "已应用：" + (out || "完成")
            }
            if (kind === "set") {
                userEdited = false
                forceMode = false
            }
        } else if (code === 3) {
            daemonDown = true
            statusKnown = false
            resultIsError = true
            resultText = "muelsyse-displayd 没在运行"
        } else if (code === 4) {
            resultIsError = true
            resultText = "没等到 muelsyse-displayd 的回复，请求可能已执行；以刷新后的状态为准"
        } else {
            resultIsError = true
            resultText = rejectText(err, code)
        }
        busyKind = ""
        busyArg = ""
        refresh()
    }

    P5Support.DataSource {
        id: executable
        engine: "executable"
        connectedSources: []

        onNewData: (source, data) => {
            disconnectSource(source)
            const code = data["exit code"]
            const out = (data["stdout"] || "").trim()
            const err = (data["stderr"] || "").trim()

            if (source === root.statusCmd) {
                root.statusRunning = false
                root.applyStatus(code, out, err)
                if (root.statusAgain) {
                    root.statusAgain = false
                    root.refresh()
                }
            } else if (source === root.busyCmd) {
                root.finishAction(code, out, err)
            }
        }
    }

    Timer {
        interval: root.expanded ? 3000 : 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    // ---- popup ---------------------------------------------------------

    fullRepresentation: ColumnLayout {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.preferredHeight: implicitHeight
        spacing: Kirigami.Units.smallSpacing

        // Daemon not running: hint only, everything else hidden.
        ColumnLayout {
            visible: root.daemonDown
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: "dialog-warning"
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: Kirigami.Units.iconSizes.large
                Layout.preferredHeight: Kirigami.Units.iconSizes.large
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                text: "muelsyse-displayd 没在运行。可以在终端里执行："
            }
            PlasmaComponents3.TextField {
                Layout.fillWidth: true
                readOnly: true
                font.family: "monospace"
                text: "systemctl --user start muelsyse-displayd"
            }
            PlasmaComponents3.Button {
                Layout.alignment: Qt.AlignHCenter
                icon.name: "view-refresh"
                text: "重试"
                onClicked: root.refresh()
            }
        }

        ColumnLayout {
            visible: !root.daemonDown
            Layout.fillWidth: true
            Layout.margins: Kirigami.Units.smallSpacing
            spacing: Kirigami.Units.smallSpacing

            // 1. status
            RowLayout {
                Layout.fillWidth: true
                Kirigami.Heading {
                    Layout.fillWidth: true
                    level: 4
                    elide: Text.ElideRight
                    text: root.statusKnown
                        ? root.curW + "×" + root.curH + " · " + root.pct(root.curScale)
                          + " · " + (root.pinned ? "已锁定" : "跟随")
                        : "状态未知"
                }
                PlasmaComponents3.BusyIndicator {
                    visible: root.busy
                    running: root.busy
                    Layout.preferredWidth: Kirigami.Units.iconSizes.smallMedium
                    Layout.preferredHeight: Kirigami.Units.iconSizes.smallMedium
                }
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                opacity: 0.8
                text: root.statusKnown ? root.clientsText() + "　" + root.uuText() : root.statusError
            }
            Repeater {
                model: root.leases
                delegate: RowLayout {
                    id: leaseRow
                    required property var modelData
                    Layout.fillWidth: true
                    PlasmaComponents3.Label {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        text: "租约 " + leaseRow.modelData.name
                            + (leaseRow.modelData.expires ? "（到 " + leaseRow.modelData.expires + "）" : "")
                    }
                    PlasmaComponents3.Button {
                        text: "释放"
                        enabled: root.controlsEnabled && root.leaseNameRe.test(leaseRow.modelData.name)
                        onClicked: root.releaseLease(leaseRow.modelData.name)
                    }
                }
            }

            Kirigami.Separator {
                Layout.fillWidth: true
            }

            // 2. resolution
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                columnSpacing: Kirigami.Units.smallSpacing
                rowSpacing: Kirigami.Units.smallSpacing
                enabled: root.controlsEnabled

                PlasmaComponents3.Label {
                    text: "分辨率"
                }
                PlasmaComponents3.ComboBox {
                    id: resCombo
                    Layout.fillWidth: true
                    model: root.presets.map(p => p[0] + "×" + p[1]).concat(["自定义"])
                    currentIndex: root.customMode ? root.customIndex : root.presetIdx
                    onActivated: index => {
                        root.userEdited = true
                        if (index === root.customIndex) {
                            root.customPicked = true
                        } else if (index >= 0 && index < root.presets.length) {
                            root.customPicked = false
                            root.selW = root.presets[index][0]
                            root.selH = root.presets[index][1]
                        }
                        currentIndex = Qt.binding(() => root.customMode ? root.customIndex : root.presetIdx)
                    }
                }

                Item {
                    implicitWidth: 1
                }
                RowLayout {
                    Layout.fillWidth: true
                    SideSpinBox {
                        enabled: root.customMode
                        value: root.selW
                        onValueModified: {
                            root.userEdited = true
                            root.customPicked = true
                            root.selW = value - value % 2
                            value = Qt.binding(() => root.selW)
                        }
                    }
                    PlasmaComponents3.Label {
                        text: "×"
                    }
                    SideSpinBox {
                        enabled: root.customMode
                        value: root.selH
                        onValueModified: {
                            root.userEdited = true
                            root.customPicked = true
                            root.selH = value - value % 2
                            value = Qt.binding(() => root.selH)
                        }
                    }
                }

                // 3. scale
                PlasmaComponents3.Label {
                    text: "缩放"
                }
                RowLayout {
                    Layout.fillWidth: true
                    PlasmaComponents3.Slider {
                        id: scaleSlider
                        Layout.fillWidth: true
                        from: 0
                        to: root.scales.length - 1
                        stepSize: 1
                        snapMode: QQC2.Slider.SnapAlways
                        value: root.selScaleIdx
                        onMoved: {
                            root.userEdited = true
                            root.selScaleIdx = Math.round(value)
                            value = Qt.binding(() => root.selScaleIdx)
                        }
                    }
                    PlasmaComponents3.Label {
                        Layout.minimumWidth: Kirigami.Units.gridUnit * 2.5
                        horizontalAlignment: Text.AlignRight
                        font.bold: true
                        text: root.pct(root.scales[root.selScaleIdx] || 0)
                    }
                }
            }

            // 4. pin / follow
            PlasmaComponents3.Switch {
                Layout.fillWidth: true
                text: "锁定当前设置"
                enabled: root.controlsEnabled
                checked: root.pinned
                // Never let the switch flip itself; state always comes from status.
                onToggled: {
                    const want = checked
                    checked = Qt.binding(() => root.pinned)
                    root.setPinned(want)
                }
            }

            // 5. apply + result
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: root.statusKnown && root.webBusy
                wrapMode: Text.Wrap
                color: Kirigami.Theme.neutralTextColor
                text: root.forceMode
                      ? "强制修改：网页端画面可能卡住，或被网页端窗口改回去；刷新网页端即可恢复"
                      : root.clients === "yes"
                      ? "网页端正有人连着，改不了；请在网页端侧栏改、先关掉网页端，或勾选「强制修改」"
                      : "确认不了网页端有没有人在看，暂时改不了；稍后再试，或勾选「强制修改」"
            }
            PlasmaComponents3.CheckBox {
                Layout.fillWidth: true
                visible: root.statusKnown
                enabled: root.controlsEnabled
                text: "强制修改（网页端有人或有租约也照改，只管下一次应用）"
                checked: root.forceMode
                onToggled: {
                    root.forceMode = checked
                    checked = Qt.binding(() => root.forceMode)
                }
            }
            PlasmaComponents3.Label {
                Layout.fillWidth: true
                visible: root.customMode && !root.selValid
                wrapMode: Text.Wrap
                color: Kirigami.Theme.negativeTextColor
                text: "宽和高都要是偶数，范围 320–4080"
            }
            RowLayout {
                Layout.fillWidth: true
                PlasmaComponents3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    visible: text !== ""
                    color: root.resultIsError ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.textColor
                    text: root.resultText
                }
                Item {
                    Layout.fillWidth: root.resultText === ""
                }
                PlasmaComponents3.Button {
                    icon.name: "dialog-ok-apply"
                    text: "应用"
                    enabled: root.controlsEnabled && root.selValid && root.selChanged
                        && (!root.webBusy || root.forceMode)
                    onClicked: root.applySelection()
                }
            }
        }
    }

    component SideSpinBox: PlasmaComponents3.SpinBox {
        // Plasma's SpinBox warns about an implicitWidth binding loop on first
        // layout whatever we set here; it is upstream and harmless.
        Layout.fillWidth: true
        Layout.preferredWidth: Kirigami.Units.gridUnit * 5
        // Inline components can't see root; keep in sync with minSide/maxSide.
        from: 320
        to: 4080
        stepSize: 2
        editable: true
        textFromValue: (v, locale) => String(v)
        valueFromText: (text, locale) => {
            const n = parseInt(text, 10)
            return isNaN(n) ? value : n
        }
        validator: IntValidator {
            bottom: 0
            top: 4080
        }
    }
}
