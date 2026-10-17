import { ApiClient } from '../api/ApiClient';
import { DevicesApi, RemoteDevice } from '../api/DevicesApi';
import { FilesApi, RemoteDirectoryEntry, RemoteTextFile } from '../api/FilesApi';
import { SharedApiClient } from '../api/SharedApiClient';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';

interface DeviceOption {
  value: string;
  icon?: Resource;
}

const HOME_ROOT = '~';
const START_PATH = '.';

function parentPath(path: string): string {
  const slashIndex = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  if (slashIndex < 0) {
    return START_PATH;
  }
  const parent = path.substring(0, slashIndex);
  if (parent.length === 0) {
    return '/';
  }
  return parent;
}

function canGoUp(path: string): boolean {
  return path !== START_PATH && path !== '/' && path.length > 0;
}

function formatSize(size: number | null): string {
  if (size === null) {
    return '';
  }
  if (size < 1024) {
    return `${size} B`;
  }
  if (size < 1048576) {
    return `${(size / 1024).toFixed(1)} KB`;
  }
  return `${(size / 1048576).toFixed(1)} MB`;
}

@Component
export struct FilesPage {
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State errorMessage: string = '';
  @State devices: RemoteDevice[] = [];
  @State deviceOptions: DeviceOption[] = [];
  @State selectedDeviceIndex: number = 0;
  @State deviceId: string = '';
  @State entries: RemoteDirectoryEntry[] = [];
  @State currentPath: string = START_PATH;
  @State directoryTruncated: boolean = false;
  @State viewingFile: boolean = false;
  @State loadingFile: boolean = false;
  @State fileName: string = '';
  @State fileContent: string = '';
  @State fileSizeLabel: string = '';
  @State fileTruncated: boolean = false;
  @State fileBinary: boolean = false;
  private navPathStack: NavPathStack = new NavPathStack();
  private scroller: Scroller = new Scroller();
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private client: ApiClient = SharedApiClient.getInstance();
  private devicesApi: DevicesApi = new DevicesApi(this.client);
  private filesApi: FilesApi = new FilesApi(this.client);

  private serverUrl(): string {
    return this.authStore.readServerUrl();
  }

  private token(): string {
    return this.authStore.readAccessToken();
  }

  private async pickDevice(): Promise<void> {
    const devices = await this.devicesApi.listDevices(this.serverUrl(), this.token());
    if (devices.length === 0) {
      this.devices = [];
      this.deviceOptions = [];
      this.errorMessage = 'No devices paired yet.';
      this.loading = false;
      return;
    }
    let selectedIndex = 0;
    for (let index = 0; index < devices.length; index++) {
      if (devices[index].status === 'online') {
        selectedIndex = index;
        break;
      }
    }
    this.devices = devices;
    const options: DeviceOption[] = [];
    for (const device of devices) {
      options.push({ value: device.name });
    }
    this.deviceOptions = options;
    this.selectedDeviceIndex = selectedIndex;
    this.deviceId = devices[selectedIndex].id;
  }

  private sortEntries(entries: RemoteDirectoryEntry[]): RemoteDirectoryEntry[] {
    const sorted = entries.slice(0);
    sorted.sort((left: RemoteDirectoryEntry, right: RemoteDirectoryEntry): number => {
      const leftDir = left.type === 'directory';
      const rightDir = right.type === 'directory';
      if (leftDir !== rightDir) {
        return leftDir ? -1 : 1;
      }
      return left.name.localeCompare(right.name);
    });
    return sorted;
  }

  private async loadDirectory(path: string): Promise<void> {
    if (this.deviceId.length === 0) {
      return;
    }
    try {
      const directory = await this.filesApi.listFiles(this.serverUrl(), this.token(), this.deviceId,
        HOME_ROOT, path);
      this.entries = this.sortEntries(directory.entries);
      this.currentPath = directory.path.length > 0 ? directory.path : path;
      this.directoryTruncated = directory.truncated;
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loading = false;
    this.refreshing = false;
  }

  private async start(): Promise<void> {
    try {
      if (this.deviceId.length === 0) {
        await this.pickDevice();
      }
      if (this.deviceId.length > 0) {
        await this.loadDirectory(START_PATH);
      }
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
      this.loading = false;
    }
  }

  private openEntry(entry: RemoteDirectoryEntry): void {
    if (entry.type === 'directory') {
      this.loadDirectory(entry.path);
      return;
    }
    if (entry.type === 'file') {
      this.openTextFile(entry);
    }
  }

  private async openTextFile(entry: RemoteDirectoryEntry): Promise<void> {
    this.loadingFile = true;
    this.errorMessage = '';
    try {
      const file: RemoteTextFile = await this.filesApi.readTextFile(this.serverUrl(), this.token(),
        this.deviceId, HOME_ROOT, entry.path);
      this.fileName = file.name;
      this.fileContent = file.content;
      this.fileSizeLabel = formatSize(file.size);
      this.fileTruncated = file.truncated;
      this.fileBinary = file.binary;
      this.viewingFile = true;
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loadingFile = false;
  }

  private goUp(): void {
    if (canGoUp(this.currentPath)) {
      this.loadDirectory(parentPath(this.currentPath));
    }
  }

  private closeViewer(): void {
    this.viewingFile = false;
    this.fileName = '';
    this.fileContent = '';
    this.fileTruncated = false;
    this.fileBinary = false;
  }

  private handleDeviceChange(index: number): void {
    if (index < 0 || index >= this.devices.length) {
      return;
    }
    this.selectedDeviceIndex = index;
    this.deviceId = this.devices[index].id;
    this.entries = [];
    this.currentPath = START_PATH;
    this.viewingFile = false;
    this.loading = true;
    this.start();
  }

  private entryIcon(entry: RemoteDirectoryEntry): string {
    if (entry.type === 'directory') {
      return '📁';
    }
    if (entry.type === 'file') {
      return '📄';
    }
    return '•';
  }

  private entrySubtitle(entry: RemoteDirectoryEntry): string {
    const sizeLabel = formatSize(entry.size);
    if (sizeLabel.length === 0) {
      return entry.type;
    }
    return `${entry.type} · ${sizeLabel}`;
  }

  private emptyStateText(): string {
    return this.loading ? 'Loading files…' : 'This directory is empty.';
  }

  private viewerNotice(): string {
    if (this.fileBinary) {
      return 'Binary file — preview may be unreadable.';
    }
    return 'File is truncated — showing the first part only.';
  }

  private viewerShowNotice(): boolean {
    return this.fileBinary || this.fileTruncated;
  }

  build() {
    NavDestination() {
      Column() {
        if (this.deviceOptions.length > 1) {
          Row({ space: 8 }) {
            Text('Device')
              .fontSize(13)
              .fontColor('#6B7280')
            Select(this.deviceOptions)
              .selected(this.selectedDeviceIndex)
              .value(this.deviceOptions[this.selectedDeviceIndex].value)
              .font({ size: 13 })
              .onSelect((index: number) => {
                this.handleDeviceChange(index);
              })
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4 })
        }
        if (this.viewingFile) {
          Row({ space: 8 }) {
            Button('← Back')
              .fontSize(13)
              .height(32)
              .padding({ left: 12, right: 12 })
              .backgroundColor('#F3F4F6')
              .fontColor('#374151')
              .onClick(() => {
                this.closeViewer();
              })
            Text(this.fileName)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(this.fileSizeLabel)
              .fontSize(12)
              .fontColor('#9CA3AF')
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          if (this.viewerShowNotice()) {
            Text(this.viewerNotice())
              .fontSize(12)
              .fontColor('#D97706')
              .width('100%')
              .padding({ left: 16, right: 16 })
          }
          Scroll(this.scroller) {
            Text(this.fileContent)
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor('#1F2937')
              .textAlign(TextAlign.Start)
              .width('100%')
          }
          .backgroundColor('#F8FAFC')
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .padding(8)
        } else {
          Row({ space: 8 }) {
            Button('↑ Up')
              .fontSize(13)
              .height(32)
              .padding({ left: 12, right: 12 })
              .backgroundColor('#F3F4F6')
              .fontColor('#374151')
              .enabled(canGoUp(this.currentPath))
              .onClick(() => {
                this.goUp();
              })
            Text(this.currentPath)
              .fontSize(13)
              .fontColor('#6B7280')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Button('⟳')
              .fontSize(13)
              .height(32)
              .padding({ left: 10, right: 10 })
              .backgroundColor('#F3F4F6')
              .fontColor('#374151')
              .onClick(() => {
                this.loadDirectory(this.currentPath);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          if (this.directoryTruncated) {
            Text('Directory listing is truncated.')
              .fontSize(12)
              .fontColor('#D97706')
              .width('100%')
              .padding({ left: 16, right: 16 })
          }
          if (this.errorMessage.length > 0) {
            Text(this.errorMessage)
              .fontSize(12)
              .fontColor('#D93025')
              .width('100%')
              .padding({ left: 16, right: 16 })
          }
          if (this.loading) {
            Column() {
              LoadingProgress()
                .width(44)
                .height(44)
            }
            .width('100%')
            .layoutWeight(1)
            .justifyContent(FlexAlign.Center)
          } else {
            Refresh({ refreshing: $$this.refreshing }) {
              List({ space: 4 }) {
                if (this.entries.length === 0) {
                  ListItem() {
                    Text(this.emptyStateText())
                      .fontSize(13)
                      .fontColor('#9CA3AF')
                      .width('100%')
                      .textAlign(TextAlign.Center)
                      .padding({ top: 32, bottom: 32 })
                  }
                }
                ForEach(this.entries, (entry: RemoteDirectoryEntry) => {
                  ListItem() {
                    Row({ space: 10 }) {
                      Text(this.entryIcon(entry))
                        .fontSize(16)
                      Column({ space: 2 }) {
                        Text(entry.name)
                          .fontSize(14)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(this.entrySubtitle(entry))
                          .fontSize(11)
                          .fontColor('#9CA3AF')
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      if (this.loadingFile) {
                        LoadingProgress()
                          .width(16)
                          .height(16)
                      }
                    }
                    .width('100%')
                    .padding(10)
                    .borderRadius(10)
                    .backgroundColor('#F8FAFC')
                    .onClick(() => {
                      this.openEntry(entry);
                    })
                  }
                }, (entry: RemoteDirectoryEntry) => entry.path)
              }
              .width('100%')
              .layoutWeight(1)
              .padding({ left: 16, right: 16, top: 4, bottom: 16 })
            }
            .onRefreshing(() => {
              this.loadDirectory(this.currentPath);
            })
            .width('100%')
            .layoutWeight(1)
          }
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('Files')
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
      const raw = ctx.pathInfo.param as string;
      if (typeof raw === 'string' && raw.length > 0) {
        this.deviceId = raw;
      }
      this.start();
    })
  }
}

@Builder
export function FilesPageBuilder() {
  FilesPage()
}
