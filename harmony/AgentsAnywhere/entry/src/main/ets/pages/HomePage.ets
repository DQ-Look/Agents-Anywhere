import { bundleManager, common, OpenLinkOptions } from '@kit.AbilityKit';
import { ApiClient } from '../api/ApiClient';
import { SessionsApi } from '../api/SessionsApi';
import { RemoteSession, RemoteSessionCreateAndStartRequest } from '../api/SessionDtos';
import { SharedApiClient } from '../api/SharedApiClient';
import { RemoteDevice, RemoteDeviceRuntime, DevicesApi } from '../api/DevicesApi';
import { FilesApi } from '../api/FilesApi';
import { RealtimeApi } from '../api/RealtimeApi';
import { RemoteDashboardSnapshot } from '../api/RealtimeDtos';
import { RealtimeSocketListener, RealtimeWebSocket } from '../api/RealtimeWebSocket';
import { AnnouncementsApi, PublicAnnouncement } from '../api/AnnouncementsApi';
import { AppUpdatesApi, compareUpdateVersions } from '../api/AppUpdatesApi';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { AnnouncementReadStore } from '../auth/AnnouncementReadStore';
import { AppUpdateIgnoreStore } from '../auth/AppUpdateIgnoreStore';
import { ApiException, errorMessageFrom } from '../common/ApiException';
import { MdBlock, parseMarkdownBlocks } from '../common/Markdown';
import {
  availableProjectName,
  workspaceProject,
  workspaceProjectName
} from '../common/WorkspaceProjects';
import { AnnouncementGateOverlay } from '../components/AnnouncementGateOverlay';
import { AppUpdatePromptOverlay } from '../components/AppUpdatePromptOverlay';
import { NewSessionSheetOverlay } from '../components/NewSessionSheetOverlay';
import { SessionActionMenuOverlay } from '../components/SessionActionMenuOverlay';
import { StringInputDialog } from '../components/StringInputDialog';

const RETRY_BASE_DELAY_MS = 1000;
const RETRY_MAX_DELAY_MS = 30000;

// Mirrors Android RealtimeRetry.reconnectDelayMillis: exponential backoff with
// a 30s cap and ±25% jitter.
function dashboardRetryDelayMs(attempt: number): number {
  const safeAttempt = attempt < 0 ? 0 : attempt;
  const exponent = safeAttempt > 5 ? 5 : safeAttempt;
  const base = Math.min(RETRY_BASE_DELAY_MS * (1 << exponent), RETRY_MAX_DELAY_MS);
  const jitter = Math.floor(base * 0.25 * Math.random());
  return Math.min(base + jitter, RETRY_MAX_DELAY_MS);
}

interface SessionListItem {
  id: string;
  title: string;
  runtimeLabel: string;
  statusLabel: string;
  unread: boolean;
  connectorStatus: string;
  pinned: boolean;
  archived: boolean;
}

@Component
export struct HomePage {
  pathStack: NavPathStack = new NavPathStack();
  onSignedOut: () => void = () => {};
  @State sessions: SessionListItem[] = [];
  @State refreshing: boolean = false;
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State announcementVisible: boolean = false;
  @State updateVisible: boolean = false;
  @State updateVersionName: string = '';
  @State newSessionVisible: boolean = false;
  @State devices: RemoteDevice[] = [];
  @State runtimes: RemoteDeviceRuntime[] = [];
  @State runtimesLoading: boolean = false;
  @State selectedDeviceId: string = '';
  @State selectedRuntimeType: string = '';
  @State newSessionCwd: string = '~';
  @State newSessionMessage: string = '';
  @State creatingSession: boolean = false;
  @State newSessionError: string = '';
  @State actionMenuSessionId: string = '';
  @State renameTargetId: string = '';
  @State renameInput: string = '';
  @State actionBusy: boolean = false;
  private announcementBlocks: MdBlock[] = [];
  private announcementMarkdown: string = '';
  private announcementPublishedAt: string = '';
  private updateDownloadUrl: string = '';
  private pageActive: boolean = false;
  private dashboardRetries: number = 0;
  private retryTimer: number = -1;
  private optCounter: number = 0;
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private client: ApiClient = SharedApiClient.getInstance();
  private sessionsApi: SessionsApi = new SessionsApi(this.client);
  private realtimeApi: RealtimeApi = new RealtimeApi(this.client);
  private devicesApi: DevicesApi = new DevicesApi(this.client);
  private filesApi: FilesApi = new FilesApi(this.client);
  private announcementsApi: AnnouncementsApi = new AnnouncementsApi(this.client);
  private updatesApi: AppUpdatesApi = new AppUpdatesApi(this.client);
  private announcementReadStore: AnnouncementReadStore = AnnouncementReadStore.getInstance();
  private updateIgnoreStore: AppUpdateIgnoreStore = AppUpdateIgnoreStore.getInstance();
  private socket: RealtimeWebSocket = new RealtimeWebSocket();

  aboutToAppear(): void {
    this.pageActive = true;
    this.loadSessions();
    this.connectDashboard();
    this.loadAnnouncement();
    this.checkForUpdates();
  }

  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.socket.destroy();
  }

  private serverUrl(): string {
    return this.authStore.readServerUrl();
  }

  private token(): string {
    return this.authStore.readAccessToken();
  }

  private nextClientId(): string {
    this.optCounter++;
    return `hmos_${Date.now().toString(36)}_${this.optCounter}`;
  }

  private toListItem(session: RemoteSession): SessionListItem {
    const title = session.title === null || session.title.length === 0
      ? 'Untitled session' : session.title;
    const item: SessionListItem = {
      id: session.id,
      title: title,
      runtimeLabel: session.runtimeName,
      statusLabel: session.status,
      unread: session.unread,
      connectorStatus: session.connectorStatus,
      pinned: session.pinned,
      archived: session.archived
    };
    return item;
  }

  private applySnapshot(snapshot: RemoteDashboardSnapshot): void {
    const items: SessionListItem[] = [];
    for (const session of snapshot.sessions) {
      if (session.archived) {
        continue;
      }
      items.push(this.toListItem(session));
    }
    this.sessions = items;
    this.loading = false;
    this.refreshing = false;
  }

  private async loadSessions(): Promise<void> {
    try {
      const serverUrl = this.serverUrl();
      const accessToken = this.token();
      if (serverUrl.length === 0 || accessToken.length === 0) {
        this.errorMessage = 'Not signed in.';
        this.loading = false;
        this.refreshing = false;
        return;
      }
      const page = await this.sessionsApi.listSessions(serverUrl, accessToken, false, 50, null);
      if (!this.pageActive) {
        return;
      }
      const items: SessionListItem[] = [];
      for (const session of page.sessions) {
        items.push(this.toListItem(session));
      }
      this.sessions = items;
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loading = false;
    this.refreshing = false;
  }

  private async connectDashboard(): Promise<void> {
    if (!this.pageActive) {
      return;
    }
    try {
      const ticket = await this.realtimeApi.createDashboardTicket(this.serverUrl(), this.token(),
        this.nextClientId());
      if (!this.pageActive) {
        return;
      }
      const url = this.realtimeApi.dashboardWebSocketUrl(this.serverUrl(), ticket.ticket);
      this.socket.connect(url, this.createDashboardListener());
    } catch (error) {
      this.scheduleDashboardRetry();
    }
  }

  private createDashboardListener(): RealtimeSocketListener {
    const listener: RealtimeSocketListener = {
      onOpen: (): void => {
        this.dashboardRetries = 0;
      },
      onMessage: (text: string): void => {
        const snapshot = this.realtimeApi.parseDashboardMessage(text);
        if (snapshot !== null) {
          this.applySnapshot(snapshot);
        }
      },
      onClose: (code: number, reason: string): void => {
        this.scheduleDashboardRetry();
      },
      onError: (message: string): void => {
        this.scheduleDashboardRetry();
      }
    };
    return listener;
  }

  private scheduleDashboardRetry(): void {
    if (!this.pageActive) {
      return;
    }
    if (this.retryTimer >= 0) {
      return;
    }
    const attempt = this.dashboardRetries;
    this.dashboardRetries++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.connectDashboard();
    }, dashboardRetryDelayMs(attempt));
  }

  private async loadAnnouncement(): Promise<void> {
    if (!this.pageActive) {
      return;
    }
    try {
      const announcement = await this.announcementsApi.current(this.serverUrl());
      if (!this.pageActive || announcement === null) {
        return;
      }
      if (!this.announcementReadStore.isUnread(this.serverUrl(), announcement)) {
        return;
      }
      this.announcementMarkdown = announcement.markdown;
      this.announcementPublishedAt = announcement.publishedAt;
      this.announcementBlocks = parseMarkdownBlocks(announcement.markdown);
      this.announcementVisible = true;
    } catch (error) {
    }
  }

  private closeAnnouncement(): void {
    this.announcementVisible = false;
    const announcement: PublicAnnouncement = {
      markdown: this.announcementMarkdown,
      publishedAt: this.announcementPublishedAt
    };
    try {
      this.announcementReadStore.markRead(this.serverUrl(), announcement);
    } catch (error) {
    }
  }

  private currentVersionName(): string {
    try {
      const info = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName;
    } catch (error) {
      return '';
    }
  }

  private async checkForUpdates(): Promise<void> {
    if (!this.pageActive) {
      return;
    }
    const current = this.currentVersionName();
    if (current.length === 0) {
      return;
    }
    try {
      const release = await this.updatesApi.check(this.serverUrl(), current);
      if (!this.pageActive || release === null) {
        return;
      }
      const ignored = this.updateIgnoreStore.readIgnoredVersion(this.serverUrl());
      if (ignored.length > 0 && compareUpdateVersions(ignored, release.versionName) === 0) {
        return;
      }
      this.updateVersionName = release.versionName;
      this.updateDownloadUrl = release.downloadUrl;
      this.updateVisible = true;
    } catch (error) {
    }
  }

  private ignoreUpdate(): void {
    try {
      this.updateIgnoreStore.saveIgnoredVersion(this.serverUrl(), this.updateVersionName);
    } catch (error) {
    }
    this.updateVisible = false;
  }

  private downloadUpdate(): void {
    const url = this.updateDownloadUrl;
    if (url.length === 0) {
      return;
    }
    const options: OpenLinkOptions = { appLinkingOnly: false };
    try {
      const context = getContext(this) as common.UIAbilityContext;
      context.openLink(url, options).catch(() => {
        this.showDownloadFallback(url);
      });
    } catch (error) {
      this.showDownloadFallback(url);
    }
  }

  private showDownloadFallback(url: string): void {
    AlertDialog.show({
      title: 'Cannot open the download page',
      message: `Open this address in your browser: ${url}`,
      primaryButton: {
        value: 'OK',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: '',
        action: (): void => {
        }
      }
    });
  }

  private openSession(sessionId: string): void {
    this.pathStack.pushPathByName('session_detail', sessionId);
  }

  private openDevices(): void {
    this.pathStack.pushPathByName('devices', '');
  }

  private openTerminal(): void {
    this.pathStack.pushPathByName('terminal', '');
  }

  private openFiles(): void {
    this.pathStack.pushPathByName('files', '');
  }

  private openProfile(): void {
    this.pathStack.pushPathByName('profile', '');
  }

  private findSession(sessionId: string): SessionListItem | null {
    for (const item of this.sessions) {
      if (item.id === sessionId) {
        return item;
      }
    }
    return null;
  }

  private replaceSession(next: SessionListItem): void {
    const items: SessionListItem[] = [];
    for (const item of this.sessions) {
      if (item.id === next.id) {
        items.push(next);
      } else {
        items.push(item);
      }
    }
    this.sessions = items;
  }

  private openActionMenu(item: SessionListItem): void {
    this.actionMenuSessionId = item.id;
  }

  private closeActionMenu(): void {
    this.actionMenuSessionId = '';
  }

  private beginRename(): void {
    const target = this.findSession(this.actionMenuSessionId);
    if (target === null) {
      return;
    }
    this.renameInput = target.title;
    this.renameTargetId = target.id;
    this.closeActionMenu();
  }

  private cancelRename(): void {
    this.renameTargetId = '';
    this.renameInput = '';
  }

  private async confirmRename(value: string): Promise<void> {
    const sessionId = this.renameTargetId;
    const title = value.trim();
    if (sessionId.length === 0) {
      return;
    }
    if (title.length === 0) {
      this.errorMessage = 'A session title is required.';
      return;
    }
    const target = this.findSession(sessionId);
    if (target === null) {
      return;
    }
    this.actionBusy = true;
    try {
      const response = await this.sessionsApi.patchSession(this.serverUrl(), this.token(),
        sessionId, title, null, null);
      const next = this.toListItem(response.session);
      this.replaceSession(next);
      this.cancelRename();
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.actionBusy = false;
  }

  private async toggleArchived(): Promise<void> {
    const target = this.findSession(this.actionMenuSessionId);
    if (target === null) {
      return;
    }
    this.closeActionMenu();
    this.actionBusy = true;
    try {
      if (target.archived) {
        const response = await this.sessionsApi.unarchiveSessions(this.serverUrl(), this.token(),
          [target.id]);
        for (const session of response.sessions) {
          this.replaceSession(this.toListItem(session));
        }
      } else {
        await this.sessionsApi.archiveSessions(this.serverUrl(), this.token(), [target.id]);
        const items: SessionListItem[] = [];
        for (const item of this.sessions) {
          if (item.id !== target.id) {
            items.push(item);
          }
        }
        this.sessions = items;
      }
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.actionBusy = false;
  }

  private async togglePinned(): Promise<void> {
    const target = this.findSession(this.actionMenuSessionId);
    if (target === null) {
      return;
    }
    this.closeActionMenu();
    this.actionBusy = true;
    try {
      const response = await this.sessionsApi.patchSession(this.serverUrl(), this.token(),
        target.id, null, !target.pinned, null);
      this.replaceSession(this.toListItem(response.session));
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.actionBusy = false;
  }

  private openNewSession(): void {
    this.selectedDeviceId = '';
    this.selectedRuntimeType = '';
    this.runtimes = [];
    this.runtimesLoading = false;
    this.newSessionCwd = '~';
    this.newSessionMessage = '';
    this.newSessionError = '';
    this.devices = [];
    this.newSessionVisible = true;
    this.loadNewSessionDevices();
  }

  private closeNewSession(): void {
    if (this.creatingSession) {
      return;
    }
    this.newSessionVisible = false;
  }

  private async loadNewSessionDevices(): Promise<void> {
    try {
      const devices = await this.devicesApi.listDevices(this.serverUrl(), this.token());
      if (!this.newSessionVisible) {
        return;
      }
      this.devices = devices;
    } catch (error) {
      this.newSessionError = errorMessageFrom(error as Object);
    }
  }

  private async selectDevice(deviceId: string): Promise<void> {
    if (this.creatingSession) {
      return;
    }
    this.selectedDeviceId = deviceId;
    this.selectedRuntimeType = '';
    this.runtimes = [];
    this.newSessionError = '';
    this.runtimesLoading = true;
    try {
      const list = await this.devicesApi.listDeviceRuntimes(this.serverUrl(), this.token(), deviceId);
      this.runtimes = list.runtimes;
    } catch (error) {
      this.newSessionError = errorMessageFrom(error as Object);
    }
    this.runtimesLoading = false;
  }

  private selectRuntime(runtimeType: string): void {
    if (this.creatingSession) {
      return;
    }
    this.selectedRuntimeType = runtimeType;
  }

  private deviceOsFor(deviceId: string): string | null {
    for (const device of this.devices) {
      if (device.id === deviceId) {
        return device.deviceOs;
      }
    }
    return null;
  }

  private async createSession(): Promise<void> {
    const deviceId = this.selectedDeviceId;
    const runtimeType = this.selectedRuntimeType;
    const content = this.newSessionMessage.trim();
    if (deviceId.length === 0) {
      this.newSessionError = 'Select a device first.';
      return;
    }
    if (runtimeType.length === 0) {
      this.newSessionError = 'Select a runtime first.';
      return;
    }
    if (content.length === 0) {
      this.newSessionError = 'Enter a first message for the session.';
      return;
    }
    this.creatingSession = true;
    this.newSessionError = '';
    try {
      let cwd = this.newSessionCwd.trim();
      if (cwd.length === 0) {
        cwd = '~';
      }
      if (cwd.startsWith('~')) {
        const directory = await this.filesApi.listFiles(this.serverUrl(), this.token(),
          deviceId, cwd, '.');
        if (directory.path.length === 0 || directory.path.startsWith('~')) {
          throw new ApiException('Could not resolve the workspace directory.');
        }
        cwd = directory.path;
      }
      const projects = (await this.sessionsApi.listProjects(this.serverUrl(), this.token())).projects;
      let project = workspaceProject(projects, deviceId, cwd, this.deviceOsFor(deviceId));
      if (project === null) {
        project = await this.sessionsApi.createProject(this.serverUrl(), this.token(),
          availableProjectName(workspaceProjectName(cwd), projects), deviceId, cwd, false);
      }
      const request: RemoteSessionCreateAndStartRequest = {
        connectorId: deviceId,
        projectId: project.id,
        runtime: runtimeType,
        content: content,
        title: null,
        cwd: project.workspacePath,
        clientMessageId: this.nextClientId()
      };
      const response = await this.sessionsApi.createAndStartSession(this.serverUrl(), this.token(),
        request);
      this.newSessionVisible = false;
      this.loadSessions();
      this.pathStack.pushPathByName('session_detail', response.session.id);
    } catch (error) {
      this.newSessionError = errorMessageFrom(error as Object);
    }
    this.creatingSession = false;
  }

  private connectorDotColor(status: string): string {
    if (status === 'online') {
      return '#22C55E';
    }
    return '#9CA3AF';
  }

  @Builder
  navAction(label: string, primary: boolean, action: () => void) {
    Button(label)
      .fontSize(13)
      .fontWeight(primary ? FontWeight.Medium : FontWeight.Normal)
      .fontColor(primary ? Color.White : '#1F2937')
      .backgroundColor(primary ? '#2563EB' : '#F2F3F5')
      .height(34)
      .padding({ left: 14, right: 14 })
      .onClick(() => {
        action();
      })
  }

  build() {
    Stack() {
      Column() {
        Row({ space: 8 }) {
          Text('Sessions')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .layoutWeight(1)
          Button('Profile')
            .fontSize(14)
            .height(36)
            .backgroundColor('#F2F3F5')
            .fontColor('#1F2937')
            .onClick(() => {
              this.openProfile();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })
        Scroll() {
          Row({ space: 8 }) {
            this.navAction('+ New session', true, (): void => {
              this.openNewSession();
            })
            this.navAction('Devices', false, (): void => {
              this.openDevices();
            })
            this.navAction('Terminal', false, (): void => {
              this.openTerminal();
            })
            this.navAction('Files', false, (): void => {
              this.openFiles();
            })
          }
          .padding({ left: 16, right: 16 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .padding({ bottom: 8 })
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(13)
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
            List({ space: 8 }) {
              if (this.sessions.length === 0) {
                ListItem() {
                  Text('No sessions yet. Start one from a connected device.')
                    .fontSize(14)
                    .fontColor('#999999')
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 32, bottom: 32 })
                }
              }
              ForEach(this.sessions, (item: SessionListItem) => {
                ListItem() {
                  Column({ space: 4 }) {
                    Row({ space: 6 }) {
                      if (item.unread) {
                        Circle()
                          .width(8)
                          .height(8)
                          .fill('#2563EB')
                      }
                      Text(item.title)
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      if (item.pinned) {
                        Text('pinned')
                          .fontSize(11)
                          .fontColor('#7C3AED')
                          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                          .borderRadius(8)
                          .backgroundColor('#EDE9FE')
                      }
                      Button('⋯')
                        .fontSize(15)
                        .fontColor('#6B7280')
                        .backgroundColor('#E5E7EB')
                        .width(32)
                        .height(32)
                        .borderRadius(16)
                        .padding(0)
                        .onClick(() => {
                          this.openActionMenu(item);
                        })
                    }
                    .width('100%')
                    Row({ space: 6 }) {
                      Circle()
                        .width(7)
                        .height(7)
                        .fill(this.connectorDotColor(item.connectorStatus))
                      Text(`${item.runtimeLabel} · ${item.statusLabel}`)
                        .fontSize(13)
                        .fontColor('#666666')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                    }
                    .width('100%')
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .padding(12)
                  .borderRadius(12)
                  .backgroundColor('#F2F3F5')
                  .onClick(() => {
                    this.openSession(item.id);
                  })
                  .gesture(
                    LongPressGesture()
                      .onAction(() => {
                        this.openActionMenu(item);
                      })
                  )
                }
              }, (item: SessionListItem) => item.id)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 16, right: 16, top: 8, bottom: 16 })
          }
          .onRefreshing(() => {
            this.loadSessions();
            this.dashboardRetries = 0;
            this.connectDashboard();
          })
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      if (this.announcementVisible) {
        AnnouncementGateOverlay({
          blocks: this.announcementBlocks,
          onClose: (): void => {
            this.closeAnnouncement();
          }
        })
      }
      if (this.updateVisible) {
        AppUpdatePromptOverlay({
          versionName: this.updateVersionName,
          onDownload: (): void => {
            this.downloadUpdate();
          },
          onIgnore: (): void => {
            this.ignoreUpdate();
          }
        })
      }
      if (this.newSessionVisible) {
        NewSessionSheetOverlay({
          devices: this.devices,
          runtimes: this.runtimes,
          runtimesLoading: this.runtimesLoading,
          selectedDeviceId: this.selectedDeviceId,
          selectedRuntimeType: this.selectedRuntimeType,
          cwdInput: this.newSessionCwd,
          messageInput: this.newSessionMessage,
          creating: this.creatingSession,
          errorText: this.newSessionError,
          onDeviceSelected: (deviceId: string): void => {
            this.selectDevice(deviceId);
          },
          onRuntimeSelected: (runtimeType: string): void => {
            this.selectRuntime(runtimeType);
          },
          onCwdChange: (value: string): void => {
            this.newSessionCwd = value;
          },
          onMessageChange: (value: string): void => {
            this.newSessionMessage = value;
          },
          onCreate: (): void => {
            this.createSession();
          },
          onClose: (): void => {
            this.closeNewSession();
          }
        })
      }
      if (this.actionMenuSessionId.length > 0) {
        SessionActionMenuOverlay({
          sessionTitle: this.actionMenuTitle(),
          archived: this.actionMenuArchived(),
          pinned: this.actionMenuPinned(),
          onRename: (): void => {
            this.beginRename();
          },
          onToggleArchived: (): void => {
            this.toggleArchived();
          },
          onTogglePinned: (): void => {
            this.togglePinned();
          },
          onClose: (): void => {
            this.closeActionMenu();
          }
        })
      }
      if (this.renameTargetId.length > 0) {
        StringInputDialog({
          title: 'Rename session',
          initial: this.renameInput,
          placeholder: 'Session title',
          saveLabel: 'Save',
          busy: this.actionBusy,
          onSave: (value: string): void => {
            this.confirmRename(value);
          },
          onCancel: (): void => {
            this.cancelRename();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }

  private actionMenuTitle(): string {
    const target = this.findSession(this.actionMenuSessionId);
    return target === null ? '' : target.title;
  }

  private actionMenuArchived(): boolean {
    const target = this.findSession(this.actionMenuSessionId);
    return target !== null && target.archived;
  }

  private actionMenuPinned(): boolean {
    const target = this.findSession(this.actionMenuSessionId);
    return target !== null && target.pinned;
  }
}
