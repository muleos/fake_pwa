import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { WebImageSaver } from './WebImageSaver';

const TAG: string = 'ImageSniffer';
const MAX_ENTRIES: number = 10;
const MAX_BYTES: number = 30 * 1024 * 1024;
const MAX_INFLIGHT: number = 3;

/**
 * 图片资源嗅探缓存（aira media discovery 同构思路）：
 * 页面加载图片请求时，经 Web.onInterceptRequest 观测 URL，并后台原生抓取一份字节入缓存；
 * 长按保存直接命中缓存 → 秒出保存弹窗，无需再走网络重试链。
 * 抓取失败完全不影响显示（onInterceptRequest 返回 null，内核照常加载）。
 *
 * 注意：onInterceptRequest 回调内禁止 UI 操作——本类只做内存缓存与后台请求。
 */
export class ImageResourceSniffer {
  private static cache: Map<string, ArrayBuffer> = new Map();
  private static inflight: Map<string, number> = new Map();

  /** 非图片 URL 快速过滤（onInterceptRequest 内同步调用） */
  static isLikelyImageUrl(url: string): boolean {
    if (!url || url.length < 12) {
      return false;
    }
    const lower: string = url.toLowerCase();
    if (lower.indexOf('data:') === 0 || lower.indexOf('blob:') === 0
      || lower.indexOf('about:') === 0 || lower.indexOf('javascript:') === 0) {
      return false;
    }
    const path: string = lower.split('?')[0];
    if (/\.(jpe?g|png|gif|webp|bmp|avif|svg)$/.test(path)) {
      return true;
    }
    if (/\.(js|css|html?|json|xml|m3u8|ts|mp4|webm|woff2?|ttf|eot|ico|txt)$/.test(path)) {
      return false;
    }
    // 图床/图片 CDN 特征：花瓣等直链无扩展名（xxx_fw658webp），按主机名识别
    try {
      const m: RegExpMatchArray | null = lower.match(/^https?:\/\/([^/]+)/);
      if (m && m[1]) {
        const host: string = m[1];
        return host.indexOf('img') >= 0 || host.indexOf('image') >= 0
          || host.indexOf('photo') >= 0 || host.indexOf('pic') >= 0;
      }
    } catch (err) {
    }
    return false;
  }

  /** 命中嗅探缓存（长按保存的秒出通道），命中即做 LRU 触碰 */
  static getCached(url: string): ArrayBuffer | null {
    const data: ArrayBuffer | undefined = ImageResourceSniffer.cache.get(url);
    if (data) {
      ImageResourceSniffer.cache.delete(url);
      ImageResourceSniffer.cache.set(url, data);
      return data;
    }
    return null;
  }

  /**
   * 资源嗅探：后台原生抓取图片字节入缓存（onInterceptRequest 内触发，不阻塞内核加载）。
   * Referer 策略：空 Referer 优先 —— 花瓣等图床对非白名单 Referer 一律 567/403，
   * 站点 no-referrer 语义即空 Referer。
   */
  static sniffAsync(url: string, userAgent: string): void {
    if (!url || url.length === 0) {
      return;
    }
    if (ImageResourceSniffer.cache.has(url) || ImageResourceSniffer.inflight.has(url)) {
      return;
    }
    if (ImageResourceSniffer.inflight.size >= MAX_INFLIGHT) {
      return;
    }
    ImageResourceSniffer.inflight.set(url, Date.now());
    const task = async (): Promise<void> => {
      let cookie: string = '';
      try {
        cookie = webview.WebCookieManager.fetchCookieSync(url) || '';
      } catch (err) {
      }
      const refs: string[] = [''];
      const origin: string = ImageResourceSniffer.originOf(url);
      if (origin.length > 0) {
        refs.push(origin);
      }
      for (const ref of refs) {
        try {
          const data: ArrayBuffer = await WebImageSaver.fetchImage(url, ref, cookie, userAgent);
          if (data && data.byteLength > 0 && data.byteLength <= MAX_BYTES
            && WebImageSaver.isLikelyImage(data)) {
            ImageResourceSniffer.put(url, data);
            hilog.info(0x0000, TAG, 'sniffed %{public}d B: %{public}s',
              data.byteLength, url.substring(0, 120));
            return;
          }
        } catch (err) {
        }
      }
      hilog.warn(0x0000, TAG, 'sniff miss: %{public}s', url.substring(0, 120));
    };
    task().finally(() => {
      ImageResourceSniffer.inflight.delete(url);
    });
  }

  /** LRU 插入：超出容量淘汰最早条目 */
  private static put(url: string, data: ArrayBuffer): void {
    if (ImageResourceSniffer.cache.has(url)) {
      ImageResourceSniffer.cache.delete(url);
    }
    ImageResourceSniffer.cache.set(url, data);
    while (ImageResourceSniffer.cache.size > MAX_ENTRIES) {
      let first: string = '';
      let found: boolean = false;
      for (const k of ImageResourceSniffer.cache.keys()) {
        first = k;
        found = true;
        break;
      }
      if (!found) {
        break;
      }
      ImageResourceSniffer.cache.delete(first);
    }
  }

  private static originOf(url: string): string {
    try {
      const m: RegExpMatchArray | null = url.match(/^https?:\/\/[^/]+/);
      if (m && m[0]) {
        return m[0] + '/';
      }
    } catch (err) {
    }
    return '';
  }
}
