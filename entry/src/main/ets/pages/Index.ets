import { webview } from '@kit.ArkWeb';
import { promptAction, window, mediaquery } from '@kit.ArkUI';
import { common, Want, OpenLinkOptions, ConfigurationConstant } from '@kit.AbilityKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { appInfoManager } from '@kit.AppGalleryKit';
import { getTargetUrl, saveTargetUrl } from '../model/StorageService';
import { EmitterUtil } from '../utiles/EmitterUtil'
import { loadSystemWallpaper } from '../services/WallpaperService';
import { DynamicAppIconService } from '../services/DynamicAppIconService';

// 默认安卓手机 UA：按 Android 手机环境渲染（设置面板后续可扩展切换）
const ANDROID_UA: string = 'Mozilla/5.0 (Linux; Android 14; M2012K11AC Build/UKQ1.230917.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';

/**
 * 假装PWA 主页（单页分层壳）：
 * - 首页层：桌面壁纸铺底（读取失败回退空白：浅色白/深色黑），默认内容为空，仅右下角设置入口；
 * - 网页层：目标网页 WebView（保存于设置），支持文件选择、外部 scheme 分发、前进后退；
 * - 设置面板：目标网页输入/保存/打开 + 更换图标入口；
 * - 换图标面板：查询 AGC 图标管理服务的动态图标并切换（系统更新桌面图标）。
 */
@Entry
@Component
struct Index {
  // ===== 页面分层状态 =====
  @State webOpen: boolean = false;
  @State showSetting: boolean = false;
  @State showIcons: boolean = false;
  // ===== 首页壁纸/深浅色 =====
  @State wallpaperPm: image.PixelMap | null = null;
  @State sysDark: boolean = false;
  // ===== 目标网页 =====
  @State targetUrlInput: string = '';
  @State savedTargetUrl: string = '';
  // ===== 网页层 =====
  @State webProgress: number = 0;
  @State webLoading: boolean = false;
  private pendingUrl: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  // ===== 换图标面板 =====
  @State iconLoading: boolean = false;
  @State iconOptions: appInfoManager.DynamicIconInfo[] = [];
  @State iconStatus: string = '';
  @State currentIconId: string = '';
  private iconService: DynamicAppIconService = new DynamicAppIconService();
  // ===== 安全区/深浅色监听 =====
  @State safeTopVp: number = 0;
  @State safeBottomVp: number = 0;
  private darkMQL: mediaquery.MediaQueryListener | null = null;

  async aboutToAppear() {
    // 系统深浅色切换：重算空白底色（浅色白/深色黑）
    EmitterUtil.on<number>('pwa_color_mode_changed', (event) => {
      this.detectDark();
    });
    // 强制深浅色双源判定：配置色模式优先，mediaquery 兜底（soutu 壳同款）
    try {
      this.darkMQL = mediaquery.matchMediaSync('(dark-mode: dark)');
      this.darkMQL.on('change', (res: mediaquery.MediaQueryResult) => {
        this.detectDark();
      });
    } catch (err) {
    }
    this.detectDark();
    // 已保存的目标网页回填
    this.savedTargetUrl = await getTargetUrl();
    this.targetUrlInput = this.savedTargetUrl;
    // 桌面壁纸：能读则铺底；读不到保持 null（空白回退在 build 中按深浅色处理）
    loadSystemWallpaper().then((pm: image.PixelMap | null) => {
      if (pm) {
        this.wallpaperPm = pm;
      }
    }).catch(() => {
    });
    // 沉浸式：全屏布局 + 安全区采集（稍等窗口就绪）
    setTimeout(() => {
      this.computeSafeAreas();
    }, 50);
  }

  aboutToDisappear(): void {
    EmitterUtil.unSubscribe('pwa_color_mode_changed');
    try {
      if (this.darkMQL) {
        this.darkMQL.off('change');
        this.darkMQL = null;
      }
    } catch (err) {
    }
  }

  // ==================== 深浅色 / 安全区 ====================

  private detectDark(): void {
    let cfg: number = 0; // 0=未知 1=深色 2=浅色
    try {
      const cm = (getContext(this) as common.UIAbilityContext).config?.colorMode;
      if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        cfg = 1;
      } else if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
        cfg = 2;
      }
    } catch (err) {
    }
    let queryMatches: boolean = false;
    try {
      if (this.darkMQL) {
        queryMatches = this.darkMQL.matches as boolean;
      }
    } catch (err) {
    }
    this.sysDark = cfg === 1 ? true : (cfg === 2 ? false : queryMatches);
  }

  private computeSafeAreas(): void {
    window.getLastWindow(getContext(this) as common.UIAbilityContext, (err, win) => {
      if (err || !win) {
        return;
      }
      try {
        win.setWindowLayoutFullScreen(true);
        const sys = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
        const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.safeTopVp = px2vp(sys.topRect.top);
        this.safeBottomVp = px2vp(nav.bottomRect.height);
      } catch (e) {
      }
    });
  }

  // ==================== 目标网页 ====================

  private normalizeUrl(raw: string): string {
    const s = raw.trim();
    if (s === '') {
      return '';
    }
    const lower = s.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return s;
    }
    return 'https://' + s;
  }

  private openTarget(): void {
    const url = this.normalizeUrl(this.targetUrlInput);
    if (url === '') {
      promptAction.showToast({ message: '请先输入目标网页' });
      return;
    }
    this.savedTargetUrl = url;
    saveTargetUrl(url);
    if (this.webOpen) {
      // 网页层已开：直接换址
      try {
        this.controller.loadUrl(url);
      } catch (err) {
      }
    } else {
      this.pendingUrl = url;
      this.webOpen = true;
    }
    this.showSetting = false;
  }

  private saveTarget(): void {
    const url = this.normalizeUrl(this.targetUrlInput);
    if (url === '') {
      promptAction.showToast({ message: '请先输入目标网页' });
      return;
    }
    this.savedTargetUrl = url;
    this.targetUrlInput = url;
    saveTargetUrl(url);
    promptAction.showToast({ message: '已保存目标网页' });
  }

  // ==================== 换图标（AGC 图标管理服务） ====================

  private openIconPanel(): void {
    this.showIcons = true;
    this.refreshIcons();
  }

  private async refreshIcons(): Promise<void> {
    this.iconLoading = true;
    this.iconStatus = '';
    const res = await this.iconService.queryIcons();
    this.iconOptions = res.icons;
    let cur: string = '';
    for (const o of res.icons) {
      if (o.enabled) {
        cur = o.iconId;
        break;
      }
    }
    this.currentIconId = cur;
    if (!res.ok) {
      this.iconStatus = res.message;
    } else if (res.icons.length === 0) {
      this.iconStatus = '暂无可选图标：需要先在 AppGallery Connect「图标管理」创建图标并通过审核，审核通过后会自动出现在这里。';
    }
    this.iconLoading = false;
  }

  private async selectIcon(opt: appInfoManager.DynamicIconInfo): Promise<void> {
    if (opt.enabled || this.iconLoading) {
      return;
    }
    this.iconLoading = true;
    const res = await this.iconService.selectIcon(opt.iconId);
    this.iconLoading = false;
    if (res.ok) {
      this.currentIconId = opt.iconId;
      promptAction.showToast({ message: '图标已切换：' + opt.iconId });
    } else {
      promptAction.showToast({ message: res.message });
    }
    await this.refreshIcons();
  }

  private async restoreDefaultIcon(): Promise<void> {
    if (this.iconLoading) {
      return;
    }
    this.iconLoading = true;
    const res = await this.iconService.restoreDefault();
    this.iconLoading = false;
    if (res.ok) {
      this.currentIconId = '';
      promptAction.showToast({ message: '已恢复默认图标' });
    } else {
      promptAction.showToast({ message: res.message });
    }
    await this.refreshIcons();
  }

  // ==================== 外部分发 ====================

  async openExternalApp(url: string): Promise<void> {
    const uiContext = getContext(this) as common.UIAbilityContext;
    try {
      // 优先走系统链接分发（Deep Linking / App Linking），可拉起注册了该协议的应用
      let linkOptions: OpenLinkOptions = { appLinkingOnly: false };
      await uiContext.openLink(url, linkOptions);
      return;
    } catch (e) {
    }
    try {
      // 兜底：显式构造 Want 拉起
      let want: Want = {
        action: 'ohos.want.action.viewData',
        uri: url
      };
      await uiContext.startAbility(want);
      return;
    } catch (err) {
    }
    promptAction.showToast({ message: '未找到可打开该链接的应用' });
  }

  // ==================== 返回键 ====================

  onBackPress(): boolean {
    // 图标面板 → 设置面板 → 网页层（先退网页历史，无历史关网页层回首页）→ 系统默认退出
    if (this.showIcons) {
      this.showIcons = false;
      return true;
    }
    if (this.showSetting) {
      this.showSetting = false;
      return true;
    }
    if (this.webOpen) {
      try {
        if (this.controller.accessStep(-1)) {
          this.controller.backward();
          return true;
        }
      } catch (err) {
      }
      this.webOpen = false;
      return true;
    }
    return false;
  }

  // ==================== UI ====================

  build() {
    Stack() {
      // ===== 首页层：桌面壁纸 / 空白 =====
      Stack() {
        if (this.wallpaperPm) {
          // 能读到桌面壁纸：全屏铺底
          Image(this.wallpaperPm)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
        } else {
          // 读取失败回退空白：浅色白 / 深色黑（用户规格）
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.sysDark ? Color.Black : Color.White)
        }
        // 首页默认为空：仅右下角一个半透明设置入口
        Column() {
          Blank()
          Row() {
            Button() {
              Image($r('app.media.settings'))
                .width(22)
                .height(22)
                .fillColor($r('app.color.dialog_text'))
            }
              .type(ButtonType.Circle)
              .width(46)
              .height(46)
              .backgroundColor($r('app.color.home_gear_bg'))
              .margin({ right: 20, bottom: 20 })
              .onClick(() => {
                this.showSetting = true;
              })
          }
          .width('100%')
          .padding({ bottom: this.safeBottomVp })
          .justifyContent(FlexAlign.End)
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')

      // ===== 网页层 =====
      if (this.webOpen) {
        this.webLayer()
      }

      // ===== 设置面板 =====
      if (this.showSetting) {
        this.settingsPanel()
      }

      // ===== 换图标面板 =====
      if (this.showIcons) {
        this.iconPanel()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ==================== 网页层 ====================

  @Builder
  webLayer() {
    Column() {
      // 顶部细进度条（加载中显示）
      Row()
        .height(2)
        .width(this.webLoading ? `${this.webProgress}%` : '0%')
        .backgroundColor($r('app.color.accent_blue'))
      Stack({ alignContent: Alignment.Center }) {
        Web({ src: this.pendingUrl, controller: this.controller })
          .onControllerAttached(() => {
            try {
              this.controller.setNetworkAvailable(true);
              this.controller.setCustomUserAgent(ANDROID_UA);
            } catch (err) {
            }
          })
          .onProgressChange((event) => {
            if (event) {
              this.webProgress = event.newProgress;
              this.webLoading = event.newProgress < 100;
            }
          })
          .onPageBegin(() => {
            this.webLoading = true;
          })
          .onPageEnd(() => {
            this.webLoading = false;
          })
          .onLoadIntercept((event) => {
            if (!event || !event.data) {
              return false;
            }
            const url: string = event.data.getRequestUrl();
            const lower = url.toLowerCase();
            // 网页与内联协议正常加载
            if (lower.startsWith('http://') || lower.startsWith('https://') ||
              lower.startsWith('about:') || lower.startsWith('data:') || lower.startsWith('blob:')) {
              return false;
            }
            // 其它 scheme（taptap://、mailto: 等）交系统分发
            this.openExternalApp(url);
            return true;
          })
          .onShowFileSelector((event) => {
            // <input type=file> 拉起系统图库选图（soutu 壳同款：handleFileList 只收 URI 字符串数组）
            try {
              const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
              photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
              photoSelectOptions.maxSelectNumber = 1;
              const photoPicker = new photoAccessHelper.PhotoViewPicker();
              photoPicker.select(photoSelectOptions).then((photoSelectResult) => {
                if (photoSelectResult.photoUris && photoSelectResult.photoUris.length > 0) {
                  const fileList: string[] = [];
                  for (const photoUri of photoSelectResult.photoUris) {
                    fileList.push(photoUri);
                  }
                  event.result.handleFileList(fileList);
                } else {
                  event.result.handleFileList([]);
                }
              }).catch(() => {
                try {
                  event.result.handleFileList([]);
                } catch (e) {
                }
              });
            } catch (err) {
              try {
                event.result.handleFileList([]);
              } catch (e) {
              }
            }
            return true;
          })
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .imageAccess(true)
          .onlineImageAccess(true)
          .fileAccess(true)
          .geolocationAccess(true)
          .zoomAccess(true)
          .forceEnableZoom(true)
          .mixedMode(MixedMode.Compatible)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.White)
        if (this.webLoading) {
          LoadingProgress()
            .width(46)
            .height(46)
            .color($r('app.color.accent_blue'))
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .padding({ top: this.safeTopVp })
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.panel_bg'))
  }

  // ==================== 设置面板 ====================

  @Builder
  settingsPanel() {
    Column() {
      Column() {
        Text('设置')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.dialog_text'))
        Row().height(14)
        Text('目标网页')
          .fontSize(13)
          .fontColor($r('app.color.dialog_text_secondary'))
        Row().height(8)
        TextInput({ placeholder: '输入网址，如 m.bilibili.com', text: this.targetUrlInput })
          .height(40)
          .fontSize(14)
          .fontColor($r('app.color.dialog_text'))
          .placeholderColor($r('app.color.dialog_text_secondary'))
          .backgroundColor($r('app.color.dialog_divider'))
          .onChange((value: string) => {
            this.targetUrlInput = value;
          })
        Row().height(12)
        Row() {
          Button('打开网页')
            .layoutWeight(1)
            .height(38)
            .type(ButtonType.Capsule)
            .fontSize(14)
            .backgroundColor($r('app.color.accent_blue'))
            .fontColor(Color.White)
            .onClick(() => {
              this.openTarget();
            })
          Row().width(10)
          Button('保存')
            .layoutWeight(1)
            .height(38)
            .type(ButtonType.Capsule)
            .fontSize(14)
            .backgroundColor($r('app.color.dialog_divider'))
            .fontColor($r('app.color.dialog_text'))
            .onClick(() => {
              this.saveTarget();
            })
        }
        .width('100%')
        Row().height(8)
        Divider().color($r('app.color.dialog_divider')).strokeWidth(1)
        // 更换图标入口（AGC 图标管理服务，aira 同构）
        Row() {
          Text('更换图标')
            .fontSize(14)
            .fontColor($r('app.color.dialog_text'))
            .layoutWeight(1)
          Text(this.currentIconId === '' ? '默认' : this.currentIconId)
            .fontSize(12)
            .fontColor($r('app.color.dialog_text_secondary'))
          Text('›')
            .fontSize(18)
            .fontColor($r('app.color.dialog_text_secondary'))
            .margin({ left: 6 })
        }
        .width('100%')
        .height(46)
        .onClick(() => {
          this.openIconPanel();
        })
        Divider().color($r('app.color.dialog_divider')).strokeWidth(1)
        Row().height(6)
        Text('图标由华为应用市场图标管理服务提供：需在 AppGallery Connect「图标管理」创建图标并通过审核后，方可在此查询与切换；切换后桌面图标由系统更新。')
          .fontSize(11)
          .fontColor($r('app.color.dialog_text_secondary'))
        Row().height(4)
        Text('首页壁纸读取属系统受限能力，读取失败时按深浅色显示空白（浅色白/深色黑）。')
          .fontSize(11)
          .fontColor($r('app.color.dialog_text_secondary'))
      }
      .width('100%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor($r('app.color.dialog_bg'))
      // 拦截点击冒泡，避免点面板内容触发遮罩关闭
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 12, right: 12, bottom: this.safeBottomVp + 12 })
    .onClick(() => {
      this.showSetting = false;
    })
  }

  // ==================== 换图标面板 ====================

  @Builder
  iconPanel() {
    Column() {
      Column() {
        Row() {
          Text('更换图标')
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.dialog_text'))
            .layoutWeight(1)
          Button('完成')
            .height(30)
            .type(ButtonType.Capsule)
            .fontSize(13)
            .backgroundColor($r('app.color.dialog_divider'))
            .fontColor($r('app.color.dialog_text'))
            .onClick(() => {
              this.showIcons = false;
            })
        }
        .width('100%')
        Row().height(12)
        if (this.iconLoading) {
          Column() {
            LoadingProgress()
              .width(36)
              .height(36)
              .color($r('app.color.accent_blue'))
            Row().height(8)
            Text('正在读取应用图标...')
              .fontSize(13)
              .fontColor($r('app.color.dialog_text_secondary'))
          }
          .width('100%')
          .padding({ top: 20, bottom: 20 })
        } else if (this.iconOptions.length === 0) {
          Column() {
            Text(this.iconStatus)
              .fontSize(13)
              .fontColor($r('app.color.dialog_text_secondary'))
            Row().height(12)
            Button('重新查询')
              .height(32)
              .type(ButtonType.Capsule)
              .fontSize(13)
              .backgroundColor($r('app.color.dialog_divider'))
              .fontColor($r('app.color.dialog_text'))
              .onClick(() => {
                this.refreshIcons();
              })
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
        } else {
          List() {
            ForEach(this.iconOptions, (opt: appInfoManager.DynamicIconInfo, index: number) => {
              ListItem() {
                Row() {
                  Image(opt.iconUrl)
                    .width(44)
                    .height(44)
                    .borderRadius(10)
                    .alt($r('app.media.startIcon'))
                  Text(opt.iconId)
                    .fontSize(14)
                    .fontColor($r('app.color.dialog_text'))
                    .margin({ left: 12 })
                    .layoutWeight(1)
                  if (opt.enabled) {
                    Text('当前')
                      .fontSize(12)
                      .fontColor($r('app.color.accent_blue'))
                  }
                }
                .width('100%')
                .height(60)
                .onClick(() => {
                  this.selectIcon(opt);
                })
              }
            }, (opt: appInfoManager.DynamicIconInfo, index: number) => opt.iconId + '_' + index)
          }
          .width('100%')
          .height(240)
          .divider({ strokeWidth: 1, color: $r('app.color.dialog_divider'), startMargin: 0, endMargin: 0 })
          .scrollBar(BarState.Off)
          Row().height(6)
          Divider().color($r('app.color.dialog_divider')).strokeWidth(1)
          Row() {
            Text('恢复默认图标')
              .fontSize(14)
              .fontColor($r('app.color.dialog_text'))
              .layoutWeight(1)
            Button('恢复')
              .height(30)
              .type(ButtonType.Capsule)
              .fontSize(13)
              .backgroundColor($r('app.color.dialog_divider'))
              .fontColor($r('app.color.dialog_text'))
              .onClick(() => {
                this.restoreDefaultIcon();
              })
          }
          .width('100%')
          .height(50)
        }
        Row().height(8)
        Text(this.iconOptions.length === 0 && !this.iconLoading
          ? '图标由华为应用市场图标管理服务提供（仅真机生效）。'
          : '切换后桌面图标会由系统更新；如果系统正在使用自定义主题图标，切换可能会失败。')
          .fontSize(11)
          .fontColor($r('app.color.dialog_text_secondary'))
      }
      .width('100%')
      .padding(16)
      .borderRadius(16)
      .backgroundColor($r('app.color.dialog_bg'))
      .onClick(() => {
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#66000000')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .padding({ left: 12, right: 12, bottom: this.safeBottomVp + 12 })
    .onClick(() => {
      this.showIcons = false;
    })
  }
}
