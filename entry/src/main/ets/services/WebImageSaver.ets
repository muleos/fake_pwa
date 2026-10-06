/**
 * WebImageSaver.ets
 * 网页图片保存至图库 / 链接复制（移植自 aira-browser WebImageContextActionService 的精简实现）
 *
 * 两段式 API（v1.1.3 重构）：
 *  - fetchImageEx：原生取图，Referer 多策略重试（页面 URL → 空 → 图片自身 origin），
 *    覆盖常见防盗链配置（只允许同域 Referer 或允许空 Referer 的源站）
 *  - saveViaCreationDialog：字节落图库唯一通道（aira 同构）——系统创建相册对话框
 *    一步确认，原始字节直写图库；无任何文件选择器回退，绝不落文件管理
 * 全链路 hilog 诊断（TAG: web-savePic），真机排查用 `hdc shell hilog | grep web-savePic`
 */
import { http } from '@kit.NetworkKit';
import { fileIo, fileUri } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { image } from '@kit.ImageKit';
import { systemShare } from '@kit.ShareKit';
import { uniformTypeDescriptor } from '@kit.ArkData';

const MAX_BYTES: number = 30 * 1024 * 1024;
const TAG: string = 'web-savePic';

export class WebImageSaver {

  /**
   * 原生直取图片：URL 候选 × Referer 策略 组合重试，逐次校验图片魔数。
   *
   * Referer 策略顺序（关键）：空 Referer 排第一 —— 搜图神器的 HTML 声明
   * `<meta name="referrer" content="no-referrer">`，WebView 显示图片时不带 Referer；
   * 花瓣等源站对"带非白名单 Referer"的请求一律 567/403 拒绝，空 Referer 才放行
   * （实测：gd-hbimg.huaban.com 空 Referer 200/1.09MB，带页面 Referer 567）。
   *
   * URL 候选：原 URL + 花瓣 edge 域回退 —— 站点自身在 gd-hbimg-edge/gd-hbimg 两域间
   * 改写（replaceHuabanUrlDomain/picAddWatermark），edge 域签名失效时主域往往仍可用。
   */
  static async fetchImageEx(url: string, pageReferer: string, cookie: string,
    userAgent: string): Promise<ArrayBuffer> {
    // data: URL 直接解码（内联图片，无网络请求）
    if (url.trim().toLowerCase().indexOf('data:image/') === 0) {
      const comma: number = url.indexOf(',');
      if (comma > 0 && url.substring(0, comma).toLowerCase().indexOf('base64') >= 0) {
        try {
          const helper = new util.Base64Helper();
          const u8: Uint8Array = helper.decodeSync(url.substring(comma + 1));
          const buf: ArrayBuffer = u8.buffer.slice(u8.byteOffset, u8.byteOffset + u8.byteLength) as ArrayBuffer;
          if (WebImageSaver.isLikelyImage(buf)) {
            return buf;
          }
        } catch (err) {
        }
      }
      throw new Error('无法解析内联图片');
    }
    // 1) URL 候选
    const urls: string[] = [url];
    try {
      const m: RegExpMatchArray | null = url.match(/^(https?:\/\/)gd-hbimg-edge\.huaban\.com\/(.+)$/);
      if (m) {
        urls.push(m[1] + 'gd-hbimg.huaban.com/' + m[2]);
      }
    } catch (err) {
    }
    // 2) Referer 候选：空 → 页面 URL → 图片 origin（去重保序）
    const referers: string[] = [''];
    if (pageReferer && pageReferer !== '') {
      referers.push(pageReferer);
    }
    try {
      const m2: RegExpMatchArray | null = url.match(/^https?:\/\/[^/]+/);
      if (m2 && m2[0]) {
        const originRef: string = m2[0] + '/';
        if (referers.indexOf(originRef) < 0) {
          referers.push(originRef);
        }
      }
    } catch (err) {
    }
    // 3) 组合重试
    let lastErr: Error = new Error('未知错误');
    for (const candidate of urls) {
      for (const referer of referers) {
        try {
          const data: ArrayBuffer = await WebImageSaver.fetchImage(candidate, referer, cookie, userAgent);
          if (data && data.byteLength > 0 && WebImageSaver.isLikelyImage(data)) {
            hilog.info(0x0000, TAG, 'fetch ok: %{public}d B, url=%{public}s, referer=%{public}s',
              data.byteLength, candidate.substring(0, 100),
              referer === '' ? '(empty)' : referer.substring(0, 60));
            return data;
          }
          lastErr = new Error('HTTP 2xx 但非图片内容（可能为防盗链错误页）');
        } catch (err) {
          const be = err as BusinessError;
          lastErr = new Error((be && be.message) ? be.message : '取图失败');
        }
        hilog.warn(0x0000, TAG, 'fetch fail (url=%{public}s, referer=%{public}s): %{public}s',
          candidate.substring(0, 100), referer === '' ? '(empty)' : referer.substring(0, 60),
          lastErr.message);
      }
    }
    throw lastErr;
  }

  /** 图片魔数校验（公开）：页面 fetch / WebView 下载兜底通道的字节校验入口 */
  static isImageBytes(data: ArrayBuffer): boolean {
    return WebImageSaver.isLikelyImage(data);
  }

  /** 图片魔数校验：jpg/png/gif/webp；2xx HTML 防盗链错误页在这里被拒绝 */
  static isLikelyImage(data: ArrayBuffer): boolean {    try {
      const bytes = new Uint8Array(data.slice(0, 12));
      if (bytes.length < 4) {
        return false;
      }
      if (bytes[0] === 0xFF && bytes[1] === 0xD8) {
        return true;
      }
      if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) {
        return true;
      }
      if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) {
        return true;
      }
      if (bytes.length >= 12 && bytes[0] === 0x52 && bytes[1] === 0x49 && bytes[2] === 0x46 &&
        bytes[3] === 0x46 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42) {
        return true;
      }
    } catch (err) {
    }
    return false;
  }

  /** 公开缓存写入：UI 层预览 + 双通道保存共用的沙箱缓存文件 */
  static async writeToCacheFile(context: common.UIAbilityContext,
    data: ArrayBuffer, ext: string): Promise<string> {
    return WebImageSaver.writeToCache(context, data, ext);
  }

  /**
   * 通道一：系统「创建相册资产」对话框（免权限，返回相册 URI 后原始字节写入）。
   * 返回 'saved'（已入库）/ 'cancel'（用户取消）；对话框不可用时抛错，由调用方回退安全控件。
   */
  static async saveViaCreationDialog(context: common.UIAbilityContext, cachePath: string,
    data: ArrayBuffer, ext: string): Promise<string> {
    const helper: photoAccessHelper.PhotoAccessHelper =
      photoAccessHelper.getPhotoAccessHelper(context);
    const config: photoAccessHelper.PhotoCreationConfig = {
      title: 'Soutu_' + Date.now(),
      fileNameExtension: ext,
      photoType: photoAccessHelper.PhotoType.IMAGE
    };
    const created: string[] =
      await helper.showAssetsCreationDialog([fileUri.getUriFromPath(cachePath)], [config]);
    if (created && created.length > 0) {
      const targetFile = fileIo.openSync(created[0], fileIo.OpenMode.READ_WRITE);
      fileIo.writeSync(targetFile.fd, data);
      fileIo.closeSync(targetFile);
      hilog.info(0x0000, TAG, 'saved via creation dialog: %{public}s', created[0]);
      return 'saved';
    }
    return 'cancel';
  }

  /**
   * 安全控件临时授权直写图库 —— 必须在 SaveButton onClick 回调内调用
   * （点击后约 10s 临时授权窗口内 createAsset 免权限，无任何二次弹窗，直接入库）。
   * 这是长按保存的确定性通道：不依赖 showAssetsCreationDialog 的设备可用性。
   */
  static async saveViaSecurityButton(context: common.UIAbilityContext,
    data: ArrayBuffer, ext: string): Promise<void> {
    if (!data || data.byteLength === 0) {
      throw new Error('图片内容为空');
    }
    const helper: photoAccessHelper.PhotoAccessHelper =
      photoAccessHelper.getPhotoAccessHelper(context);
    const uri: string = await helper.createAsset(photoAccessHelper.PhotoType.IMAGE, ext);
    const targetFile = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE);
    fileIo.writeSync(targetFile.fd, data);
    fileIo.closeSync(targetFile);
    hilog.info(0x0000, TAG, 'saved via security button: %{public}s', uri);
  }

  /** 提取 URL 主机名（错误提示定位图源用） */
  static urlHost(url: string): string {
    const m: RegExpMatchArray | null = url.match(/^https?:\/\/([^\/?#]+)/);
    return m ? m[1] : url.substring(0, 60);
  }

  /**
   * nas_nav 同构下载：安全控件授权窗口内**单次原生 GET**（默认无 Referer——
   * 花瓣等图床对空 Referer 放行），魔数校验后写沙箱缓存，返回文件路径。
   * 无多级重试，一次到位（快）。
   */
  static async downloadImageSimple(url: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        usingCache: true,
        connectTimeout: 10000,
        readTimeout: 15000,
        maxLimit: MAX_BYTES / 1024
      });
      if (resp.responseCode !== http.ResponseCode.OK || !(resp.result instanceof ArrayBuffer)) {
        const code: number = resp.responseCode as number;
        throw new Error('图源返回 ' + code + ' [' + WebImageSaver.urlHost(url) + ']');
      }
      const data: ArrayBuffer = resp.result as ArrayBuffer;
      if (!data || data.byteLength === 0 || !WebImageSaver.isLikelyImage(data)) {
        throw new Error('图源返回非图片内容 [' + WebImageSaver.urlHost(url) + ']');
      }
      const ext: string = WebImageSaver.sniffExtension(data, url);
      return await WebImageSaver.writeToCache(WebImageSaver.appContext(), data, ext);
    } finally {
      httpRequest.destroy();
    }
  }

  /** 当前 UIAbility 上下文（downloadImageSimple 沙箱写入用） */
  private static appContext(): common.UIAbilityContext {
    return getContext() as common.UIAbilityContext;
  }

  /**
   * nas_nav 同构入库（关键差异）：媒体库变更请求 `createImageAssetRequest` +
   * `applyChanges`——原始字节经沙箱文件登记进系统图库。与 createAsset+fd 直写
   * 相比授权模型不同，在部分设备上更可靠（nas_nav 实测可用）。
   * 必须在 SaveButton onClick 临时授权窗口内调用。
   */
  static async saveViaAssetChangeRequest(sandboxPath: string): Promise<void> {
    if (!sandboxPath || sandboxPath.length === 0) {
      throw new Error('图片文件未就绪');
    }
    const context = getContext() as common.UIAbilityContext;
    const helper: photoAccessHelper.PhotoAccessHelper =
      photoAccessHelper.getPhotoAccessHelper(context);
    const assetChangeRequest: photoAccessHelper.MediaAssetChangeRequest =
      photoAccessHelper.MediaAssetChangeRequest.createImageAssetRequest(context, sandboxPath);
    await helper.applyChanges(assetChangeRequest);
    hilog.info(0x0000, TAG, 'saved via asset change request: %{public}s',
      assetChangeRequest.getAsset().uri);
  }

  /** 复制文本（图片链接/视频链接） */
  static copyText(text: string, tip: string): void {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: tip });
    } catch (err) {
      promptAction.showToast({ message: '复制失败' });
    }
  }

  /** 复制图片本体到剪贴板（解码为 PixelMap 写入，粘到聊天输入框/备忘录即为图片） */
  static async copyImageToClipboard(data: ArrayBuffer): Promise<void> {
    if (!data || data.byteLength === 0) {
      throw new Error('图片内容为空');
    }
    const source: image.ImageSource = image.createImageSource(data);
    let pixelMap: image.PixelMap | null = null;
    try {
      pixelMap = await source.createPixelMap();
      const clipData = pasteboard.createData(pasteboard.MIMETYPE_PIXELMAP, pixelMap);
      await pasteboard.getSystemPasteboard().setData(clipData);
      hilog.info(0x0000, TAG, 'image copied to pasteboard: %{public}d B', data.byteLength);
    } finally {
      if (pixelMap) {
        await pixelMap.release().catch((_e: Error) => { });
      }
      await source.release().catch((_e: Error) => { });
    }
  }

  /** 分享图片：字节写缓存文件 → 系统分享面板（移植自 aira-browser shareImage 方案） */
  static async shareImageFile(context: common.UIAbilityContext, data: ArrayBuffer,
    url: string): Promise<void> {
    if (!data || data.byteLength === 0) {
      throw new Error('图片内容为空');
    }
    const ext: string = WebImageSaver.sniffExtension(data, url);
    const path: string = await WebImageSaver.writeToCache(context, data, ext);
    const uri: string = fileUri.getUriFromPath(path);
    const title: string = 'Soutu_' + Date.now() + '.' + ext;
    const utd: uniformTypeDescriptor.UniformDataType =
      ext === 'png' ? uniformTypeDescriptor.UniformDataType.PNG :
        ext === 'gif' ? uniformTypeDescriptor.UniformDataType.GIF :
          (ext === 'jpg' || ext === 'jpeg') ? uniformTypeDescriptor.UniformDataType.JPEG :
            uniformTypeDescriptor.UniformDataType.IMAGE;
    const shareData = new systemShare.SharedData({
      utd: utd,
      uri: uri,
      title: title,
      label: title
    });
    const controller = new systemShare.ShareController(shareData);
    await controller.show(context, {
      selectionMode: systemShare.SelectionMode.SINGLE,
      previewMode: systemShare.SharePreviewMode.DEFAULT
    });
    hilog.info(0x0000, TAG, 'share panel opened: %{public}s (%{public}d B)', path, data.byteLength);
  }

  static async fetchImage(url: string, referer: string,
    cookie: string, userAgent: string): Promise<ArrayBuffer> {
    const httpRequest = http.createHttp();
    try {
      const header: Record<string, string> = {};
      if (userAgent) {
        header['User-Agent'] = userAgent;
      }
      if (referer) {
        header['Referer'] = referer;
      }
      if (cookie) {
        header['Cookie'] = cookie;
      }
      header['Accept'] = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8';
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.GET,
        header: header,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 8000,
        readTimeout: 12000,
        usingCache: true,
        maxLimit: MAX_BYTES / 1024
      });
      hilog.info(0x0000, TAG, 'HTTP %{public}d, %{public}s', resp.responseCode, url.substring(0, 120));
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error('HTTP ' + resp.responseCode);
      }
      return resp.result as ArrayBuffer;
    } finally {
      httpRequest.destroy();
    }
  }

  static sniffExtension(data: ArrayBuffer, url: string): string {
    try {
      const bytes = new Uint8Array(data.slice(0, 16));
      if (bytes.length >= 4) {
        if (bytes[0] === 0xFF && bytes[1] === 0xD8) { return 'jpg'; }
        if (bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4E && bytes[3] === 0x47) { return 'png'; }
        if (bytes[0] === 0x47 && bytes[1] === 0x49 && bytes[2] === 0x46) { return 'gif'; }
        if (bytes[0] === 0x52 && bytes[8] === 0x57 && bytes[9] === 0x45 && bytes[10] === 0x42) { return 'webp'; }
      }
    } catch (err) { }
    const lower = url.toLowerCase();
    if (lower.indexOf('.png') > 0) { return 'png'; }
    if (lower.indexOf('.gif') > 0) { return 'gif'; }
    if (lower.indexOf('.webp') > 0) { return 'webp'; }
    if (lower.indexOf('.bmp') > 0) { return 'bmp'; }
    return 'jpg';
  }

  private static async writeToCache(context: common.UIAbilityContext,
    data: ArrayBuffer, ext: string): Promise<string> {
    const dir: string = context.cacheDir + '/web_images';
    try {
      fileIo.mkdirSync(dir, true);
    } catch (err) { }
    const path: string = dir + '/stq_' + Date.now() + '.' + ext;
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    // v1.2.9 关键修复：写原始 ArrayBuffer（与图库保存链路一致）。此前传 Uint8Array 视图
    // 在真机触发 "Invalid argument. Write failed. Invalid arraybuffer or options"，
    // 导致分享图片必失败
    fileIo.writeSync(file.fd, data);
    fileIo.closeSync(file);
    return path;
  }
}
