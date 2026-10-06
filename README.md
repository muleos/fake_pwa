# 假装PWA

HarmonyOS 网页套壳应用：一个可以"假装"成任意网站 App 的壳子。**壳能力与 [soutu_ohos](https://github.com/muleos/soutu_ohos) 1:1 同构**，差异仅在：首页不内置任何网址，由用户手动填写。

- 包名：`com.hmos.pwa`
- 应用名：假装PWA
- 当前版本：v1.0.4 (100005)
- 兼容版本：compatibleSdkVersion `6.0.0(20)`

## 功能

### 首页（默认为空）
- 首页地址默认**空**，用户在设置面板手动填写目标网址并保存；
- **首页为空时显示纯空白底色：浅色模式白色、深色模式黑色（跟随系统深浅色实时切换）**；
- 空白首页仅右下角一个半透明齿轮按钮进入设置；
- 保存网址后，整壳即"假装"成该网站 App（WebView 全屏承载，伪装 PWA）。

### 设置（soutu_ohos 壳同款全量能力）
- **首页地址**：输入网址 → 保存（自动补 `https://` 前缀，立即生效）；
- **UA 切换**：手机(安卓) / 电脑 / 自定义；
- **横屏禁止刷新**、**全屏模式**、**显示状态栏**、**显示底部白条**；
- **强制深色模式**：开关打开时网页深色跟随系统深浅色；
- **下拉灵敏度**、**底栏抬高**（0-30vp）；
- **清除缓存**（7 天未使用启动时也自动清）、**返回首页**、下拉刷新；
- **更换图标（纯静态，无 AGC）**：
  - **预置图标样式**：5 款静态样式（收藏蓝/曜石黑/翡翠绿/珊瑚橙/星紫，白色网络地球统一前景），应用内点选即切并记忆（选样式自动清除旧的自定义上传图）；
  - **桌面图标更换**：桌面图标安装时固化，用 `python tools/set_app_icon.py --variant black` 或 `--image 网站logo.png`（可加 `--build`）替换包内图标资源重打包——安装新 hap 后桌面图标即为目标样式；
  - **上传自定义图标**：图库选图 → 拷贝沙箱 → 持久化 → 应用内展示（WeiboPura 封面更换同构）。

### 壳能力（soutu_ohos 1:1）
- 沉浸式全屏 + 状态栏/小白条避让，系统栏背景取页面采样色（DOM 探针经 console 上报）；
- 长按图片/视频自绘上下文菜单：保存图片（安全控件直存系统图库）/ 复制图片 / 分享图片 / 复制链接 / 其他应用打开；
- 统一取图通道：资源嗅探缓存 → 默认参数 GET → 多策略 Referer 矩阵 → 页面内 fetch（分片桥）→ WebView 网络栈下载；
- 文件下载确认弹窗（进度条，SaveButton 授权保存）；图片类下载自动改走图库保存（魔数嗅探兜底）；
- `<input type=file>` 拉起系统图库选图；外部 scheme（深链）交系统分发；
- Cookie 登录：粘贴 Cookie 串写入首页域 CookieStore（UI 暂隐藏，逻辑保留，域名跟随首页 URL）；
- 深浅色双源判定（配置色模式优先，mediaquery 兜底）；网页双指强制缩放；MixedMode 兼容。

### 应用分身
`AppScope/app.json5` 中配置：

```json5
"multiAppMode": {
  "multiAppModeType": "appClone",
  "maxCount": 10
}
```

> 注：官方文档（OpenHarmony app.json5 配置）标注 appClone 模式 `maxCount` 范围 1~5（multiInstance 模式才到 10）；DevEco 本地 hvigor schema 校验上限为 5，本地编译需临时改 5。若目标系统按 5 截断，属平台限制，此处配置值仍保留 10。

## 换图标的前置条件（重要）

换图标功能与 aira-browser 同构，底层为 **AppGallery Kit 图标管理服务**（`@kit.AppGalleryKit` 的 `appInfoManager`，起始版本 5.0.3(15)）：

1. 仅**真机**生效（不支持模拟器）；
2. 需先在 **AppGallery Connect → 图标管理** 创建图标（iconId + 图标）并**通过审核**；
3. 审核通过后，应用内 `queryDynamicIcons()` 才能查到，`selectDynamicIcon()` 切换后由系统更新桌面图标。

典型用法：给每个常用网站在 AGC 上传对应图标（iconId 即网站名），每个应用分身选择不同网页与图标，即可"假装"出多个网站 App。

## 工程结构

```
AppScope/app.json5                        包名/版本/分身(multiAppMode)
entry/src/main/ets/
  entryability/EntryAbility.ets           入口：内核预热+首页预连接、深浅色事件
  model/StorageService.ets                首页地址/UA/开关/Cookie 等持久化（soutu 同构）
  services/ImageResourceSniffer.ets       页面图片资源嗅探缓存（soutu 同构）
  services/WebImageSaver.ets              取图/图库直存/剪贴板/分享（soutu 同构）
  services/DynamicAppIconService.ets      AGC 动态图标查询/切换/恢复（aira 同构）
  services/CustomIconService.ets          自定义图标上传：图库选图→沙箱持久化→file:// 展示（WeiboPura 同构）
  component/DownloadConfirmDialog.ets     下载确认弹窗（soutu 同构）
  delegate/IWebDownloadFile.ets           下载委托抽象（soutu 同构）
  delegate/WebDownloadFileImpl.ets        下载委托实现（soutu 同构）
  utiles/WebChromeScript.ets              页面注入脚本：取色探针+取图桥（soutu 同构）
  utiles/EmitterUtil.ets                  事件工具
  pages/Index.ets                         空白首页(白/黑跟随深浅色)+网页层+设置+换图标
```

## 版本历史

- **v1.0.4 (100005)**：移除 AGC 动态图标（服务/UI/依赖整体删除）；修复静态样式切换不生效（旧的自定义上传图标优先级遮挡预览 → 选预置样式时自动清除）；面板精简为「预置样式 + 上传自定义」。
- **v1.0.3 (100004)**：预置 5 款静态图标样式选择器（应用内点选即切+记忆）；新增 `tools/set_app_icon.py` 换图标重打包工具（预置样式或任意图片 → 直接产出 hap，侧载安装后桌面图标真实更换）；全尺寸样式图入库 `assets/icons/`。
- **v1.0.2 (100003)**：更换图标支持上传自定义图标（图库选图→沙箱持久化→应用内展示，WeiboPura 封面更换同构）+ AGC 动态图标双通道；应用图标重绘：收藏 app 同款华为蓝渐变背景 + 白色网络地球（分层资源 1024px，前景/背景/startIcon 同步更新）。
- **v1.0.1 (100002)**：壳能力对齐 soutu_ohos 1:1（下载/取图/长按菜单/沉浸取色/UA/全屏开关等全量移植）；首页改为纯空白底（浅色白/深色黑），移除桌面壁纸读取；设置面板全量重做。
- **v1.0.0 (100001)**：首版。分层壳 + 壁纸尽力读取 + 简化设置面板 + AGC 换图标。
