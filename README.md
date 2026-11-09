# WES·MACLEAN

本地运行的 macOS 状态栏工具。\
原生 SwiftUI 界面，MIT 开源。

- CPU、GPU、内存、硬盘与网速。
- SMC 温度、风扇数量和转速。
- 点击状态栏，查看应用内存。
- 核对应用及关联文件后卸载。
- 清理缓存、日志和文件缓存。

无需账号，没有遥测或在线更新。\
源码没有第三方包依赖。

## 构建与运行

需要 macOS 和 Xcode 16 或更新版。\
系统部署目标为 macOS 13。\
已在 M1、M4 Air 实测。\
Intel 机型尚未实测。

```sh
git clone https://github.com/wesley138cn/WES-MACLEAN.git
cd WES-MACLEAN
./scripts/build.sh
open 'dist/WES·MACLEAN.app'
```

脚本使用当前 Xcode 工具链。\
也可通过 `DEVELOPER_DIR` 指定。\
默认构建采用 ad-hoc 本地签名。\
系统指标、卸载和垃圾清理可用。\
文件缓存回收需另配助手签名。

### 清理助手

助手首次启用需管理员授权。\
之后清理无需重复输入密码。\
设置页可检查、修复或移除助手。\
升级签名或修复时可能再次授权。

开发者可使用自己的 Apple 证书：

```sh
security find-identity -v -p codesigning
export MACLEAN_SIGNING_IDENTITY='YOUR_40_CHARACTER_CERTIFICATE_SHA1'
./scripts/build.sh
./scripts/check-helper.sh
```

填写钥匙串中证书的 SHA-1。\
应用和助手须使用同一证书。\
生成配置会被 Git 忽略。\
构建脚本不会导出私钥。

此仓库提供完整源码。\
当前未提供公证下载包。\
向他人分发需另做签名与公证。\
详见[构建与签名](docs/BUILDING.md)。

## 使用

关闭主窗口后，状态栏继续运行。\
点击状态栏，打开内存排行。\
面板打开时每三秒刷新。\
右键状态栏可退出应用。

设置页可选择显示项目。\
按住 ⌘ 可拖动状态栏位置。\
展开宽度仍受系统菜单栏限制。\
刘海和其他图标可能占用空间。

### 温度与风扇

SEN 是一个 SMC 传感器读数。\
各机型使用不同传感器键。\
它并非 CPU 或整机平均温度。\
无可用数据时显示破折号。

M1 Air 使用 `TCHP`。\
M4 Air 优先使用 `Tp09`。\
两款机型都没有风扇。\
界面显示“无风扇”或 `0 FANS`。\
有风扇机型读取实际 RPM。\
零转速与读取失败分别显示。

更多说明见[传感器](docs/SENSORS.md)。

### 卸载与垃圾清理

扫描 `/Applications` 和 `~/Applications`。\
关联文件按包标识精确匹配。\
用户数据默认不勾选。\
运行中的应用会被跳过。

确认后移入 Finder 废纸篓。\
应用不会自行清空废纸篓。\
清空后才会释放磁盘空间。\
恢复时可在废纸篓选择“放回”。

系统服务、驱动和共享容器，\
需按软件自身卸载流程处理。

### 内存

排行使用驻留内存 RSS。\
辅助进程归属对应应用。\
共享页可能重复计入。

清理按钮调用系统 `purge`。\
它回收文件缓存。\
应用仍在使用的内存由系统管理。\
回收可能短暂增加磁盘读取。\
内存压力正常时，无需频繁清理。\
也可选择正常退出应用。

## 测试

```sh
python3 scripts/configure.py
xcrun swift test
```

测试覆盖清理路径、内存归属、\
传感器解析、并发和 XPC 拒绝。\
测试不会执行管理员缓存回收。

签名集成检查需 Apple 证书。\
它用临时监听器验证 XPC 身份。\
不会安装或移除系统助手。

## 隐私与安全

操作记录仅保存在本机：

`~/Library/Application Support/Lime/operations.jsonl`

设置保存在：

`~/Library/Preferences/local.wesp.Lime.plist`

日志包含操作时间和文件路径。\
提交问题前请隐去个人路径。

详见[安全设计](SECURITY.md)。\
功能调整见[更新记录](CHANGELOG.md)。\
贡献说明见[CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

[MIT](LICENSE)，允许商用和修改。\
保留原版权与许可声明。
