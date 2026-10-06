import { webview } from '@kit.ArkWeb';
import { promptAction, window, display, mediaquery } from '@kit.ArkUI';
import { common, Want, OpenLinkOptions, ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  saveHomeUrl,
  getHomeUrl,
  saveUserAgent,
  getUserAgent,
  saveLSRefresh,
  getLSRefresh,
  saveIshidebar,
  getIshidebar,
  getIshidestatus,
  saveIshidestatus,
  getUserAgentType,
  saveUserAgentType,
  getIsfull,
  saveIsfull,
  getSlidenum,
  saveSlidenum,
  saveWebDarkMode,
  getWebDarkMode,
  saveWebCookie,
  getWebCookie,
  saveBottomLift,
  getBottomLift
} from '../model/StorageService';
import { DownloadConfirmDialog } from '../component/DownloadConfirmDialog'
import { IAbstractDownloadHandler } from '../delegate/IWebDownloadFile'
import { WebDownloadFileHelper } from '../delegate/WebDownloadFileImpl'
import { EmitterUtil } from '../utiles/EmitterUtil'
import { WEB_CHROME_SCRIPT } from '../utiles/WebChromeScript'
import { WebImageSaver } from '../services/WebImageSaver'
import { ImageResourceSniffer } from '../services/ImageResourceSniffer'
import { DynamicAppIconService } from '../services/DynamicAppIconService';
import { http } from '@kit.NetworkKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { appInfoManager } from '@kit.AppGalleryKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

let context_index = getContext(this) as common.UIAbilityContext;

const TAG = 'web-savePic';
// UA 常量：默认伪装安卓客户端（Chrome/Android 手机 UA），电脑端为桌面 Chrome
const ANDROID_UA: string = 'Mozilla/5.0 (Linux; Android 14; M2012K11AC Build/UKQ1.230917.001) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
const PC_UA: string = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
const context = getContext(this) as common.UIAbilityContext;

@Entry
@Component
struct Index {
  private isRefreshing: boolean = false;
  @State controller: webview.WebviewController = new webview.WebviewController();
  @State webDownloadFile: IAbstractDownloadHandler = new WebDownloadFileHelper()
  downloadWebLoading: CustomDialogController = new CustomDialogController({
    //Web页面加载的弹窗控制器
    builder: DownloadConfirmDialog(),
    customStyle: true,
    alignment: DialogAlignment.Bottom,
    autoCancel: false,
    isModal: false
  })

  private shouldClearCache: boolean = false;
  // 假装PWA：首页默认为空（用户在设置面板手动填写目标网址）。
  // 未填写时显示纯空白首页：浅色白 / 深色黑（跟随系统深浅色模式），仅右下角设置入口；
  // 填写后整壳同构 soutu_ohos：Web 承载目标网页（伪装 PWA）。
  @State saved_home_url: string = '';
  @State home_url: string = '';
  // Cookie 登录（v1.7.4 同构）：设置面板粘贴网页版 Cookie 写入 WebView CookieStore
  @State savedCookie: string = '';
  @State cookieInput: string = '';
  private cookiePending: boolean = false;
  // 启动性能：Web 首帧 src 用普通属性（非 @State），偏好设置晚于首帧就绪时不再触发二次加载
  private firstSrc: string = '';
  private webReady: boolean = false;
  @State refreshing: boolean = false
  @State list: number[] = Array(20).fill(Date.now())
  @State is_home: boolean = false;
  @State showDialog: boolean = false;
  @State c_pg_ua: string = '';
  @State c_ua_temp: string = '';
  @State ua_type: string = 'Mobile';
  @State userAgent: string = '';
  @State ua_device: string = '';
  @State showTopRow: boolean = false;
  @State showRefreshRow: boolean = true;
  @State showButtonRow: boolean = true;
  @State refreshTimerId: number | null = null;
  @State showSetting: boolean = false;
  @State showIcons: boolean = false;
  @State isLandscape: boolean = false;
  @State isLSRefresh: string = 'flase'; //是否横屏不能刷新
  @State isdrag: number = 1
  @State isHidebar: string = 'false';
  @State isHidestatus: string = 'false';
  @State isFull: string = 'true';
  @State slide_num: number = 0.3;
  @State webDark: string = 'auto'; // 'auto'=开关关闭(始终浅色), 'dark'=开关打开(深色跟随系统)
  @State sysDark: boolean = false; // 系统当前是否深色（mediaquery 实时同步）
  // 系统深浅色监听：开关打开时，网页深色随系统切换（系统深色→深色显示，浅色→浅色显示）
  private darkMQL: mediaquery.MediaQueryListener | null = null;
  // 页面内取图桥（__STQ_IMGB64__）分片缓存：reqId -> 已收分片（按 seq 追加）
  private imgChunks: Map<string, string[]> = new Map();
  // reqId -> 期望分片数（-1 表示页面侧取图失败）
  private imgTotal: Map<string, number> = new Map();
  // 沉浸式：状态栏高度留白(px->vp)，供下拉顶栏避开状态栏
  @State safeTopVp: number = 0;
  // 底栏抬高设置值(0-30vp)：设置面板可调，抬高网页视口底部，避免网页底栏被小白条手势区压住
  @State bottomLiftSetting: number = 28;
  // 底栏抬高区填充色：与底部采样色一致（同状态栏避让的取色逻辑）
  @State bottomFillColor: string = '';
  // 主内容区实际高度(vp)：避让/抬高区分段取色的锚点
  @State contentHeightVp: number = 0;
  // 全屏避让填充色：状态栏区域与页面顶部采样色一致，避免色差断层
  @State topFillColor: string = '';
  // 状态栏原生高度(vp)：全屏布局下二三级页面的避让量来源
  private statusVp: number = 0;
  // 当前窗口是否为全屏布局（setWindowLayoutFullScreen(true) 后窗口延伸到状态栏下）
  private fullLayout: boolean = false;
  // 当前主文档 URL：用于区分首页一级界面（保持沉浸不避让）与二三级页面（避让状态栏）
  private pageUrl: string = '';
  private lastTopBg: string = '';
  private lastBottomBg: string = '';
  // 空白首页：小白条手势区高度(vp)，设置入口按钮抬高避让
  @State homeNavVp: number = 0;
  // 长按上下文菜单（图片/视频）
  @State ctxVisible: boolean = false;
  @State ctxX: number = 0;
  @State ctxY: number = 0;
  @State ctxItems: string[] = [];
  // 防回环：同一 URL 的图库保存进行中标记
  private saveInFlightUrl: string = '';
  // 保存到图库确认弹窗：内嵌系统安全控件 SaveButton，点击后临时授权直写图库
  @State saveBtnVisible: boolean = false;
  private pendingSaveBytes: ArrayBuffer = new ArrayBuffer(0);
  // 无缓存字节时直取来源 URL（nas_nav 1:1：点保存时才单次 GET）
  private pendingSaveUrl: string = '';
  private ctxUrl: string = '';
  // ===== 换图标面板（AGC 图标管理服务，fake_pwa 特性保留） =====
  @State iconLoading: boolean = false;
  @State iconOptions: appInfoManager.DynamicIconInfo[] = [];
  @State iconStatus: string = '';
  @State currentIconId: string = '';
  private iconService: DynamicAppIconService = new DynamicAppIconService();

  async setSystemFull(is_full: string, is_hidestatus: string, is_hidebar: string) {
    let windowClass = await window.getLastWindow(context_index)
    if (is_full == 'true') {
      if (is_hidestatus == 'true') {
        if (is_hidebar == 'true') {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);

        } else {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      } else {
        if (is_hidebar == 'true') {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);

        } else {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      }
    } else {
      if (is_hidestatus == 'true') {
        if (is_hidebar == 'true') {
          // 小白条开启：必须全屏布局。非全屏布局下系统会把导航栏画成默认黑，
          // navigationBarColor 被忽略；全屏布局下窗口延伸到小白条下方，采样色可正常上屏
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);
        } else {
          await windowClass.setWindowLayoutFullScreen(false);
          this.fullLayout = false;
          await windowClass.setSpecificSystemBarEnabled('status', true, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      } else {
        if (is_hidebar == 'true') {
          await windowClass.setWindowLayoutFullScreen(true);
          this.fullLayout = true;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);

          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', true, true);

        } else {
          await windowClass.setWindowLayoutFullScreen(false);
          this.fullLayout = false;
          await windowClass.setSpecificSystemBarEnabled('status', false, true);
          await windowClass.setSpecificSystemBarEnabled('navigationIndicator', false, true);

        }
      }
    }
    // 系统栏样式：非全屏时状态栏/小白条背景取页面采样色；全屏同理
    await this.updateSystemBarStyle();
    // navigationIndicator 异步生效，会把导航栏颜色重置回系统默认黑：延时重设
    setTimeout(() => {
      this.updateSystemBarStyle(this.lastTopBg, this.lastBottomBg);
    }, 350);
    // 状态栏原生高度：全屏布局下二三级页面避让用；非全屏布局窗口自动避让，不加 padding
    try {
      const area = windowClass.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.statusVp = px2vp(area.topRect.top);
    } catch (err) {
      this.statusVp = 0;
    }
    this.pageUrl = this.saved_home_url || '';
    this.updateSafeTop();
  }

  /** 一级界面判定：主文档 URL 与设置的主页一致（去 query/hash、归一尾斜杠）视为首页，保持沉浸不避让 */
  private isTopLevelUrl(url: string): boolean {
    try {
      const norm = (u: string): string => {
        let s = (u || '').split('#')[0].split('?')[0];
        if (s.length > 1 && s.endsWith('/')) {
          s = s.substring(0, s.length - 1);
        }
        return s;
      };
      const home = norm(this.saved_home_url);
      if (home === '') {
        return false;
      }
      return norm(url) === home;
    } catch (err) {
      return false;
    }
  }

  /** 顶部避让量：全屏布局下窗口延伸到状态栏之下，必须整体下移，
   *  否则网页顶部（站点自绘标题栏）会被系统状态栏压住 */
  private updateSafeTop(): void {
    const target: number = (this.fullLayout && this.statusVp > 0) ? this.statusVp : 0;
    if (target !== this.safeTopVp) {
      this.safeTopVp = target;
    }
  }

  /** 渐变分段锚点：顶部避让区结束比例（0-1） */
  private topStop(): number {
    if (this.contentHeightVp <= 0 || this.safeTopVp <= 0) {
      return 0;
    }
    return Math.min(1, this.safeTopVp / this.contentHeightVp);
  }

  /** 渐变分段锚点：底部抬高区开始比例（0-1） */
  private bottomStop(): number {
    if (this.contentHeightVp <= 0 || this.bottomLiftSetting <= 0) {
      return 1;
    }
    return Math.max(0, 1 - this.bottomLiftSetting / this.contentHeightVp);
  }

  async aboutToAppear() {
    // 系统深浅色切换：强制重设系统栏（深色：顶栏#1B1C21/底栏#161920）
    EmitterUtil.on<number>('stq_color_mode_changed', (event) => {
      // 系统深浅色切换：用最近采样色强制重设系统栏
      this.applyImmersiveTheme(this.lastTopBg, this.lastBottomBg, true);
    });
    // 强制深色跟随系统：开关打开时，网页深色随系统深浅色变化
    try {
      this.darkMQL = mediaquery.matchMediaSync('(dark-mode: dark)');
      this.darkMQL.on('change', (res: mediaquery.MediaQueryResult) => {
        this.onSystemDarkChanged(this.detectSystemDark(res.matches as boolean));
      });
    } catch (err) {
    }
    // 网页缓存管理：记录最后使用时间；超过 7 天未使用，启动时自动清除缓存
    preferences.getPreferences(context_index, 'stq_web_cache').then((pref) => {
      const now: number = systemDateTime.getTime();
      pref.get('cache_updated_at', 0).then((v) => {
        const last: number = typeof v === 'number' ? v : 0;
        if (last > 0 && now - last > 7 * 24 * 60 * 60 * 1000) {
          this.shouldClearCache = true;
        }
        pref.put('cache_updated_at', now).then(() => {
          pref.flush();
        });
      });
    }).catch(() => {
    });
    EmitterUtil.on<number>('affffa', (event) => {
      if (event?.data === 1) {
        this.downloadWebLoading.open()
      } else {
        this.downloadWebLoading.close()
      }
    })
    // 启动性能：偏好读取并行化（原先 12 次串行 await，每次都阻塞一帧）
    const slidePromise = getSlidenum();
    const prefs: string[] = await Promise.all([
      getLSRefresh(), getUserAgent(), getHomeUrl(), getIshidebar(), getIshidestatus(),
      getUserAgentType(), getIsfull(), getWebDarkMode(), getWebCookie(), getBottomLift()
    ]);
    const slideN: number = await slidePromise;
    this.isLSRefresh = prefs[0] || this.isLSRefresh;
    this.c_pg_ua = prefs[1] || this.c_pg_ua;
    this.c_ua_temp = prefs[1] || this.c_pg_ua;
    // 首页 URL 默认为空：用户手动填写（填写后整壳即"假装"成该网站 App）
    this.saved_home_url = prefs[2] || '';
    this.home_url = this.saved_home_url;
    this.isHidebar = (prefs[3] || this.isHidebar);
    this.isHidestatus = (prefs[4] || this.isHidestatus);
    this.ua_type = (prefs[5] || this.ua_type);
    this.isFull = (prefs[6] || this.isFull);
    this.slide_num = slideN || this.slide_num;
    this.webDark = (prefs[7] || this.webDark);
    // Cookie 登录：内核已在 EntryAbility 预热，首帧加载前写入可随首个请求生效；
    // 写入失败（内核未就绪）时置 pending，由 onControllerAttached 补写并刷新一次
    this.savedCookie = (prefs[8] || '').trim();
    // 底栏抬高设置值(0-30vp)：默认 28（与 TapTapWeb 壳一致），超界纠正
    const savedLift: number = Number(prefs[9] || '');
    this.bottomLiftSetting = isNaN(savedLift)
      ? 28
      : Math.max(0, Math.min(30, Math.round(savedLift)));
    if (this.savedCookie !== '' && !this.applyWebCookie()) {
      this.cookiePending = true;
    }
    // 启动性能：首帧 src 尚未被消费时直接用真实首页，避免"先默认页再跳转"的二次加载
    if (!this.webReady && this.saved_home_url) {
      this.firstSrc = this.saved_home_url;
    }
    // 初始系统深浅色同步（在偏好读取后执行）：空白首页底色/网页深色均跟随系统
    try {
      if (this.darkMQL) {
        this.onSystemDarkChanged(this.detectSystemDark(this.darkMQL.matches as boolean));
      }
    } catch (err) {
    }
    setTimeout(() => {
      this.backToHome();
      this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
      this.computeHomeNavArea();
    }, 50);
  }

  aboutToDisappear(): void {
    EmitterUtil.off<number>('affffa', (event) => {

    })
    EmitterUtil.unSubscribe('stq_color_mode_changed');
    try {
      if (this.darkMQL) {
        this.darkMQL.off('change');
        this.darkMQL = null;
      }
    } catch (err) {
    }
  }

  /** 空白首页：小白条手势区高度（设置入口按钮抬高避让） */
  private computeHomeNavArea(): void {
    window.getLastWindow(context_index, (err, win) => {
      if (err || !win) {
        return;
      }
      try {
        const nav = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
        this.homeNavVp = px2vp(nav.bottomRect.height);
      } catch (e) {
        this.homeNavVp = 0;
      }
    });
  }

  /**
   * 系统深色判定（双源校验）：优先取 UIAbility 配置色模式（应用跟随系统时与系统一致），
   * 拿不到时回退 mediaquery 结果。v1.1.5 真机出现 matches 与系统相反的现象，改以配置为准，
   * 并打 hilog 记录两源取值，便于异常时定位。
   */
  private detectSystemDark(queryMatches: boolean): boolean {
    let cfg: number = 0; // 0=未知 1=深色 2=浅色
    try {
      const cm = context_index.config?.colorMode;
      if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK) {
        cfg = 1;
      } else if (cm === ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT) {
        cfg = 2;
      }
    } catch (err) {
    }
    const dark: boolean = cfg === 1 ? true : (cfg === 2 ? false : queryMatches);
    hilog.info(0x0000, TAG, 'sysDark detect: cfg=%{public}d, query=%{public}s, result=%{public}s',
      cfg, queryMatches ? 'dark' : 'light', dark ? 'dark' : 'light');
    return dark;
  }

  /** 系统深浅色变化：网页深色开关打开时随系统切换；空白首页底色始终跟随系统（浅色白/深色黑） */
  private onSystemDarkChanged(sysDark: boolean): void {
    const changed: boolean = sysDark !== this.sysDark;
    this.sysDark = sysDark;
    if (!changed || !this.get_isWebDark()) {
      return;
    }
    this.lastTopBg = '';
    this.lastBottomBg = '';
    this.applyImmersiveTheme('', '', true);
    hilog.info(0x0000, TAG, 'web dark follows system: %{public}s', sysDark ? 'dark' : 'light');
    if (this.webReady && this.saved_home_url !== '') {
      this.refreshWeb();
    }
  }

  /** 网页最终深色状态：强制深色开关打开 且 系统当前为深色（系统浅色时保持浅色显示） */
  private isWebDarkNow(): boolean {
    return this.get_isWebDark() && this.sysDark;
  }

  @Builder
  content() {
    Stack() {
      Column() {
        Row() {
          TextInput({
            placeholder: '请输入有效的URL地址',
            text: this.saved_home_url
          })
            .height(32)
            .width("80%")
            .onChange((value) => {
              this.home_url = value;
            })

          Button('保存')
            .height(32)
            .width("15%")
            .type(ButtonType.Capsule)
            .backgroundColor(Color.Blue)
            .onClick(() => {
              if (this.home_url) {
                this.saveHomeAndOpen(this.home_url);
              }
              this.showTopRow = false
              this.showRefreshRow = true
              this.showButtonRow = true
              this.onRefreshing();
            })
        }
        .visibility(this.showTopRow ? Visibility.Visible : Visibility.None)
        .height(40)
        .width("100%")
        .alignItems(VerticalAlign.Center)
        .justifyContent(FlexAlign.SpaceAround)

        Row() {
          LoadingProgress()
            .height(32)
          Text('正在刷新...')
              .fontColor($r('app.color.dialog_text'))
            .fontSize(16)
            .margin({ left: 20 })
        }
        .visibility(this.showRefreshRow ? Visibility.Visible : Visibility.None)
        .alignItems(VerticalAlign.Center)

        Row() {
          Button({ type: ButtonType.Circle }) {
            Image($r('app.media.settings'))
              .width(20)
              .height(20)
          }
          .onClick(() => {
            this.showSetting = true
          })
          .height(32)
          .width(32)

          Button("清除缓存")
            .onClick(() => {
              this.controller.removeCache(true);
            })
            .height(32)
            .width("25%")
          Button("返回首页")
            .onClick(() => {
              this.is_home = true
              this.backToHome()
              setTimeout(() => {
                this.is_home = false
              }, 1000);
            })
            .height(32)
            .width("60%")
        }
        .visibility(this.showButtonRow ? Visibility.Visible : Visibility.None)
        .padding({ top: 5, bottom: 5 })
        .height(40)
        .width("100%")
        .alignItems(VerticalAlign.Center)
        .backgroundColor($r('app.color.panel_bg'))
        .justifyContent(FlexAlign.SpaceAround)
      }
      .padding({ top: this.safeTopVp })
    }

  }

  build() {
    Stack() {
      if (this.saved_home_url === '') {
        // ===== 空白首页：首页地址未填写，显示纯空白（浅色白/深色黑跟随系统）+ 右下角设置入口 =====
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(this.sysDark ? '#000000' : '#FFFFFF')
          Column() {
            Blank()
            Row() {
              Button() {
                Image($r('app.media.settings'))
                  .width(22)
                  .height(22)
                  .fillColor(this.sysDark ? '#E8EAED' : '#1A1A1A')
              }
                .type(ButtonType.Circle)
                .width(46)
                .height(46)
                .backgroundColor(this.sysDark ? '#CC26282E' : '#CCFFFFFF')
                .margin({ right: 20, bottom: 20 })
                .onClick(() => {
                  this.showSetting = true;
                })
            }
            .width('100%')
            .padding({ bottom: this.homeNavVp })
            .justifyContent(FlexAlign.End)
          }
          .width('100%')
          .height('100%')
        }
        .width('100%')
        .height('100%')
      } else {
        // ===== 网页层：目标网页（soutu_ohos 壳 1:1 同构） =====
        Refresh({ refreshing: $$this.refreshing, builder: this.content() }) {
          NavDestination() {
            Column() {
              Web({ src: this.firstSrc, controller: this.controller })
                .onControllerAttached(() => {
                  this.controller.setNetworkAvailable(true);
                  this.webDownloadFile.setDownloadDelegate(this.controller);
                  // 图片类下载拦截改走图库保存（站点内建保存按钮触发下载时不再落文件管理）
                  this.webDownloadFile.onImageDownload = (u: string): void => {
                    this.saveWebImage(u);
                  };
                  // 下载完成魔数嗅探兜底：内容实为图片 → 原始字节交图库保存，绝不进文件选择器
                  this.webDownloadFile.onImageDataDownload = (data: ArrayBuffer, name: string): void => {
                    this.openSaveConfirm(data, name);
                  };
                  if (this.shouldClearCache) {
                    this.shouldClearCache = false;
                    try {
                      this.controller.removeCache(true);
                    } catch (err) {
                    }
                  }
                  console.info("onControllerAttached");
                  this.webReady = true;
                  try {
                    this.change_userAgent()
                  } catch (error) {
                    console.error(`ErrorCode: ${(error as BusinessError).code},  Message: ${(error as BusinessError).message}`);
                  }
                  // Cookie 登录兜底：aboutToAppear 时内核未就绪导致写入失败的，这里补写；
                  // 补写成功后整页加载真实首页，保证登录态随请求生效
                  if (this.cookiePending) {
                    this.cookiePending = false;
                    if (this.applyWebCookie()) {
                      setTimeout(() => {
                        try {
                          if (this.saved_home_url !== '') {
                            this.controller.loadUrl(this.saved_home_url);
                          }
                        } catch (err) {
                        }
                      }, 300);
                    }
                  }
                })
                .domStorageAccess(true)
                .javaScriptAccess(true)
                .geolocationAccess(true)
                .imageAccess(true)
                .onlineImageAccess(true)
                .fileAccess(true)
                .mediaPlayGestureAccess(true)
                .mixedMode(MixedMode.Compatible)
                .darkMode(this.isWebDarkNow() ? WebDarkMode.On : WebDarkMode.Off)
                .forceDarkAccess(this.isWebDarkNow())
                // aira 同构：强制允许网页内双指缩放（无视站点 user-scalable=no），
                // 图片可直接在网页上捏合放大查看
                .zoomAccess(true)
                .forceEnableZoom(true)
                .backgroundColor($r('app.color.panel_bg'))
                .javaScriptOnDocumentStart([{ script: WEB_CHROME_SCRIPT, scriptRules: ['*'] }])
                .onConsole((event) => {
                  // 沉浸式取色桥：页面探针经 console 上报主题背景色
                  if (event && event.message) {
                    const msg: string = event.message.getMessage() || '';
                    if (msg.indexOf('__STQ_IMGB64__') === 0) {
                      return this.handleImgBridge(msg);
                    }
                    if (msg.indexOf('__STQ_CHROME__') === 0) {
                      try {
                        const payload = JSON.parse(msg.substring('__STQ_CHROME__'.length)) as Record<string, string>;
                        this.applyImmersiveTheme(payload.bg || '', payload.bbg || '');
                      } catch (err) {
                      }
                    }
                  }
                  return false;
                })
                .onContextMenuShow((event) => {
                  return this.handleWebContextMenu(event);
                })
                .onLoadIntercept((event) => {
                  // 拦截非网页协议的跳转，交给系统/外部应用打开（如应用深链 scheme）
                  if (event && event.data) {
                    const url: string = event.data.getRequestUrl() || '';
                    const scheme: string = url.split(':')[0]?.toLowerCase() || '';
                    const webSchemes: string[] = ['http', 'https', 'file', 'about', 'data', 'blob', 'javascript'];
                    if (scheme !== '' && !webSchemes.includes(scheme)) {
                      this.openExternalApp(url);
                      return true; // 拦截，不让 WebView 自己加载
                    }
                    // 主文档导航：按页面层级刷新状态栏避让（首页沉浸，二三级避让）
                    if ((scheme === 'http' || scheme === 'https') && event.data.isMainFrame()) {
                      this.pageUrl = url;
                      this.updateSafeTop();
                    }
                  }
                  return false;
                })
                .onShowFileSelector((event) => {
                  // 网页 <input type=file> 拉起系统图库选图。
                  // ArkWeb 默认不处理网页文件选择，必须接管并回传文件句柄
                  try {
                    const photoSelectOptions = new photoAccessHelper.PhotoSelectOptions();
                    photoSelectOptions.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
                    photoSelectOptions.maxSelectNumber = 1;
                    const photoPicker = new photoAccessHelper.PhotoViewPicker();
                    photoPicker.select(photoSelectOptions).then((photoSelectResult) => {
                      if (photoSelectResult.photoUris && photoSelectResult.photoUris.length > 0) {
                        // 本地 SDK 兼容：FileSelectorResult.handleFileList 只接受 Array<string>（文件 URI 列表），
                        // 原写法传 {uri,fileName,fd} 对象数组会被 ArkTS 静态检查拒绝（untyped-obj-literals）
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
                      } catch (err) {
                      }
                    });
                  } catch (err) {
                    try {
                      event.result.handleFileList([]);
                    } catch (err2) {
                    }
                    return false;
                  }
                  return true;
                })

            }
            .width("100%")
            .height("100%")
            // 顶部：全屏布局下整体下移，网页顶部（站点标题栏）不被系统状态栏遮挡；
            // 底部：抬高 0-30vp（设置面板可调），网页底栏不被小白条手势区压住
            .padding({ top: this.safeTopVp, bottom: this.bottomLiftSetting })
            // 避让/抬高区分段取色：上段用页面顶部采样色、下段用页面底部采样色（与系统栏同逻辑），
            // 无采样时回退 panel_bg（浅色资源自适配深浅色）
            .linearGradient({
              angle: 180,
              colors: [
                [this.topFillColor === '' ? $r('app.color.panel_bg') : this.topFillColor, 0],
                [this.topFillColor === '' ? $r('app.color.panel_bg') : this.topFillColor, this.topStop()],
                [this.bottomFillColor === '' ? $r('app.color.panel_bg') : this.bottomFillColor, this.bottomStop()],
                [this.bottomFillColor === '' ? $r('app.color.panel_bg') : this.bottomFillColor, 1]
              ]
            })
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              const h: number = Number(newArea.height) || 0;
              if (h > 0 && Math.abs(h - this.contentHeightVp) > 0.5) {
                this.contentHeightVp = h;
              }
            })

          }

        }
        .pullDownRatio(this.slide_num * this.isdrag)
        .backgroundColor($r('app.color.panel_bg'))
        .onRefreshing(() => this.onRefreshing())
        .onSizeChange(() => {
          window.getLastWindow(this.getUIContext().getHostContext(), (err, win) => {
            let cutOutInfo = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM_GESTURE)
            if (window.Orientation.AUTO_ROTATION) {
              let rotation: number =
                display.getDefaultDisplaySync().orientation // Get current screen orientation enum value
              if (this.isLSRefresh == 'true') {
                if (rotation == 0) {
                  this.isLandscape = false;
                  this.isdrag = 1;
                } else if (rotation == 1) {
                  this.isLandscape = true;
                  this.isdrag = 0;
                } else if (rotation == 2) {
                  this.isLandscape = false;
                  this.isdrag = 1;
                } else {
                  this.isLandscape = true;
                  this.isdrag = 0;
                }
              }
            }
          })
        })
        .width('100%')
        .height('100%')
      }

      //弹窗
      Column() {
        Column() {
          Row() {
            Text("首页")
              .fontColor($r('app.color.dialog_text'))
              .width("12%")
              .height(32)
            TextInput({
              placeholder: '请输入有效的URL地址',
              text: this.saved_home_url
            })
              .height(32)
              .width("70%")
              .padding({
                top: '4vp',
                right: '12vp',
                bottom: '4vp',
                left: '12vp'

              })
              .onChange((value) => {
                this.home_url = value;
              })
            Text()
              .width(7)

            Button('保存')
              .height(32)
              .width("18%")
              .type(ButtonType.Capsule)
              .onClick(() => {
                if (this.home_url) {
                  this.saveHomeAndOpen(this.home_url);
                } else {
                  promptAction.showToast({ message: '请输入有效的URL地址' });
                }
              })
          }
          // 假装PWA：首页地址行常显（目标网址手动填写，默认为空）
          .visibility(Visibility.Visible)

          Row()
            .height(10)

          // UA 选择行常显（默认手机=安卓客户端 UA）—— soutu 壳同构
          // 三个选项等分剩余宽度并单行省略——原写法各 Text 不限宽，中文标签会把设置面板边框撑破
          Row() {
            Text("UA")
              .fontColor($r('app.color.dialog_text'))
              .fontSize(14)
              .width('12%')

            Row() {
              Radio({ value: 'Mobile', group: 'ua_type_group' })
                .checked(this.ua_type === 'Mobile')
                .onChange((isChecked) => {
                  if (isChecked) {
                    this.ua_type = 'Mobile';
                    saveUserAgentType('Mobile');
                    this.change_userAgent();
                    this.refreshWeb();
                  }
                })
                .height(20)
                .width(20)
              Text("手机(安卓)")
                .fontColor($r('app.color.dialog_text'))
                .fontSize(12)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  if (this.ua_type == 'custom') {
                    this.c_ua_temp = this.getuseragentbytype('Mobile');
                  }
                })
            }
            .layoutWeight(1)

            Row() {
              Radio({ value: 'PC', group: 'ua_type_group' })
                .checked(this.ua_type === 'PC')
                .onChange((isChecked) => {
                  if (isChecked) {
                    this.ua_type = 'PC';
                    saveUserAgentType('PC');
                    this.change_userAgent();
                    this.refreshWeb();
                  }
                })
                .height(20)
                .width(20)
              Text("电脑")
                .fontColor($r('app.color.dialog_text'))
                .fontSize(12)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  if (this.ua_type == 'custom') {
                    this.c_ua_temp = this.getuseragentbytype('PC');
                  }
                })
            }
            .layoutWeight(1)

            Row() {
              Radio({ value: 'custom', group: 'ua_type_group' })
                .checked(this.ua_type === 'custom')
                .onChange((isChecked) => {
                  if (isChecked) {
                    this.ua_type = 'custom';
                    saveUserAgentType('custom');
                    this.change_userAgent();
                    this.refreshWeb();
                  }
                })
                .height(20)
                .width(20)
              Text("自定义")
                .fontColor($r('app.color.dialog_text'))
                .fontSize(12)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
                .onClick(() => {
                  if (this.ua_type == 'custom') {
                    this.c_ua_temp = this.getuseragentbytype('custom');
                  }
                })
            }
            .layoutWeight(1)
          }
          .width('100%')

          // UA 输入框：仅自定义 UA 时显示（手机/电脑内置 UA 无需输入）
          if (this.ua_type === 'custom') {
            Row() {
              TextArea({
                text: this.c_ua_temp,
                placeholder: '输入自定义UA'
              })
              .placeholderFont({ size: 13 })
              .fontSize(14)
              .height(90)
              .textAlign(TextAlign.Start)
              .layoutWeight(1)
              .onChange((value) => {
                this.c_ua_temp = value;
              })

            Text()
              .width(7)

            Button('保存')
              .height(32)
              .width(72)
              .type(ButtonType.Capsule)
              .onClick(() => {
                if (this.c_ua_temp) {
                  this.c_pg_ua = this.c_ua_temp;
                  saveUserAgent(this.c_pg_ua);
                  this.change_userAgent()
                  this.refreshWeb();
                }
              })
          }
          .alignItems(VerticalAlign.Top)
          .width('100%')
          }
          Row()
            .height(10)

          Row() {
            Text("横屏禁止刷新")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isLSRefresh()
            })
              .width('15%')
              .height(25)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isLSRefresh = 'true';
                  saveLSRefresh(this.isLSRefresh);
                  if (this.isLandscape == true) {
                    this.isdrag = 1;
                  } else {
                    this.isdrag = 0;
                  }
                } else {
                  this.isLSRefresh = 'false';
                  saveLSRefresh(this.isLSRefresh);
                  this.isdrag = 1;
                }

              })

          }
          .justifyContent(FlexAlign.SpaceAround)
          .width('100%')

          Row() {
            Text("全屏模式")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isfull()
            })
              .width('15%')
              .height(25)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isFull = 'true';
                  saveIsfull(this.isFull);
                } else {
                  this.isFull = 'false';
                  saveIsfull(this.isFull);
                }
                this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
              })
          }

          Row() {
            Text("显示状态栏")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isHideStatus()
            })
              .width('15%')
              .height(25)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isHidestatus = 'true';
                  saveIshidestatus(this.isHidestatus);
                } else {
                  this.isHidestatus = 'false';
                  saveIshidestatus(this.isHidestatus);
                }
                this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
              })
          }

          Row() {
            Text("显示底部白条")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isHideBar()
            })
              .width('15%')
              .height(25)
              .onChange((isOn: boolean) => {
                if (isOn) {
                  this.isHidebar = 'true';
                  saveIshidebar(this.isHidebar);
                } else {
                  this.isHidebar = 'false';
                  saveIshidebar(this.isHidebar);
                }
                this.setSystemFull(this.isFull, this.isHidestatus, this.isHidebar);
              })
          }


          Row() {
            Text("强制深色模式")
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text()
              .width('50%')
            Toggle({
              type: ToggleType.Switch,
              isOn: this.get_isWebDark()
            })
              .width('15%')
              .height(25)
              .onChange((isOn: boolean) => {
                this.webDark = isOn ? 'dark' : 'auto';
                saveWebDarkMode(this.webDark);
                this.lastTopBg = '';
                this.lastBottomBg = '';
                this.applyImmersiveTheme('', '', true);
                this.refreshWeb();
                // 开关打开瞬间即按当前系统深浅色生效，无需等下一次系统切换
                this.onSystemDarkChanged(this.sysDark);
              })
          }

          Row() {
            Text("下拉灵敏度")
              .fontColor($r('app.color.dialog_text'))
              .width("30%")
              .height(32)
            Text()
              .width('10%')
            Slider({
              value: this.slide_num * 100,
              step: 10,
              min: 10,
              style: SliderStyle.InSet
            })
              .width('50%')
              .height(25)
              .showSteps(true)
              .onChange((value: number, mode: SliderChangeMode) => {
                this.slide_num = value / 100;
                saveSlidenum(value / 100);
              })
            Text((this.slide_num * 100).toFixed(0))
              .width('10%')
              .height(32)
              .textAlign(TextAlign.End)

          }

          Row() {
            Text("底栏抬高")
              .fontColor($r('app.color.dialog_text'))
              .width("30%")
              .height(32)
            Text()
              .width('10%')
            Slider({
              value: this.bottomLiftSetting,
              step: 1,
              min: 0,
              max: 30,
              style: SliderStyle.InSet
            })
              .width('50%')
              .height(25)
              .showSteps(true)
              .onChange((value: number, mode: SliderChangeMode) => {
                const v: number = Math.max(0, Math.min(30, Math.round(value)));
                if (v === this.bottomLiftSetting && mode !== SliderChangeMode.End) {
                  return;
                }
                this.bottomLiftSetting = v;
                saveBottomLift(String(v));
              })
            Text(this.bottomLiftSetting.toFixed(0))
              .width('10%')
              .height(32)
              .textAlign(TextAlign.End)

          }

          // 更换图标入口（AGC 图标管理服务，fake_pwa 特性保留）
          Divider().color($r('app.color.dialog_divider')).strokeWidth(1)
          Row() {
            Text('更换图标')
              .fontSize(14)
              .fontColor($r('app.color.dialog_text'))
              .width("35%")
              .height(32)
            Text(this.currentIconId === '' ? '默认' : this.currentIconId)
              .fontSize(12)
              .fontColor($r('app.color.dialog_text_secondary'))
              .layoutWeight(1)
              .textAlign(TextAlign.End)
            Text('›')
              .fontSize(18)
              .fontColor($r('app.color.dialog_text_secondary'))
              .margin({ left: 6 })
          }
          .width('100%')
          .onClick(() => {
            this.openIconPanel();
          })

          Row()
            .height(30)

          Row() {
            Text("Version:1.0.1")
              .fontColor($r('app.color.dialog_text_secondary'))
              .width('100%')
              .textAlign(TextAlign.Center)
          }


          Row()
            .height(20)

          // Cookie 登录逻辑保留（fetchCurrentCookie/applyWebCookie），UI 按需求隐藏；
          // 已保存的 Cookie 仍在启动/页面加载时自动写入（域名跟随首页 URL）
          Row() {
            Text('登录 Cookie')
              .fontColor($r('app.color.dialog_text'))
              .width('30%')
              .height(40)
            TextInput({
              placeholder: '粘贴网页版 Cookie',
              text: this.cookieInput
            })
              .height(40)
              .layoutWeight(1)
              .fontSize(13)
              .onChange((value: string) => {
                this.cookieInput = value;
              })

            Button('应用')
              .type(ButtonType.Capsule)
              .backgroundColor($r('app.color.dialog_text_secondary'))
              .margin({ left: 8 })
              .height(40)
              .width(72)
              .onClick(() => {
                const raw = (this.cookieInput || '').trim();
                if (raw === '') {
                  promptAction.showToast({ message: '请先粘贴 Cookie 串' });
                  return;
                }
                this.savedCookie = raw;
                saveWebCookie(raw);
                const ok = this.applyWebCookie();
                this.showSetting = false;
                if (ok) {
                  promptAction.showToast({ message: 'Cookie 已写入，刷新登录态' });
                  this.refreshWeb();
                } else {
                  this.cookiePending = true;
                  promptAction.showToast({ message: '内核未就绪，页面加载时自动重试' });
                }
              })
          }
          .width('100%')
          .visibility(Visibility.None)

          // 获取当前账号 Cookie：应用内已登录时一键取出 WebView 现有登录 Cookie，
          // 填入上方输入框供查看/复制，再点"应用"固化（与手动粘贴输入并存）
          Row() {
            Text('应用内已登录时，可一键取出当前登录 Cookie')
              .fontSize(11)
              .fontColor($r('app.color.dialog_text_secondary'))
              .layoutWeight(1)
            Button('获取当前 Cookie')
              .type(ButtonType.Capsule)
              .backgroundColor($r('app.color.dialog_text_secondary'))
              .height(32)
              .fontSize(12)
              .onClick(() => {
                const got = this.fetchCurrentCookie();
                if (got === '') {
                  promptAction.showToast({ message: '未取到 Cookie，请先在应用内登录' });
                  return;
                }
                this.cookieInput = got;
                promptAction.showToast({ message: '已填入当前 Cookie，点"应用"生效' });
              })
          }
          .width('100%')
          .margin({ top: 8 })
          .visibility(Visibility.None)

          Row()
            .height(16)

          Row() {
            Button('返回')
              .type(ButtonType.Capsule)
              .onClick(() => {
                this.showSetting = false
                this.c_ua_temp = this.c_pg_ua;
              })
              .height(40)
              .width(100)
          }

        }
        .width("90%")
        .padding(20)
        .backgroundColor($r('app.color.panel_bg'))
        .borderRadius($r('sys.float.corner_radius_level8'))
      }
      .width("100%")
      .height("100%")
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Color.Transparent)
      .visibility(this.showSetting ? Visibility.Visible : Visibility.None)

      // 长按菜单点击遮罩（点击空白关闭）
      if (this.ctxVisible) {
        Column()
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.ctxVisible = false;
          })
      }

      // 长按图片/视频 自绘上下文菜单（参考 aira-browser 自绘 overlay 方案）
      if (this.ctxVisible) {
        Column() {
          ForEach(this.ctxItems, (item: string) => {
            // 「保存图片」行：仍渲染系统安全控件 SaveButton（临时授权直存图库的前提），
            // 但样式定制为与普通菜单行一致——无图标、背景与菜单同色（安全控件禁止
            // 透明/遮挡，用同色不透明背景实现"纯文字"观感）、字体颜色同其他行
            if (item === '保存图片') {
              SaveButton({
                text: SaveDescription.SAVE_IMAGE,
                buttonType: ButtonType.Capsule
              })
                .width(170)
                .height(44)
                .fontSize(15)
                .fontColor($r('app.color.dialog_text'))
                .backgroundColor($r('app.color.ctx_menu_bg'))
                .onClick((event: ClickEvent, result: SaveButtonOnClickResult): void => {
                  if (result === SaveButtonOnClickResult.SUCCESS) {
                    this.ctxVisible = false;
                    this.doDirectSave(this.ctxUrl);
                  } else if (result === SaveButtonOnClickResult.TEMPORARY_AUTHORIZATION_FAILED) {
                    promptAction.showToast({ message: '临时授权失败，请重试' });
                  }
                })
            } else {
              Text(item)
                .fontSize(15)
                .fontColor($r('app.color.dialog_text'))
                .height(44)
                .width(170)
                .textAlign(TextAlign.Center)
                .onClick(() => {
                  this.onCtxItem(item);
                })
            }
            if (item !== this.ctxItems[this.ctxItems.length - 1]) {
              Divider()
                .color($r('app.color.ctx_divider'))
                .width(150)
            }
          }, (item: string) => item)
        }
        .backgroundColor($r('app.color.ctx_menu_bg'))
        .borderRadius(12)
        .shadow({ radius: 16, color: '#26000000' })
        .position({ x: this.ctxX, y: this.ctxY })
      }

      // 保存到图库最小确认框（仅长按菜单透明安全控件授权失败/下载兜底时出现）：
      // 内嵌系统安全控件 SaveButton，点击即按 nas_nav 流程直存图库，无预览图
      if (this.saveBtnVisible) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#66000000')
            .onClick((): void => {
              this.closeSaveDialog();
            })
          Column({ space: 14 }) {
            Text('保存图片到系统图库')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.dialog_text'))
            SaveButton({ icon: SaveIconStyle.FULL_FILLED, text: SaveDescription.SAVE_IMAGE, buttonType: ButtonType.Capsule })
              .onClick((event: ClickEvent, result: SaveButtonOnClickResult): void => {
                if (result === SaveButtonOnClickResult.SUCCESS) {
                  this.doDirectSave(this.pendingSaveUrl, this.pendingSaveBytes);
                } else if (result === SaveButtonOnClickResult.TEMPORARY_AUTHORIZATION_FAILED) {
                  promptAction.showToast({ message: '临时授权失败，请重试' });
                }
              })
            Text('取消')
              .fontSize(14)
              .fontColor($r('app.color.dialog_text'))
              .opacity(0.7)
              .padding({ left: 24, right: 24, top: 4, bottom: 4 })
              .onClick((): void => {
                this.closeSaveDialog();
              })
          }
          .alignItems(HorizontalAlign.Center)
          .padding(24)
          .borderRadius(16)
          .backgroundColor($r('app.color.panel_bg'))
        }
        .width('100%')
        .height('100%')
      }

      // ===== 换图标面板（AGC 图标管理服务） =====
      if (this.showIcons) {
        this.iconPanel()
      }

    }
    .height('100%')
    .width('100%')

  }

  onBackPress() {
    // 图标面板 → 设置面板 → 保存确认弹窗 → 网页历史 → 系统默认退出
    if (this.showIcons) {
      this.showIcons = false;
      return true;
    }
    if (this.showSetting) {
      this.showSetting = false;
      return true;
    }
    // 保存确认弹窗打开时：返回键取消保存
    if (this.saveBtnVisible) {
      this.closeSaveDialog();
      return true;
    }
    // 当前页面是否可前进或者后退给定的step步(-1),正数代表前进，负数代表后退
    if (this.controller.accessStep(-1)) {
      this.controller.backward(); // 返回上一个web页
      // 执行用户自定义返回逻辑
      return true
    } else {
      // 执行系统默认返回逻辑，返回上一个page页
      return false
    }
  }

  /** 保存首页 URL（手动填写目标网址）：补 https:// 前缀，保存后立即生效
   *  （未挂载 Web 时由条件渲染自动挂载；已挂载时直接整页加载新地址） */
  private saveHomeAndOpen(raw: string): void {
    const url = this.normalizeHomeUrl(raw);
    if (url === '') {
      promptAction.showToast({ message: '请输入有效的URL地址' });
      return;
    }
    this.home_url = url;
    saveHomeUrl(url);
    const wasMounted: boolean = this.saved_home_url !== '';
    this.saved_home_url = url;
    this.firstSrc = url;
    this.showSetting = false;
    if (wasMounted) {
      this.backToHome();
    }
  }

  /** URL 归一化：无 scheme 时补 https://（手动输入 m.example.com 也能直接用） */
  private normalizeHomeUrl(raw: string): string {
    const s = (raw || '').trim();
    if (s === '') {
      return '';
    }
    const lower = s.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return s;
    }
    return 'https://' + s;
  }

  /** 首页 URL 的 https origin（Cookie 写入/读取域跟随首页） */
  private homeOrigin(): string {
    const m: RegExpMatchArray | null = this.saved_home_url.match(/^https?:\/\/[^/]+/);
    return m && m[0] ? m[0] : '';
  }

  onRefreshing() {
    // 设置新的定时器
    this.refreshTimerId = setTimeout(() => {
      this.list = Array(20).fill(Date.now());
      this.refreshing = false;

      if (!this.is_home) {
        this.refreshWeb();
        this.is_home = false;
        promptAction.showToast({ message: '刷新成功' });
      }
    }, 1000);
  }

  // 统一清除定时器方法
  private clearRefreshTimer() {
    if (this.refreshTimerId !== null) {
      clearTimeout(this.refreshTimerId);
      this.refreshTimerId = null;
    }
  }

  private refreshWeb() {
    if (this.isRefreshing) {
      return;
    }
    this.isRefreshing = true;
    // 执行刷新
    this.controller.refresh();

    //刷新完成后恢复
    setTimeout(() => {
      this.isRefreshing = false;
    }, 1000);
  }

  // 中断刷新函数
  private cancelRefresh() {
    this.clearRefreshTimer(); // 统一清除
    this.isRefreshing = true;
    this.refreshing = true;
    this.controller.stop();
  }

  // 返回首页
  backToHome() {
    // 首页 URL 未设置：无网页可回
    if (this.saved_home_url === '') {
      return;
    }
    // 启动性能：当前已在目标首页（首帧 src 命中）时跳过，避免同 URL 重复加载
    try {
      const target = this.saved_home_url;
      let current = '';
      try {
        current = this.controller.getUrl() || '';
      } catch (e) {
        current = '';
      }
      if (current !== '' && current === target) {
        return;
      }
      this.controller.loadUrl(target);
    } catch (err) {
    }
  }

  /** 获取当前 Cookie：从 WebView CookieStore 读出首页域的现有 Cookie，
   * 按名称去重合并，拼成 k=v; k=v 串返回。空串表示取不到（未登录/内核未就绪） */
  private fetchCurrentCookie(): string {
    const origin: string = this.homeOrigin();
    if (origin === '') {
      return '';
    }
    const names: string[] = [];
    const values: string[] = [];
    let raw = '';
    try {
      raw = webview.WebCookieManager.fetchCookieSync(origin) || '';
    } catch (err) {
      raw = '';
    }
    const parts = raw.split(';');
    for (let i = 0; i < parts.length; i++) {
      const kv = parts[i].trim();
      const eq = kv.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name = kv.substring(0, eq).trim();
      const value = kv.substring(eq + 1).trim();
      if (name === '' || value === '') {
        continue;
      }
      let idx = -1;
      for (let j = 0; j < names.length; j++) {
        if (names[j] === name) {
          idx = j;
          break;
        }
      }
      if (idx >= 0) {
        values[idx] = value;
      } else {
        names.push(name);
        values.push(value);
      }
    }
    let out = '';
    for (let j = 0; j < names.length; j++) {
      out = out + (out === '' ? '' : '; ') + names[j] + '=' + values[j];
    }
    return out;
  }

  /** Cookie 登录：把用户粘贴的 Cookie 串逐对写入首页域，写入后随请求自动携带。
   * 返回是否成功写入；串为空返回 false（不置 pending） */
  private applyWebCookie(): boolean {
    const raw = (this.savedCookie || '').trim();
    const origin: string = this.homeOrigin();
    if (raw === '' || origin === '') {
      return false;
    }
    let ok = false;
    try {
      const parts = raw.split(';');
      for (let i = 0; i < parts.length; i++) {
        const kv = parts[i].trim();
        if (kv.indexOf('=') <= 0) {
          continue;
        }
        try {
          webview.WebCookieManager.configCookieSync(origin, kv);
          ok = true;
        } catch (err) {
        }
      }
    } catch (e) {
      return false;
    }
    return ok;
  }

  // 用系统/外部应用打开非网页协议链接（如应用深链 scheme）
  async openExternalApp(url: string) {
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
    promptAction.showToast({ message: '未找到可以打开此链接的应用' });
  }


  get_isWebDark(): boolean {
    return this.webDark === 'dark';
  }

  /** 长按网页图片/视频 -> 接管系统菜单，弹自绘菜单（移植自 aira-browser 长按上下文菜单方案） */
  handleWebContextMenu(event: OnContextMenuShowEvent): boolean {
    try {
      if (!event || !event.param) {
        return false;
      }
      const param = event.param;
      let mediaType: number = -1;
      try {
        mediaType = Number(param.getMediaType());
      } catch (err) {
        mediaType = -1;
      }
      let sourceUrl: string = '';
      try {
        sourceUrl = param.getSourceUrl() || '';
      } catch (err) {
        sourceUrl = '';
      }
      let xPx: number = 0;
      let yPx: number = 0;
      try {
        xPx = Number(param.x());
        yPx = Number(param.y());
      } catch (err) {
        xPx = 0;
        yPx = 0;
      }
      // 图片/视频之外的（纯文本、普通区域）走系统默认
      if (mediaType !== 1 && mediaType !== 2 && mediaType !== 3) {
        return false;
      }
      if (!sourceUrl) {
        return false;
      }
      this.ctxUrl = sourceUrl;
      if (mediaType === 1) {
        this.ctxItems = ['保存图片', '复制图片', '分享图片', '复制图片链接'];
      } else {
        this.ctxItems = ['复制视频链接', '其他应用打开'];
      }
      // 坐标 px -> vp，并夹在屏幕内（菜单约 170vp 宽）
      const screenWVp: number = px2vp(display.getDefaultDisplaySync().width);
      const screenHVp: number = px2vp(display.getDefaultDisplaySync().height);
      this.ctxX = Math.min(Math.max(px2vp(xPx), 8), Math.max(screenWVp - 178, 8));
      this.ctxY = Math.min(Math.max(px2vp(yPx), 8), Math.max(screenHVp - 200, 8));
      if (event.result) {
        try {
          event.result.closeContextMenu();
        } catch (err) {
        }
      }
      this.ctxVisible = true;
      return true;
    } catch (err) {
      return false;
    }
  }

  /** 解析页面内取图桥的分片消息：__STQ_IMGB64__<reqId>:<seq|meta|err>:<total>:<chunk> */
  private handleImgBridge(msg: string): boolean {
    try {
      const prefix = '__STQ_IMGB64__';
      const rest: string = msg.substring(prefix.length);
      const c1: number = rest.indexOf(':');
      if (c1 <= 0) {
        return true;
      }
      const reqId: string = rest.substring(0, c1);
      const c2: number = rest.indexOf(':', c1 + 1);
      if (c2 <= 0) {
        return true;
      }
      const tag: string = rest.substring(c1 + 1, c2);
      if (tag === 'err') {
        // 页面侧取图失败：置 -1 让等待方立即退出
        this.imgTotal.set(reqId, -1);
        return true;
      }
      const c3: number = rest.indexOf(':', c2 + 1);
      if (tag === 'meta') {
        const total: number = Number(rest.substring(c2 + 1, c3 < 0 ? rest.length : c3)) || 0;
        this.imgTotal.set(reqId, total);
        if (!this.imgChunks.has(reqId)) {
          this.imgChunks.set(reqId, []);
        }
        return true;
      }
      const seq: number = Number(tag);
      if (isNaN(seq)) {
        return true;
      }
      // 数据分片格式 reqId:seq:total:chunk；base64 不含 ':'，直接取最后一段
      const chunk: string = c3 >= 0 ? rest.substring(c3 + 1) : rest.substring(c2 + 1);
      let parts: string[] | undefined = this.imgChunks.get(reqId);
      if (!parts) {
        parts = [];
        this.imgChunks.set(reqId, parts);
      }
      parts.push(chunk);
      return true;
    } catch (err) {
      return true;
    }
  }

  /** 兜底取图：在 WebView 页面上下文内 fetch（同 <img> 的 Cookie/UA/凭证上下文），base64 分片回传 */
  private async fetchImageViaPage(url: string): Promise<ArrayBuffer | null> {
    const reqId: string = 'r' + Date.now().toString();
    this.imgChunks.delete(reqId);
    this.imgTotal.delete(reqId);
    try {
      await this.controller.runJavaScript('window.__stqFetchImage && window.__stqFetchImage('
        + JSON.stringify(reqId) + ',' + JSON.stringify(url) + ')');
    } catch (err) {
      const be = err as BusinessError;
      hilog.warn(0x0000, TAG, 'page fetch inject fail: %{public}s', (be && be.message) ? be.message : '?');
      return null;
    }
    const deadline: number = Date.now() + 20000;
    while (Date.now() < deadline) {
      const total: number = this.imgTotal.get(reqId) || 0;
      if (total === -1) {
        hilog.warn(0x0000, TAG, 'page fetch rejected by page context (CORS/网络)');
        return null;
      }
      const parts: string[] | undefined = this.imgChunks.get(reqId);
      if (total > 0 && parts && parts.length >= total) {
        let b64: string = '';
        for (let i = 0; i < total; i++) {
          b64 += (parts[i] || '');
        }
        try {
          const helper = new util.Base64Helper();
          const u8: Uint8Array = helper.decodeSync(b64);
          return u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
        } catch (err) {
          hilog.warn(0x0000, TAG, 'page fetch base64 decode fail');
          return null;
        }
      }
      await this.sleepMs(120);
    }
    hilog.warn(0x0000, TAG, 'page fetch timeout');
    return null;
  }

  private sleepMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  /**
   * 统一取图通道（保存/复制/分享共用）——主链路与保存图片完全一致：
   * 1) 资源嗅探缓存命中（页面加载图片时后台已抓取，字节直接可用）
   * 2) nas_nav 1:1 默认参数单次 GET（无自定义 UA/Referer，避开图源防盗链拦截，
   *    与 doDirectSave 的 copyUrlPicToFilesDir 同构）
   * 3) 兜底：多策略 Referer 矩阵 → 页面内 fetch → WebView 网络栈下载
   * 每级开始均有 toast 进度提示。
   */
  private async getWebImageBytes(url: string): Promise<ArrayBuffer> {
    // 1) 嗅探缓存：与保存同链路的第一优先级
    const cached: ArrayBuffer | null =
      url.length > 0 ? ImageResourceSniffer.getCached(url) : null;
    if (cached && cached.byteLength > 0) {
      hilog.info(0x0000, TAG, 'sniffer cache hit for copy/share: %{public}d B', cached.byteLength);
      return cached;
    }
    // 2) nas_nav 1:1 默认参数 GET（保存图片的实测可用通道，无任何请求头篡改）
    promptAction.showToast({ message: '正在获取图片…', duration: 2000 });
    try {
      const buf: ArrayBuffer = await this.fetchBytesDefaultGet(url);
      if (buf && buf.byteLength > 0 && WebImageSaver.isImageBytes(buf)) {
        hilog.info(0x0000, TAG, 'default GET ok: %{public}d B', buf.byteLength);
        return buf;
      }
      hilog.warn(0x0000, TAG, 'default GET: %{public}d B but not image',
        buf ? buf.byteLength : 0);
    } catch (err) {
      const be = err as BusinessError;
      hilog.warn(0x0000, TAG, 'default GET failed: %{public}s',
        (be && be.message) ? be.message : '?');
    }
    // 3) 兜底：历史多策略链路（URL 候选 × Referer 矩阵 → 页面内 fetch → WebView 下载）
    let pageUrl: string = '';
    try {
      pageUrl = this.controller.getUrl() || '';
    } catch (err) {
      pageUrl = '';
    }
    let cookie: string = '';
    try {
      cookie = webview.WebCookieManager.fetchCookieSync(url) || '';
    } catch (err) {
      cookie = '';
    }
    promptAction.showToast({ message: '直连受限，正在多策略重试…', duration: 2000 });
    try {
      const data: ArrayBuffer =
        await WebImageSaver.fetchImageEx(url, pageUrl, cookie, this.userAgent);
      if (data && data.byteLength > 0) {
        return data;
      }
    } catch (err) {
      const be = err as BusinessError;
      hilog.warn(0x0000, TAG, 'native fetch all strategies failed: %{public}s',
        (be && be.message) ? be.message : '?');
    }
    promptAction.showToast({ message: '直连受限，正在页面内取图…', duration: 2000 });
    const data2: ArrayBuffer | null = await this.fetchImageViaPage(url);
    if (data2 && data2.byteLength > 0 && WebImageSaver.isImageBytes(data2)) {
      return data2;
    }
    // 3) WebView 网络栈下载兜底：与页面显示图片同一网络上下文（同 UA/同 Cookie/无 Referer 篡改），
    //    防盗链源站按"浏览器行为"放行——最接近网页自身加载路径的取图方式
    promptAction.showToast({ message: '正在经浏览器通道取图…', duration: 2000 });
    try {
      const data3: ArrayBuffer = await this.downloadViaWeb(url);
      if (data3 && data3.byteLength > 0 && WebImageSaver.isImageBytes(data3)) {
        return data3;
      }
      hilog.warn(0x0000, TAG, 'web download fallback: got %{public}d B but not image',
        data3 ? data3.byteLength : 0);
    } catch (err) {
      const be = err as BusinessError;
      hilog.warn(0x0000, TAG, 'web download fallback failed: %{public}s',
        (be && be.message) ? be.message : '?');
    }
    let host: string = url;
    try {
      const m: RegExpMatchArray | null = url.match(/^https?:\/\/([^/]+)/);
      if (m && m[1]) {
        host = m[1];
      }
    } catch (err) {
    }
    throw new Error('图片源拒绝访问[' + host + ']');
  }

  /**
   * nas_nav 1:1 默认参数单次 GET（与保存图片的 copyUrlPicToFilesDir 同构，仅返回
   * 字节不落盘）：无 header、无 expectDataType、无 maxLimit——图源按"原生默认行为"
   * 放行，避开自定义 UA/Referer 触发的防盗链拦截。
   */
  private async fetchBytesDefaultGet(picUrl: string): Promise<ArrayBuffer> {
    const httpRequest = http.createHttp();
    try {
      const data: http.HttpResponse =
        await (httpRequest.request(picUrl) as Promise<http.HttpResponse>);
      if (data && data.responseCode === http.ResponseCode.OK
        && data.result instanceof ArrayBuffer) {
        return data.result as ArrayBuffer;
      }
      return new ArrayBuffer(0);
    } finally {
      httpRequest.destroy();
    }
  }

  /** 用 WebView 网络栈下载 URL 资源，返回文件字节（读完即删临时文件） */
  private downloadViaWeb(url: string): Promise<ArrayBuffer> {
    return new Promise<ArrayBuffer>((resolve, reject) => {
      const delegate = new webview.WebDownloadDelegate();
      const handler = this.webDownloadFile;
      let settled: boolean = false;
      const finish = (fn: () => void): void => {
        if (!settled) {
          settled = true;
          handler.suppressImageIntercept = false;
          fn();
        }
      };
      delegate.onDownloadFinish((item: webview.WebDownloadItem) => {
        try {
          const path: string = item.getFullPath();
          hilog.info(0x0000, TAG, 'web download finish: %{public}s', path);
          const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
          const st = fileIo.statSync(f.fd);
          const buf = new ArrayBuffer(st.size);
          fileIo.readSync(f.fd, buf);
          fileIo.closeSync(f);
          try {
            fileIo.unlinkSync(path);
          } catch (err) {
          }
          finish(() => resolve(buf));
        } catch (err) {
          finish(() => reject(new Error('下载文件读取失败')));
        }
      });
      delegate.onDownloadFailed((item: webview.WebDownloadItem) => {
        finish(() => reject(new Error('WebView 下载失败(state=' + item.getState() + ')')));
      });
      try {
        webview.WebDownloadManager.setDownloadDelegate(delegate);
        // 取图下载进行中：暂停下载拦截（避免拦截回调回环触发 saveWebImage）
        this.webDownloadFile.suppressImageIntercept = true;
        this.controller.startDownload(url);
        hilog.info(0x0000, TAG, 'web download start: %{public}s', url.substring(0, 120));
      } catch (err) {
        finish(() => reject(new Error('WebView 下载不可用')));
        return;
      }
      setTimeout(() => {
        finish(() => reject(new Error('WebView 下载超时')));
      }, 60000);
    });
  }

  /**
   * 兜底确认框入口（长按菜单透明安全控件授权失败/站点下载拦截时走此路径）：
   * 打开最小确认框（无预览图），点击内嵌系统 SaveButton 后执行 nas_nav 直存。
   */
  private saveWebImage(url: string): void {
    if (url && url === this.saveInFlightUrl) {
      return;
    }
    this.saveInFlightUrl = url;
    try {
      this.pendingSaveBytes = new ArrayBuffer(0);
      this.pendingSaveUrl = url;
      this.saveBtnVisible = true;
    } finally {
      this.saveInFlightUrl = '';
    }
  }

  /** 下载完成魔数嗅探兜底：内容实为图片 → 带原始字节打开最小确认框 */
  private openSaveConfirm(data: ArrayBuffer, urlOrName: string): void {
    this.pendingSaveBytes = data;
    this.pendingSaveUrl = urlOrName;
    this.saveBtnVisible = true;
  }

  private closeSaveDialog(): void {
    this.saveBtnVisible = false;
    this.pendingSaveBytes = new ArrayBuffer(0);
    this.pendingSaveUrl = '';
  }

  /**
   * nas_nav 1:1 直存（必须在系统安全控件 SaveButton onClick 临时授权窗口内执行）：
   * 优先嗅探缓存字节；否则单次原生 GET（默认参数，与 nas_nav 完全一致）写
   * filesDir → MediaAssetChangeRequest.createImageAssetRequest + applyChanges
   * 直接入系统图库。无预览窗、无文件选择器、无多级重试。
   */
  private async doDirectSave(url: string, data?: ArrayBuffer): Promise<void> {
    let path: string = '';
    try {
      if (data && data.byteLength > 0) {
        path = context_index.filesDir + '/onlinePic_' + Date.now() + '.png';
        const dest = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
        fileIo.writeSync(dest.fd, data);
        fileIo.closeSync(dest);
      } else {
        // 嗅探缓存命中：字节已在本地（页面加载该图时后台抓取），直接落盘更快
        const cached: ArrayBuffer | null =
          url.length > 0 ? ImageResourceSniffer.getCached(url) : null;
        if (cached && cached.byteLength > 0) {
          hilog.info(0x0000, TAG, 'sniffer cache hit, direct save');
          path = context_index.filesDir + '/onlinePic_' + Date.now() + '.png';
          const dest = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
          fileIo.writeSync(dest.fd, cached);
          fileIo.closeSync(dest);
        } else {
          path = await this.copyUrlPicToFilesDir(url, 'onlinePic_' + Date.now() + '.png');
        }
      }
      if (!path || path.length === 0) {
        promptAction.showToast({ message: '保存失败：图片获取失败' });
        return;
      }
      const helper: photoAccessHelper.PhotoAccessHelper =
        photoAccessHelper.getPhotoAccessHelper(context_index);
      const req: photoAccessHelper.MediaAssetChangeRequest =
        photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context_index, path);
      await helper.applyChanges(req);
      hilog.info(0x0000, TAG, 'saved to gallery: %{public}s', req.getAsset().uri);
      promptAction.showToast({ message: '已保存到图库' });
    } catch (err) {
      const be = err as BusinessError;
      const msg: string = (be && be.message) ? be.message : '未知错误';
      hilog.error(0x0000, TAG, 'direct save failed: %{public}s', msg);
      promptAction.showToast({ message: '保存失败：' + msg });
    } finally {
      this.cleanupSaveCache(path);
    }
  }

  /** nas_nav 1:1：单次 GET 网络图片写沙箱 filesDir（默认请求参数，无 Referer 篡改） */
  private async copyUrlPicToFilesDir(picUrl: string, newFileName: string): Promise<string> {
    let uri: string = '';
    const httpRequest = http.createHttp();
    try {
      const data: http.HttpResponse =
        await (httpRequest.request(picUrl) as Promise<http.HttpResponse>);
      if (data && data.responseCode === http.ResponseCode.OK) {
        const dstPath: string = context_index.filesDir + '/' + newFileName;
        const dest = fileIo.openSync(dstPath,
          fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
        fileIo.writeSync(dest.fd, data.result as ArrayBuffer);
        fileIo.closeSync(dest);
        uri = dstPath;
      }
    } finally {
      httpRequest.destroy();
    }
    return uri;
  }

  private cleanupSaveCache(path: string): void {
    if (!path || path.length === 0) {
      return;
    }
    try {
      fileIo.unlinkSync(path);
    } catch (err) {
    }
  }

  /** 长按复制图片：统一取图 → 解码 PixelMap → 系统剪贴板 */
  private async copyWebImage(url: string): Promise<void> {
    try {
      const data: ArrayBuffer = await this.getWebImageBytes(url);
      await WebImageSaver.copyImageToClipboard(data);
      promptAction.showToast({ message: '图片已复制，可粘贴发送' });
    } catch (err) {
      const be = err as BusinessError;
      const msg: string = (be && be.message) ? be.message : '未知错误';
      hilog.error(0x0000, TAG, 'copy image failed: %{public}s', msg);
      promptAction.showToast({ message: '复制失败：' + msg });
    }
  }

  /** 长按分享图片：统一取图 → 写缓存文件 → 系统分享面板 */
  private async shareWebImage(url: string): Promise<void> {
    try {
      const data: ArrayBuffer = await this.getWebImageBytes(url);
      await WebImageSaver.shareImageFile(context_index, data, url);
    } catch (err) {
      const be = err as BusinessError;
      const msg: string = (be && be.message) ? be.message : '未知错误';
      hilog.error(0x0000, TAG, 'share image failed: %{public}s', msg);
      promptAction.showToast({ message: '分享失败：' + msg });
    }
  }

  onCtxItem(item: string): void {
    this.ctxVisible = false;
    const url = this.ctxUrl;
    if (item === '保存图片') {
      this.saveWebImage(url);
    } else if (item === '复制图片') {
      this.copyWebImage(url);
    } else if (item === '分享图片') {
      this.shareWebImage(url);
    } else if (item === '复制图片链接' || item === '复制视频链接') {
      WebImageSaver.copyText(url, '已复制链接');
    } else if (item === '其他应用打开') {
      this.openExternalApp(url);
    }
  }

  /** 是否深色渲染：强制深色开关打开 且 系统当前为深色（开关语义=深色跟随系统） */
  private isDarkModeNow(): boolean {
    return this.get_isWebDark() && this.sysDark;
  }

  /** 亮度反转（HSV 的 V 取反、降饱和）：用于强制深色渲染时把浅色采样色转成深色 */
  private darkenSample(hex: string): string {
    const r = parseInt(hex.substring(1, 3), 16) / 255;
    const g = parseInt(hex.substring(3, 5), 16) / 255;
    const b = parseInt(hex.substring(5, 7), 16) / 255;
    const max = Math.max(r, g, b);
    const min = Math.min(r, g, b);
    const v = max;
    const sv = max === 0 ? 0 : (max - min) / max;
    let h = 0;
    if (max !== min) {
      const d = max - min;
      if (max === r) {
        h = (g - b) / d + (g < b ? 6 : 0);
      } else if (max === g) {
        h = (b - r) / d + 2;
      } else {
        h = (r - g) / d + 4;
      }
      h /= 6;
    }
    const v2 = 1 - v;
    const s2 = Math.min(1, sv * 0.6);
    const i = Math.floor(h * 6);
    const f = h * 6 - i;
    const p = v2 * (1 - s2);
    const q = v2 * (1 - f * s2);
    const t = v2 * (1 - (1 - f) * s2);
    let r2 = 0;
    let g2 = 0;
    let b2 = 0;
    switch (i % 6) {
      case 0: r2 = v2; g2 = t; b2 = p; break;
      case 1: r2 = q; g2 = v2; b2 = p; break;
      case 2: r2 = p; g2 = v2; b2 = t; break;
      case 3: r2 = p; g2 = q; b2 = v2; break;
      case 4: r2 = t; g2 = p; b2 = v2; break;
      default: r2 = v2; g2 = p; b2 = q; break;
    }
    const to2 = (x: number): string => {
      const n = Math.round(x * 255).toString(16);
      return n.length < 2 ? '0' + n : n;
    };
    return '#' + to2(r2) + to2(g2) + to2(b2);
  }

  /** 亮度判断：true=浅色背景（用深色图标） */
  private lumLight(hex: string): boolean {
    const r = parseInt(hex.substring(1, 3), 16);
    const g = parseInt(hex.substring(3, 5), 16);
    const b = parseInt(hex.substring(5, 7), 16);
    return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6;
  }

  /** 系统栏样式：顶栏/底栏背景取页面采样色（全屏/非全屏均不固定），无采样时按深浅色兜底 */
  private async updateSystemBarStyle(topBg: string = '', bottomBg: string = ''): Promise<void> {
    try {
      const win = await window.getLastWindow(context_index);
      const dark = this.isDarkModeNow();
      let statusBarColor = dark ? '#FF1B1C21' : '#00000000';
      let statusContent = dark ? '#FFFFFFFF' : '#FF000000';
      let navigationBarColor = dark ? '#FF161920' : '#00000000';
      let navContent = '#FFFFFFFF';
      // 深色渲染下 DOM 采样仍是浅色主题原始色：浅色采样需反转成深色再上屏
      if (/^#[0-9a-fA-F]{6}$/.test(topBg)) {
        const effTop = dark && this.lumLight(topBg) ? this.darkenSample(topBg) : topBg;
        statusBarColor = '#FF' + effTop.substring(1);
        statusContent = this.lumLight(effTop) ? '#FF000000' : '#FFFFFFFF';
      }
      if (/^#[0-9a-fA-F]{6}$/.test(bottomBg)) {
        const effBottom = dark && this.lumLight(bottomBg) ? this.darkenSample(bottomBg) : bottomBg;
        navigationBarColor = '#FF' + effBottom.substring(1);
        navContent = this.lumLight(effBottom) ? '#FF000000' : '#FFFFFFFF';
      }
      win.setWindowSystemBarProperties({
        statusBarColor: statusBarColor,
        navigationBarColor: navigationBarColor,
        statusBarContentColor: statusContent,
        navigationBarContentColor: navContent,
        isStatusBarLightIcon: statusContent === '#FFFFFFFF'
      });
      // 避让区填充色与状态栏色保持一致（无采样时深色用顶栏色，浅色透明交给 panel_bg）
      let fillTop = '';
      if (/^#[0-9a-fA-F]{6}$/.test(topBg)) {
        fillTop = dark && this.lumLight(topBg) ? this.darkenSample(topBg) : topBg;
      } else {
        fillTop = dark ? '#1B1C21' : '';
      }
      if (fillTop !== this.topFillColor) {
        this.topFillColor = fillTop;
      }
      // 底栏抬高区填充色：与导航栏/底部采样色同一逻辑（无采样时深色用底栏色，浅色交给 panel_bg）
      let fillBottom = '';
      if (/^#[0-9a-fA-F]{6}$/.test(bottomBg)) {
        fillBottom = dark && this.lumLight(bottomBg) ? this.darkenSample(bottomBg) : bottomBg;
      } else {
        fillBottom = dark ? '#161920' : '';
      }
      if (fillBottom !== this.bottomFillColor) {
        this.bottomFillColor = fillBottom;
      }
    } catch (err) {
    }
  }

  /** 沉浸式取色：顶栏/底栏背景取页面色（不固定），图标按亮度自适应 */
  async applyImmersiveTheme(topBg: string, bottomBg: string = '', force: boolean = false): Promise<void> {
    if (!force && (!topBg || (topBg === this.lastTopBg && bottomBg === this.lastBottomBg))) {
      return;
    }
    if (topBg) {
      this.lastTopBg = topBg;
    }
    if (bottomBg) {
      this.lastBottomBg = bottomBg;
    }
    await this.updateSystemBarStyle(this.lastTopBg, this.lastBottomBg);
  }

  get_isLSRefresh() {
    if (this.isLSRefresh == 'true') {
      return true;
    } else {
      return false;
    }
  }

  get_isHideBar() {
    if (this.isHidebar == 'true') {
      return true;
    } else {
      return false;
    }
  }

  get_isHideStatus() {
    if (this.isHidestatus == 'true') {
      return true;
    } else {
      return false;
    }
  }

  get_isfull() {
    if (this.isFull == 'true') {
      return true;
    } else {
      return false;
    }
  }

  getuseragentbytype(type: string) {
    let ua: string = '';
    switch (type) {
      case 'Mobile':
        ua = ANDROID_UA; // 安卓客户端 UA
        break;
      case 'PC':
        ua = PC_UA;
        break;
      case 'custom':
        ua = this.c_pg_ua;
        break;
      default:
        ua = 'error';
        break;
    }
    return ua;
  }


  change_userAgent() {
    // 默认（Mobile）：伪装安卓客户端 UA，网页按 Android 手机环境渲染
    this.userAgent = this.getuseragentbytype(this.ua_type);
    this.controller.setCustomUserAgent(this.userAgent);
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
    .padding({ left: 12, right: 12, bottom: this.homeNavVp + 12 })
    .onClick(() => {
      this.showIcons = false;
    })
  }
}
