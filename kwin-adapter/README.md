# Selkies KWin virtual-output adapter

这是与 KWin 6.3.6 精确匹配的最小插件。它只在当前进程内为 `VirtualBackend` 的
已有输出准备一个动态 `OutputMode`，不创建新的桌面 compositor，也不处理视频、音频、
输入、剪贴板或远程命令。

## 本地协议

插件在 `$XDG_RUNTIME_DIR/selkies-kwin-adapter.sock` 监听，也可以由
`SELKIES_KWIN_ADAPTER_SOCKET` 指定 runtime 目录下的备用路径。协议是单行 JSON：

```json
{"op":"status"}
{"op":"prepare","output_index":0,"width":1920,"height":1080,"refresh_mhz":60000}
```

只有与 KWin 相同 UID 的 Unix peer 被接受。`prepare` 只准备 mode；Selkies 随后通过
KDE `output-management-v2` 选择该 mode，并等待 `applied` 及新的 PipeWire DMA-BUF 帧。

## 构建约束

该目录必须作为精确 KWin 6.3.6 构建树中的子目录加入，并链接同一棵树的 `kwin` target：

```text
cmake -DSELKIES_KWIN_ADAPTER_SOURCE_DIR=/path/to/kwin-adapter-poc ...
```

不把插件安装到系统 KWin 目录；预检使用独立 KWin 安装前缀和独立 Wayland socket。
