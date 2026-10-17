import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { SharedApiClient } from '../api/SharedApiClient';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';
import { RemoteDownloadedAttachment } from '../api/SessionDtos';
import { SessionsApi } from '../api/SessionsApi';

const ATTACHMENT_IMAGE_CACHE_LIMIT = 32;
const ATTACHMENT_MAX_DOWNLOAD_BYTES = 26214400;

const attachmentPixelMapCache: Map<string, image.PixelMap> = new Map();
const attachmentPixelMapOrder: string[] = [];
const attachmentPendingKeys: Set<string> = new Set();

function rememberAttachmentPixelMap(key: string, pixelMap: image.PixelMap): void {
  if (attachmentPixelMapCache.has(key)) {
    return;
  }
  attachmentPixelMapCache.set(key, pixelMap);
  attachmentPixelMapOrder.push(key);
  while (attachmentPixelMapOrder.length > ATTACHMENT_IMAGE_CACHE_LIMIT) {
    const evicted = attachmentPixelMapOrder.shift();
    if (evicted === undefined) {
      break;
    }
    const cached = attachmentPixelMapCache.get(evicted);
    if (cached !== undefined) {
      cached.release();
    }
    attachmentPixelMapCache.delete(evicted);
  }
}

@Component
export struct AttachmentImageView {
  @Prop sessionId: string = '';
  @Prop fileId: string = '';
  @State pixelMap: image.PixelMap | undefined = undefined;
  @State loadState: string = 'loading';
  @State errorText: string = '';
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private sessionsApi: SessionsApi = new SessionsApi(SharedApiClient.getInstance());

  aboutToAppear(): void {
    this.loadPixelMap();
  }

  private async loadPixelMap(): Promise<void> {
    if (this.fileId.length === 0 || this.sessionId.length === 0) {
      this.loadState = 'failed';
      this.errorText = 'Attachment is unavailable.';
      return;
    }
    const key = `${this.sessionId}/${this.fileId}`;
    const cached = attachmentPixelMapCache.get(key);
    if (cached !== undefined) {
      this.pixelMap = cached;
      this.loadState = 'loaded';
      return;
    }
    if (attachmentPendingKeys.has(key)) {
      setTimeout(() => {
        this.loadPixelMap();
      }, 600);
      return;
    }
    attachmentPendingKeys.add(key);
    try {
      const downloaded: RemoteDownloadedAttachment = await this.sessionsApi.downloadSessionAttachment(
        this.authStore.readServerUrl(), this.authStore.readAccessToken(), this.sessionId, this.fileId);
      if (downloaded.contentBase64.length === 0) {
        throw new Error('The attachment did not download completely.');
      }
      const decoder = new util.Base64Helper();
      const bytes = decoder.decodeSync(downloaded.contentBase64);
      if (bytes.byteLength === 0 || bytes.byteLength > ATTACHMENT_MAX_DOWNLOAD_BYTES) {
        throw new Error('The attachment is too large to display.');
      }
      if (downloaded.size > 0 && bytes.byteLength !== downloaded.size) {
        throw new Error('The attachment did not download completely.');
      }
      const source = image.createImageSource(bytes);
      const decoded = await source.createPixelMap();
      await source.release();
      rememberAttachmentPixelMap(key, decoded);
      this.pixelMap = decoded;
      this.loadState = 'loaded';
    } catch (error) {
      this.loadState = 'failed';
      this.errorText = errorMessageFrom(error as Object);
    } finally {
      attachmentPendingKeys.delete(key);
    }
  }

  private statusLabel(): string {
    if (this.loadState === 'loading') {
      return 'Loading image…';
    }
    return this.errorText.length > 0 ? this.errorText : 'Could not load the attachment.';
  }

  build() {
    Column() {
      if (this.pixelMap !== undefined) {
        Image(this.pixelMap)
          .objectFit(ImageFit.Contain)
          .borderRadius(8)
          .width('100%')
          .constraintSize({ maxHeight: 260 })
      } else if (this.loadState === 'failed') {
        Row({ space: 8 }) {
          Text(this.statusLabel())
            .fontSize(12)
            .fontColor('#6B7280')
            .layoutWeight(1)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Button('Retry')
            .fontSize(11)
            .height(24)
            .padding({ left: 8, right: 8 })
            .backgroundColor('#E5E7EB')
            .fontColor('#374151')
            .onClick(() => {
              this.loadState = 'loading';
              this.loadPixelMap();
            })
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(8)
        .backgroundColor('rgba(0,0,0,0.06)')
      } else {
        Row({ space: 8 }) {
          LoadingProgress()
            .width(16)
            .height(16)
          Text(this.statusLabel())
            .fontSize(12)
            .fontColor('#6B7280')
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(8)
        .backgroundColor('rgba(0,0,0,0.06)')
      }
    }
    .width('100%')
  }
}
