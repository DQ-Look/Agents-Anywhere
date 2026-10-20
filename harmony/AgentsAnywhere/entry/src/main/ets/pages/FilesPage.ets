import { pasteboard } from '@kit.BasicServicesKit';
import { ApiClient } from '../api/ApiClient';
import { DevicesApi, RemoteDevice } from '../api/DevicesApi';
import { FilesApi, RemoteDirectoryEntry, RemoteTextFile } from '../api/FilesApi';
import { SharedApiClient } from '../api/SharedApiClient';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';
import {
  FilePreviewLine,
  FilePreviewLineDataSource,
  fileContentLines,
  fileEntryKind,
  fileEntrySymbol,
  fileEntrySymbolColor,
  findMatchLineIndexes,
  isWindowsDriveRootPath,
  isWindowsDriveStylePath,
  windowsDriveRootOf,
  windowsParentPath
} from '../common/FileViewSupport';
import { FileRowMenuOverlay } from '../components/FileRowMenuOverlay';
import { StringInputDialog } from '../components/StringInputDialog';
import { APP_IS_DARK_KEY, getColors } from '../designsystem/ColorTokens';
import { showToast } from '../utils/Toast';

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
  @StorageProp(APP_IS_DARK_KEY) themeIsDark: boolean = false;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State errorMessage: string = '';
  @State devices: RemoteDevice[] = [];
  @State deviceOptions: DeviceOption[] = [];
  @State selectedDeviceIndex: number = 0;
  @State deviceId: string = '';
  @State devicesEmpty: boolean = false;
  @State selectedDeviceOffline: boolean = false;
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
  @State fileRoot: string = HOME_ROOT;
  @State customRoot: string = '';
  @State showRootDialog: boolean = false;
  @State rootInputText: string = '';
  @State searchOpen: boolean = false;
  @State searchQuery: string = '';
  @State searchTotal: number = 0;
  @State searchCurrentOrdinal: number = 0;
  @State copiedContent: boolean = false;
  @State rowMenuOpen: boolean = false;
  @State rowMenuEntryName: string = '';
  private rowMenuEntryPath: string = '';
  private searchMatchLines: number[] = [];
  private searchCurrentIndex: number = 0;
  private copiedContentTimer: number = -1;
  private rawLines: string[] = [];
  private previewLines: FilePreviewLineDataSource = new FilePreviewLineDataSource();
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
      this.devicesEmpty = true;
      this.selectedDeviceOffline = false;
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
    this.devicesEmpty = false;
    this.selectedDeviceOffline = devices[selectedIndex].status !== 'online';
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
    let requestPath = path;
    let requestRoot = this.fileRoot;
    if (isWindowsDriveStylePath(requestPath)) {
      if (requestPath.length === 2) {
        requestPath = `${requestPath}\\`;
      }
      requestRoot = windowsDriveRootOf(requestPath);
    }
    try {
      const directory = await this.filesApi.listFiles(this.serverUrl(), this.token(), this.deviceId,
        requestRoot, requestPath);
      this.entries = this.sortEntries(directory.entries);
      this.currentPath = directory.path.length > 0 ? directory.path : requestPath;
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
      if (this.deviceId.length > 0 && !this.selectedDeviceOffline) {
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
        this.deviceId, this.fileRoot, entry.path);
      this.fileName = file.name;
      this.fileContent = file.content;
      this.fileSizeLabel = formatSize(file.size);
      this.fileTruncated = file.truncated;
      this.fileBinary = file.binary;
      this.resetSearch();
      this.rawLines = fileContentLines(file.content);
      this.rebuildPreviewLines();
      this.viewingFile = true;
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loadingFile = false;
  }

  private goUp(): void {
    if (!canGoUp(this.currentPath)) {
      return;
    }
    if (isWindowsDriveRootPath(this.currentPath)) {
      this.loadDirectory('');
      return;
    }
    if (isWindowsDriveStylePath(this.currentPath)) {
      this.loadDirectory(windowsParentPath(this.currentPath));
      return;
    }
    this.loadDirectory(parentPath(this.currentPath));
  }

  private changeRoot(root: string): void {
    if (root === 'custom') {
      this.openRootDialog();
      return;
    }
    this.fileRoot = root;
    this.currentPath = START_PATH;
    this.loadDirectory(START_PATH);
  }

  private openRootDialog(): void {
    this.rootInputText = this.customRoot.length > 0 ? this.customRoot : '/';
    this.showRootDialog = true;
  }

  private confirmRootDialog(value: string): void {
    const trimmed = value.trim();
    this.showRootDialog = false;
    if (trimmed.length === 0) {
      return;
    }
    this.customRoot = trimmed;
    this.fileRoot = trimmed;
    this.currentPath = START_PATH;
    this.loadDirectory(START_PATH);
  }

  private cancelRootDialog(): void {
    this.showRootDialog = false;
  }

  private closeViewer(): void {
    this.viewingFile = false;
    this.fileName = '';
    this.fileContent = '';
    this.fileTruncated = false;
    this.fileBinary = false;
    this.resetSearch();
  }

  private handleDeviceChange(index: number): void {
    if (index < 0 || index >= this.devices.length) {
      return;
    }
    this.selectedDeviceIndex = index;
    this.deviceId = this.devices[index].id;
    this.selectedDeviceOffline = this.devices[index].status !== 'online';
    this.entries = [];
    this.currentPath = START_PATH;
    this.viewingFile = false;
    this.loading = true;
    this.start();
  }

  private entryKindOf(entry: RemoteDirectoryEntry): string {
    return fileEntryKind(entry.name, entry.type === 'directory');
  }

  private entrySymbol(entry: RemoteDirectoryEntry): Resource {
    return fileEntrySymbol(this.entryKindOf(entry));
  }

  private entrySymbolColor(entry: RemoteDirectoryEntry): string {
    return fileEntrySymbolColor(this.entryKindOf(entry));
  }

  private entrySubtitle(entry: RemoteDirectoryEntry): string {
    const sizeLabel = formatSize(entry.size);
    if (sizeLabel.length === 0) {
      return entry.type;
    }
    return `${entry.type} · ${sizeLabel}`;
  }

  private emptyStateText(): ResourceStr {
    return this.loading ? $r('app.string.files_loading') : $r('app.string.files_empty_directory');
  }

  private displayPath(): ResourceStr {
    if (this.currentPath.length === 0) {
      return $r('app.string.files_windows_drives');
    }
    return this.currentPath;
  }

  private allDevicesOffline(): boolean {
    for (const device of this.devices) {
      if (device.status === 'online') {
        return false;
      }
    }
    return true;
  }

  private offlineMessage(): ResourceStr {
    return this.allDevicesOffline() ? $r('app.string.files_all_devices_offline')
      : $r('app.string.files_device_offline');
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

  private openPairing(): void {
    this.navPathStack.pushPathByName('devices', '');
  }

  // --- In-file search ---

  private resetSearch(): void {
    this.searchOpen = false;
    this.searchQuery = '';
    this.searchMatchLines = [];
    this.searchCurrentIndex = 0;
    this.searchTotal = 0;
    this.searchCurrentOrdinal = 0;
  }

  private currentMatchLine(): number {
    if (this.searchCurrentIndex < this.searchMatchLines.length) {
      return this.searchMatchLines[this.searchCurrentIndex];
    }
    return -1;
  }

  private rebuildPreviewLines(): void {
    const lines: FilePreviewLine[] = [];
    const matchLines = this.searchMatchLines;
    const currentLine = this.currentMatchLine();
    let matchPointer = 0;
    for (let i = 0; i < this.rawLines.length; i++) {
      const line = new FilePreviewLine();
      line.text = this.rawLines[i];
      line.lineIndex = i;
      while (matchPointer < matchLines.length && matchLines[matchPointer] < i) {
        matchPointer++;
      }
      line.isMatch = matchPointer < matchLines.length && matchLines[matchPointer] === i;
      line.isCurrent = line.isMatch && i === currentLine;
      lines.push(line);
    }
    this.previewLines.reload(lines);
  }

  private applySearch(): void {
    this.searchMatchLines = findMatchLineIndexes(this.rawLines, this.searchQuery);
    this.searchTotal = this.searchMatchLines.length;
    if (this.searchMatchLines.length === 0) {
      this.searchCurrentIndex = 0;
      this.searchCurrentOrdinal = 0;
    } else {
      if (this.searchCurrentIndex >= this.searchMatchLines.length) {
        this.searchCurrentIndex = 0;
      }
      this.searchCurrentOrdinal = this.searchCurrentIndex + 1;
    }
    this.rebuildPreviewLines();
    this.scrollToCurrentMatch();
  }

  private toggleSearch(): void {
    if (this.searchOpen) {
      this.searchMatchLines = [];
      this.searchCurrentIndex = 0;
      this.searchTotal = 0;
      this.searchCurrentOrdinal = 0;
      this.searchOpen = false;
      this.rebuildPreviewLines();
      return;
    }
    this.searchOpen = true;
    this.searchCurrentIndex = 0;
    this.applySearch();
  }

  private stepSearch(delta: number): void {
    if (this.searchMatchLines.length === 0) {
      return;
    }
    const previousLine = this.currentMatchLine();
    this.searchCurrentIndex = (this.searchCurrentIndex + delta + this.searchMatchLines.length)
      % this.searchMatchLines.length;
    this.searchCurrentOrdinal = this.searchCurrentIndex + 1;
    const nextLine = this.currentMatchLine();
    if (previousLine !== nextLine) {
      this.previewLines.setCurrent(previousLine, nextLine);
    }
    this.scrollToCurrentMatch();
  }

  private scrollToCurrentMatch(): void {
    const line = this.currentMatchLine();
    if (line >= 0) {
      this.scroller.scrollToIndex(line, true);
    }
  }

  // --- Clipboard ---

  private copyFileContent(): void {
    try {
      const board = pasteboard.getSystemPasteboard();
      const data = pasteboard.createPlainTextData(this.fileContent);
      board.setDataSync(data);
      this.copiedContent = true;
      if (this.copiedContentTimer >= 0) {
        clearTimeout(this.copiedContentTimer);
      }
      this.copiedContentTimer = setTimeout(() => {
        this.copiedContentTimer = -1;
        this.copiedContent = false;
      }, 2000);
    } catch (error) {
      showToast(errorMessageFrom(error as Object));
    }
  }

  private copyEntryPath(path: string): void {
    this.closeRowMenu();
    try {
      const board = pasteboard.getSystemPasteboard();
      const data = pasteboard.createPlainTextData(path);
      board.setDataSync(data);
      showToast($r('app.string.files_copied_path'));
    } catch (error) {
      showToast(errorMessageFrom(error as Object));
    }
  }

  // --- Long-press row menu ---

  private openRowMenu(entry: RemoteDirectoryEntry): void {
    this.rowMenuEntryName = entry.name;
    this.rowMenuEntryPath = entry.path;
    this.rowMenuOpen = true;
  }

  private closeRowMenu(): void {
    this.rowMenuOpen = false;
    this.rowMenuEntryName = '';
    this.rowMenuEntryPath = '';
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          if (this.deviceOptions.length > 1) {
            Row({ space: 8 }) {
              Text($r('app.string.files_device'))
                .fontSize(13)
                .fontColor(getColors().muted)
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
              Button($r('app.string.files_back'))
                .fontSize(13)
                .height(32)
                .padding({ left: 12, right: 12 })
                .backgroundColor(getColors().raisedSurface)
                .fontColor(getColors().inkSoft)
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
                .fontColor(getColors().faint)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
            Row({ space: 8 }) {
              Button() {
                SymbolGlyph($r('sys.symbol.magnifyingglass'))
                  .fontSize(16)
                  .fontColor([getColors().inkSoft])
              }
              .fontSize(13)
              .height(32)
              .width(38)
              .padding(0)
              .backgroundColor(this.searchOpen ? getColors().accentPurpleSurface : getColors().raisedSurface)
              .onClick(() => {
                this.toggleSearch();
              })
              Button(this.copiedContent ? $r('app.string.files_copied_content')
                : $r('app.string.files_copy_content'))
                .fontSize(13)
                .height(32)
                .padding({ left: 12, right: 12 })
                .backgroundColor(getColors().raisedSurface)
                .fontColor(this.copiedContent ? getColors().noticeSuccess : getColors().inkSoft)
                .enabled(!this.fileBinary)
                .onClick(() => {
                  this.copyFileContent();
                })
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 2, bottom: 4 })
            if (this.searchOpen) {
              Row({ space: 8 }) {
                TextInput({ text: this.searchQuery, placeholder: $r('app.string.files_search') })
                  .fontSize(13)
                  .height(32)
                  .layoutWeight(1)
                  .backgroundColor(getColors().matchedAccountSurface)
                  .enterKeyType(EnterKeyType.Search)
                  .onChange((value: string) => {
                    this.searchQuery = value;
                    this.applySearch();
                  })
                  .onSubmit(() => {
                    this.stepSearch(1);
                  })
                Text(`${this.searchCurrentOrdinal}/${this.searchTotal}`)
                  .fontSize(11)
                  .fontColor(getColors().muted)
                Button('↑')
                  .fontSize(13)
                  .height(32)
                  .width(32)
                  .padding(0)
                  .backgroundColor(getColors().raisedSurface)
                  .fontColor(getColors().inkSoft)
                  .enabled(this.searchTotal > 0)
                  .onClick(() => {
                    this.stepSearch(-1);
                  })
                Button('↓')
                  .fontSize(13)
                  .height(32)
                  .width(32)
                  .padding(0)
                  .backgroundColor(getColors().raisedSurface)
                  .fontColor(getColors().inkSoft)
                  .enabled(this.searchTotal > 0)
                  .onClick(() => {
                    this.stepSearch(1);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 2, bottom: 4 })
            }
            if (this.viewerShowNotice()) {
              Text(this.viewerNotice())
                .fontSize(12)
                .fontColor(getColors().noticeWarning)
                .width('100%')
                .padding({ left: 16, right: 16 })
            }
            List({ scroller: this.scroller }) {
              LazyForEach(this.previewLines, (line: FilePreviewLine) => {
                ListItem() {
                  Text(line.text.length > 0 ? line.text : ' ')
                    .fontSize(12)
                    .fontFamily('monospace')
                    .fontColor(getColors().ink)
                    .width('100%')
                    .backgroundColor(line.isCurrent ? getColors().accentPurpleSurface
                      : line.isMatch ? getColors().accentSurface : Color.Transparent)
                }
              }, (line: FilePreviewLine) => `${line.lineIndex}_${line.text.length}_${line.isMatch ? 1 : 0}`)
            }
            .backgroundColor(getColors().matchedAccountSurface)
            .width('100%')
            .layoutWeight(1)
            .padding(8)
            .cachedCount(6)
          } else {
            if (this.devicesEmpty || this.selectedDeviceOffline) {
              Column({ space: 12 }) {
                if (this.devicesEmpty) {
                  Text($r('app.string.files_pair_first'))
                    .fontSize(14)
                    .fontColor(getColors().muted)
                    .textAlign(TextAlign.Center)
                  Button($r('app.string.devices_pair'))
                    .fontSize(14)
                    .height(38)
                    .padding({ left: 18, right: 18 })
                    .backgroundColor(getColors().primaryAction)
                    .fontColor(getColors().onPrimaryAction)
                    .onClick(() => {
                      this.openPairing();
                    })
                } else {
                  Text(this.offlineMessage())
                    .fontSize(14)
                    .fontColor(getColors().muted)
                    .textAlign(TextAlign.Center)
                    .padding({ left: 32, right: 32 })
                }
              }
              .width('100%')
              .layoutWeight(1)
              .justifyContent(FlexAlign.Center)
            } else {
              Row({ space: 8 }) {
                Button('Home (~)')
                  .fontSize(13)
                  .height(32)
                  .padding({ left: 12, right: 12 })
                  .backgroundColor(this.fileRoot === HOME_ROOT ? getColors().accentPurpleSurface : getColors().raisedSurface)
                  .fontColor(this.fileRoot === HOME_ROOT ? getColors().accentPurple : getColors().inkSoft)
                  .onClick(() => {
                    this.changeRoot(HOME_ROOT);
                  })
                Button('/')
                  .fontSize(13)
                  .height(32)
                  .padding({ left: 12, right: 12 })
                  .backgroundColor(this.fileRoot === '/' ? getColors().accentPurpleSurface : getColors().raisedSurface)
                  .fontColor(this.fileRoot === '/' ? getColors().accentPurple : getColors().inkSoft)
                  .onClick(() => {
                    this.changeRoot('/');
                  })
                Button('Custom')
                  .fontSize(13)
                  .height(32)
                  .padding({ left: 12, right: 12 })
                  .backgroundColor(this.fileRoot !== HOME_ROOT && this.fileRoot !== '/' ? getColors().accentPurpleSurface : getColors().raisedSurface)
                  .fontColor(this.fileRoot !== HOME_ROOT && this.fileRoot !== '/' ? getColors().accentPurple : getColors().inkSoft)
                  .onClick(() => {
                    this.changeRoot('custom');
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 4 })
              Row({ space: 8 }) {
                Button($r('app.string.files_up'))
                  .fontSize(13)
                  .height(32)
                  .padding({ left: 12, right: 12 })
                  .backgroundColor(getColors().raisedSurface)
                  .fontColor(getColors().inkSoft)
                  .enabled(canGoUp(this.currentPath))
                  .onClick(() => {
                    this.goUp();
                  })
                Text(this.displayPath())
                  .fontSize(13)
                  .fontColor(getColors().muted)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Button('⟳')
                  .fontSize(13)
                  .height(32)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor(getColors().raisedSurface)
                  .fontColor(getColors().inkSoft)
                  .onClick(() => {
                    this.loadDirectory(this.currentPath);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              if (this.directoryTruncated) {
                Text($r('app.string.files_truncated'))
                  .fontSize(12)
                  .fontColor(getColors().noticeWarning)
                  .width('100%')
                  .padding({ left: 16, right: 16 })
              }
              if (this.errorMessage.length > 0) {
                Text(this.errorMessage)
                  .fontSize(12)
                  .fontColor(getColors().errorText)
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
                          .fontColor(getColors().faint)
                          .width('100%')
                          .textAlign(TextAlign.Center)
                          .padding({ top: 32, bottom: 32 })
                      }
                    }
                    ForEach(this.entries, (entry: RemoteDirectoryEntry) => {
                      ListItem() {
                        Row({ space: 10 }) {
                          SymbolGlyph(this.entrySymbol(entry))
                            .fontSize(20)
                            .fontColor([this.entrySymbolColor(entry)])
                          Column({ space: 2 }) {
                            Text(entry.name)
                              .fontSize(14)
                              .maxLines(1)
                              .textOverflow({ overflow: TextOverflow.Ellipsis })
                            Text(this.entrySubtitle(entry))
                              .fontSize(11)
                              .fontColor(getColors().faint)
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
                        .backgroundColor(getColors().matchedAccountSurface)
                        .onClick(() => {
                          this.openEntry(entry);
                        })
                        .gesture(
                          LongPressGesture()
                            .onAction(() => {
                              this.openRowMenu(entry);
                            })
                        )
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
        }
        .width('100%')
        .height('100%')

        if (this.rowMenuOpen) {
          FileRowMenuOverlay({
            entryName: this.rowMenuEntryName,
            onCopyPath: (): void => {
              this.copyEntryPath(this.rowMenuEntryPath);
            },
            onClose: (): void => {
              this.closeRowMenu();
            }
          })
        }

        if (this.showRootDialog) {
          StringInputDialog({
            title: 'Custom root path',
            initial: this.rootInputText,
            placeholder: 'Enter an absolute path, e.g. /data/local/tmp',
            saveLabel: 'Go',
            onSave: (value: string): void => {
              this.confirmRootDialog(value);
            },
            onCancel: (): void => {
              this.cancelRootDialog();
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .title($r('app.string.files_title'))
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
