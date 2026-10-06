import { webview } from '@kit.ArkWeb'
import { BusinessError } from '@kit.BasicServicesKit'
import { fileIo, picker } from '@kit.CoreFileKit'

const TAG = 'WebDownloadFileHelper'

/**
 * @dec web下载文件抽象类,
 * @author ZhangHuiXin,
 * @param
 * @returns void
 * @date 2025/3/11 20:26,
 */
export abstract class IAbstractDownloadHandler {
  public webDownloadDelegate: webview.WebDownloadDelegate = new webview.WebDownloadDelegate()
  protected webDownloadItem: webview.WebDownloadItem | null = null
  protected downloadProgress: number = 0
  protected controller: webview.WebviewController | null = null
  protected isCustomPath: boolean = false
  /**
   * 图片类下载拦截回调（宿主页注入）：命中时不再走"另存到文件管理"链路，
   * 由宿主页改走图库保存（取图字节 → 创建对话框直写相册）。
   */
  public onImageDownload: ((url: string) => void) | null = null
  /**
   * 下载完成兜底回调：下载内容经魔数嗅探确为图片时触发，宿主页将原始字节
   * 直写图库（跳过 DocumentViewPicker，绝不落文件管理）。
   */
  public onImageDataDownload: ((data: ArrayBuffer, suggestedName: string) => void) | null = null
  /**
   * WebView 取图下载（downloadViaWeb）进行中置 true：onBeforeDownload 不做拦截、
   * 不弹下载确认框，交给其专属委托处理，避免拦截回环。
   */
  public suppressImageIntercept: boolean = false

  /**
   * 设置下载委托
   * */
  setDownloadDelegate(controller: webview.WebviewController, delegate?: webview.WebDownloadDelegate) {
    if (delegate) {
      this.webDownloadDelegate = delegate
    }
    try {
      this.controller = controller
      this.controller.setDownloadDelegate(this.webDownloadDelegate)
      this.setupDelegateCallbacks(this.webDownloadDelegate)
    } catch (error) {
      this.handleError(error as BusinessError)
    }
  }

  /**
   * 启动文件下载
   * @param customPath 自定义存储路径（需包含文件名）
   */
  startDownload(customPath?: string) {
    if (!this.webDownloadItem) {
      throw new Error('DOWNLOAD_NOT_INITIALIZED')
    }

    try {
      const effectivePath = this.validatePath(customPath)
      this.prepareDirectory(effectivePath)

      this.webDownloadItem!.start(effectivePath)
      this.downloadProgress = 0
      this.isCustomPath = !!customPath
    } catch (error) {
      this.handleError(error as BusinessError)
    }
  }

  /**
   * 准备存储目录
   */
  prepareDirectory(fullPath: string) {
    const dirPath = fullPath.substring(0, fullPath.lastIndexOf('/'))

    if (!this.checkPathExists(dirPath)) {
      fileIo.mkdirSync(dirPath)
    }
  }

  /**
   * 抽象方法 - 处理下载开始
   * */
  protected abstract handleDownloadStart(): void

  /**
   * 抽象方法 - 更新进度
   * */
  protected abstract handleProgressUpdate(progress: number): void

  /**
   * 抽象方法 - 处理下载成功
   * */
  protected abstract handleDownloadSuccess(): void

  /**
   * 抽象方法 - 处理下载失败
   * */
  protected abstract handleDownloadFailure(message: string): void

  /**
   * 通用文件保存方法
   * */
  protected async saveFile(filePath: string): Promise<void> {
    const context = getContext()
    const fileName = this.extractFileName(filePath)
    const saveOptions = new picker.DocumentSaveOptions()
    saveOptions.newFileNames = [fileName]

    try {
      const documentSaveResult = await new picker.DocumentViewPicker(context).save(saveOptions)
      await this.copyFileContents(filePath, documentSaveResult[0])
    } catch (error) {
      throw new Error(`文件保存失败: ${(error as BusinessError).message}`)
    }
  }

  /**
   * 错误处理
   * */
  protected handleError(error: BusinessError) {
    console.error(`${TAG} ErrorCode: ${error.code}, Message: ${error.message}`)
    this.cleanupDownloadSession()
  }

  /**
   * 清理下载会话
   * */
  protected cleanupDownloadSession() {
    this.webDownloadItem = null
    this.downloadProgress = 0
  }

  /**
   * 路径验证与处理
   */
  private validatePath(customPath?: string): string {
    if (customPath) {
      return this.ensureFileExtension(customPath)
    }
    return this.generateDefaultPath()
  }

  /**
   * 生成默认下载路径
   */
  private generateDefaultPath(): string {

    const defaultDir = `${getContext(this).cacheDir}/web_download`
    const fileName = this.webDownloadItem?.getSuggestedFileName()
      || `download_${Date.now()}.bin`
    return `${defaultDir}${fileName}`
  }

  /**
   * 确保文件扩展名正确
   */
  private ensureFileExtension(path: string): string {
    const suggestedName = this.webDownloadItem?.getSuggestedFileName() || ''
    const expectedExt = suggestedName.split('.').pop() || ''
    const currentExt = path.split('.').pop() || ''

    return currentExt === expectedExt ? path : `${path}.${expectedExt}`
  }

  /**
   * 路径存在性检查
   */
  private checkPathExists(path: string): boolean {
    try {
      return fileIo.accessSync(path)
    } catch {
      return false
    }
  }

  /** 图片下载判定：MIME 为 image/*，或 URL/建议文件名带图片扩展名，
   * 或 URL 末段无扩展名（花瓣等图床 CDN 直链形如 xxx_fw658webp）——
   * 无扩展名情形由宿主页再做魔数校验，非图片会提示而非误存。 */
  private static isImageDownload(item: webview.WebDownloadItem): boolean {
    let mime: string = '';
    try {
      mime = (item.getMimeType() || '').toLowerCase();
      if (mime.indexOf('image/') === 0) {
        return true;
      }
    } catch (err) {
    }
    let url: string = '';
    try {
      url = (item.getUrl() || '').split('?')[0].toLowerCase();
    } catch (err) {
    }
    let name: string = '';
    try {
      name = (item.getSuggestedFileName() || '').toLowerCase();
    } catch (err) {
    }
    const extRe: RegExp = /\.(jpe?g|png|gif|webp|bmp|heic)$/;
    if (extRe.test(url) || extRe.test(name)) {
      return true;
    }
    // 无扩展名 URL（图床直链）：按疑似图片拦截，宿主页魔数校验兜底
    const seg: string = url.substring(url.lastIndexOf('/') + 1);
    if (seg.length > 0 && seg.indexOf('.') < 0 && mime.indexOf('text/') !== 0) {
      return true;
    }
    return false;
  }

  /** 读取已下载文件全部字节；失败返回 null */
  private static readFileBytes(path: string): ArrayBuffer | null {
    try {
      const f = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
      const st = fileIo.statSync(f.fd);
      const buf = new ArrayBuffer(st.size);
      fileIo.readSync(f.fd, buf);
      fileIo.closeSync(f);
      return buf;
    } catch (err) {
      return null;
    }
  }

  /** 魔数判定真实图片内容（jpg/png/gif/webp/bmp），不依赖 URL 与 MIME */
  private static isImageMagic(u: Uint8Array): boolean {
    if (!u || u.length < 12) {
      return false;
    }
    if (u[0] === 0xFF && u[1] === 0xD8 && u[2] === 0xFF) {
      return true; // jpeg
    }
    if (u[0] === 0x89 && u[1] === 0x50 && u[2] === 0x4E && u[3] === 0x47) {
      return true; // png
    }
    if (u[0] === 0x47 && u[1] === 0x49 && u[2] === 0x46) {
      return true; // gif
    }
    if (u[0] === 0x42 && u[1] === 0x4D) {
      return true; // bmp
    }
    if (u[0] === 0x52 && u[1] === 0x49 && u[2] === 0x46 && u[3] === 0x46 &&
      u[8] === 0x57 && u[9] === 0x45 && u[10] === 0x42 && u[11] === 0x50) {
      return true; // webp
    }
    return false;
  }

  /**
   * 初始化委托回调
   * */
  private setupDelegateCallbacks(delegate: webview.WebDownloadDelegate) {
    delegate.onBeforeDownload((item: webview.WebDownloadItem) => {
      // WebView 取图下载（downloadViaWeb）进行中：交给其专属委托，不拦截不弹框
      if (this.suppressImageIntercept) {
        return;
      }
      // 图片类下载（站点内建保存按钮/MIME 为 image、URL 或建议文件名带图片扩展名、
      // 或无扩展名图床直链）拦截改走图库：取消下载任务并交给宿主页图库保存链路
      if (this.onImageDownload && IAbstractDownloadHandler.isImageDownload(item)) {
        const url: string = item.getUrl() || '';
        try {
          item.cancel();
        } catch (err) {
        }
        if (url.length > 0) {
          this.onImageDownload(url);
        }
        return;
      }
      this.webDownloadItem = item
      this.handleDownloadStart()
    })

    delegate.onDownloadUpdated((item: webview.WebDownloadItem) => {
      this.downloadProgress = item.getPercentComplete()
      this.handleProgressUpdate(item.getPercentComplete())
    })

    delegate.onDownloadFailed((item: webview.WebDownloadItem) => {
      this.handleDownloadFailure('文件下载失败')
    })

    delegate.onDownloadFinish(async (item: webview.WebDownloadItem) => {
      try {
        const filePath = item.getFullPath()
        if (this.onImageDataDownload && !this.isCustomPath) {
          // 魔数嗅探兜底：下载内容实为图片 → 原始字节交宿主页直写图库，
          // 跳过 DocumentViewPicker，绝不落文件管理
          const buf: ArrayBuffer | null = IAbstractDownloadHandler.readFileBytes(filePath);
          if (buf && IAbstractDownloadHandler.isImageMagic(new Uint8Array(buf))) {
            const name: string = item.getSuggestedFileName() || '';
            this.closeDownloadPopup();
            this.cleanupDownloadSession();
            this.onImageDataDownload(buf, name);
            return;
          }
        }
        if (!this.isCustomPath) {
          await this.saveFile(filePath) // 仅非自定义路径需要另存操作
        }
        this.handleDownloadSuccess()
      } catch (error) {
        this.handleDownloadFailure(this.isCustomPath ? '文件下载失败' : '文件保存失败')
      }
    })
  }

  /** 下载会话善后（子类可覆盖）：默认仅清状态 */
  protected closeDownloadPopup(): void {
  }

  /**
   * 提取文件名
   * */
  private extractFileName(path: string): string {
    const match = path.match(/[^\\/]+$/)
    return match ? match[0] : `file_${Date.now()}`
  }

  /**
   * 复制文件内容
   * */
  private async copyFileContents(sourcePath: string, destPath: string) {
    const sourceFd = await fileIo.open(sourcePath, fileIo.OpenMode.READ_ONLY)
    const stat = await fileIo.stat(sourcePath)
    const buffer = new ArrayBuffer(stat.size)

    await fileIo.read(sourceFd.fd, buffer)
    await fileIo.close(sourceFd)

    const destFile = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE)
    await fileIo.write(destFile.fd, buffer)
    await fileIo.close(destFile.fd)
  }
}