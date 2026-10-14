# 独立 Selkies 网页桌面

本目录是全新的远程桌面部署，不依赖 `wechat-selkies`、TigerVNC、noVNC 或主机 KDE 会话。

## 运行时边界

- 容器名：`rakko-remote-desktop`
- 官方镜像：`ghcr.io/selkies-project/selkies-egl-desktop:26.04`
- 本机监听：`127.0.0.1:8090`
- 容器端口：`8080`
- 公网入口：`https://desktop.rakko.cn`
- 传输：Selkies WebSocket，经 Cloudflare Tunnel 和 Phainon Gateway
- GPU：主机 `/dev/dri` 的 Intel VAAPI
- 桌面：容器自己的 Plasma/Wayland 会话

公网入口的鉴权由 Phainon/Priestess 负责。Selkies Basic Auth 和容器 HTTPS 都关闭，避免出现第二套密码或内层自签名证书。

## 部署

在服务器上进入本目录，先准备非敏感的 GPU 组 ID：

```bash
export RENDER_GID="$(getent group render | cut -d: -f3)"
export VIDEO_GID="$(getent group video | cut -d: -f3)"
```

密码由 1Password CLI 注入，不把它写入仓库：

```bash
export REMOTE_DESKTOP_PASSWD="$(op read 'op://<vault>/<item>/password')"
docker compose config >/tmp/rakko-remote-desktop.compose.yaml
docker compose up -d
```

`/tmp/rakko-remote-desktop.compose.yaml` 只用于本机检查，使用完应删除；不要把展开后的配置提交到 Git。

## 验证

```bash
docker compose ps
docker compose logs --tail=200 remote-desktop
ss -ltnp | rg ':8090\\b'
```

日志必须看到 Selkies 使用 Intel VAAPI 的 H.264 编码器。若出现 x264/CPU 回退，不能把部署标记为完成。

4K/60 是硬验收条件；先确认日志和运行时指标，再做公网鉴权、WebSocket、音频和剪贴板测试。测试只使用文本和指标，不使用截图或视觉判断。

## Cloudflare Tunnel

现有 Tunnel 增加一条 ingress，放在最终 `http_status:404` 之前：

```yaml
- hostname: desktop.rakko.cn
  service: http://127.0.0.1:8090
```

不要给 8090 增加公网防火墙规则，也不要把它改成 `0.0.0.0`。
