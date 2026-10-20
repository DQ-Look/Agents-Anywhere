import { ApiClient } from '../api/ApiClient';
import { DevicesApi, RemoteDevice, RemoteDeviceRuntime } from '../api/DevicesApi';
import { SessionsApi } from '../api/SessionsApi';
import { SharedApiClient } from '../api/SharedApiClient';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';
import { APP_IS_DARK_KEY, getColors } from '../designsystem/ColorTokens';
import { ConfirmDialog } from '../components/ConfirmDialog';
import { RuntimeConfigureSheetOverlay } from '../components/RuntimeConfigureSheetOverlay';
import { showToast } from '../utils/Toast';

@Component
export struct DevicesPage {
  @StorageProp(APP_IS_DARK_KEY) themeIsDark: boolean = false;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State errorMessage: string = '';
  @State devices: RemoteDevice[] = [];
  @State expandedId: string = '';
  @State runtimesLoading: boolean = false;
  @State runtimes: RemoteDeviceRuntime[] = [];
  @State runtimesError: string = '';
  @State renameTargetId: string = '';
  @State renameInput: string = '';
  @State busy: boolean = false;
  // Runtime management (discover / configure / activate / delete), mirrors
  // android DeviceRuntimeManagementState's pendingRuntimeId + discovering.
  @State runtimeBusyId: string = '';
  @State discovering: boolean = false;
  @State configureTarget: RemoteDeviceRuntime | null = null;
  @State configureSaving: boolean = false;
  @State configureError: string = '';
  private navPathStack: NavPathStack = new NavPathStack();
  private runtimesRequestSeq: number = 0;
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private client: ApiClient = SharedApiClient.getInstance();
  private devicesApi: DevicesApi = new DevicesApi(this.client);
  private sessionsApi: SessionsApi = new SessionsApi(this.client);
  private pendingDeleteDevice: RemoteDevice | null = null;
  private confirmDeleteDialog: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      title: $r('app.string.devices_delete_title'),
      message: `Delete "${this.pendingDeleteDevice?.name ?? ''}"? Its connector token will stop working.`,
      confirmText: $r('app.string.devices_delete_confirm'),
      cancelText: $r('app.string.devices_delete_cancel'),
      confirmIsDanger: true,
      onConfirm: (): void => {
        if (this.pendingDeleteDevice !== null) {
          this.deleteDevice(this.pendingDeleteDevice.id);
        }
        this.confirmDeleteDialog.close();
      },
      onCancel: (): void => {
        this.confirmDeleteDialog.close();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });
  // "Archive all sessions" confirmation: which device is about to have all of
  // its sessions archived (scope "all", mirrors Android DeviceDetailScreen).
  private pendingArchiveDevice: RemoteDevice | null = null;
  private confirmArchiveAllDialog: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      title: $r('app.string.devices_archive_all_title'),
      message: $r('app.string.devices_archive_all_body', this.pendingArchiveDevice?.name ?? ''),
      confirmText: $r('app.string.devices_archive_all_confirm'),
      cancelText: $r('app.string.devices_delete_cancel'),
      confirmIsDanger: false,
      onConfirm: (): void => {
        if (this.pendingArchiveDevice !== null) {
          this.archiveAllDeviceSessions(this.pendingArchiveDevice);
        }
        this.confirmArchiveAllDialog.close();
      },
      onCancel: (): void => {
        this.confirmArchiveAllDialog.close();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });
  // "Delete runtime configuration" confirmation: which configured runtime is
  // about to be removed (scope mirrors Android DeviceConfirmAction.DeleteRuntimeConfig).
  private pendingDeleteRuntime: RemoteDeviceRuntime | null = null;
  private confirmDeleteRuntimeDialog: CustomDialogController = new CustomDialogController({
    builder: ConfirmDialog({
      title: $r('app.string.devices_runtime_delete_title', this.pendingDeleteRuntime?.displayName ?? ''),
      message: this.pendingDeleteRuntime !== null && this.pendingDeleteRuntime.active
        ? $r('app.string.devices_runtime_delete_active_body', this.pendingDeleteRuntime?.displayName ?? '')
        : $r('app.string.devices_runtime_delete_body', this.pendingDeleteRuntime?.displayName ?? ''),
      confirmText: $r('app.string.devices_runtime_delete_confirm'),
      cancelText: $r('app.string.devices_delete_cancel'),
      confirmIsDanger: true,
      onConfirm: (): void => {
        if (this.pendingDeleteRuntime !== null) {
          this.deleteRuntime(this.pendingDeleteRuntime);
        }
        this.confirmDeleteRuntimeDialog.close();
      },
      onCancel: (): void => {
        this.confirmDeleteRuntimeDialog.close();
      }
    }),
    autoCancel: true,
    alignment: DialogAlignment.Center
  });

  private serverUrl(): string {
    return this.authStore.readServerUrl();
  }

  private token(): string {
    return this.authStore.readAccessToken();
  }

  private async loadDevices(): Promise<void> {
    try {
      this.devices = await this.devicesApi.listDevices(this.serverUrl(), this.token());
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loading = false;
    this.refreshing = false;
  }

  private async toggleExpanded(deviceId: string): Promise<void> {
    this.runtimesRequestSeq++;
    if (this.expandedId === deviceId) {
      this.expandedId = '';
      this.runtimes = [];
      this.runtimesError = '';
      this.runtimesLoading = false;
      return;
    }
    this.expandedId = deviceId;
    this.renameTargetId = '';
    this.runtimes = [];
    this.runtimesError = '';
    this.runtimesLoading = true;
    const requestSeq = this.runtimesRequestSeq;
    try {
      const list = await this.devicesApi.listDeviceRuntimes(this.serverUrl(), this.token(), deviceId);
      if (this.runtimesRequestSeq !== requestSeq) {
        return;
      }
      this.runtimes = list.runtimes;
      this.runtimesLoading = false;
    } catch (error) {
      if (this.runtimesRequestSeq !== requestSeq) {
        return;
      }
      this.runtimesError = errorMessageFrom(error as Object);
      this.runtimesLoading = false;
    }
  }

  private beginRename(device: RemoteDevice): void {
    this.renameTargetId = device.id;
    this.renameInput = device.name;
  }

  private async confirmRename(): Promise<void> {
    const deviceId = this.renameTargetId;
    const name = this.renameInput.trim();
    if (deviceId.length === 0 || name.length === 0) {
      return;
    }
    this.busy = true;
    try {
      const updated = await this.devicesApi.updateDevice(this.serverUrl(), this.token(), deviceId, name);
      const next: RemoteDevice[] = [];
      for (const device of this.devices) {
        if (device.id === deviceId) {
          next.push(updated);
        } else {
          next.push(device);
        }
      }
      this.devices = next;
      this.renameTargetId = '';
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.busy = false;
  }

  private cancelRename(): void {
    this.renameTargetId = '';
    this.renameInput = '';
  }

  private requestDelete(device: RemoteDevice): void {
    this.pendingDeleteDevice = device;
    this.confirmDeleteDialog.open();
  }

  private async deleteDevice(deviceId: string): Promise<void> {
    this.busy = true;
    try {
      await this.devicesApi.deleteDevice(this.serverUrl(), this.token(), deviceId);
      const next: RemoteDevice[] = [];
      for (const device of this.devices) {
        if (device.id !== deviceId) {
          next.push(device);
        }
      }
      this.devices = next;
      if (this.expandedId === deviceId) {
        this.expandedId = '';
        this.runtimes = [];
      }
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.busy = false;
  }

  // --- Archive all sessions on a device ------------------------------------

  private requestArchiveAll(device: RemoteDevice): void {
    this.pendingArchiveDevice = device;
    this.confirmArchiveAllDialog.open();
  }

  private async archiveAllDeviceSessions(device: RemoteDevice): Promise<void> {
    this.busy = true;
    try {
      const sessions = await this.sessionsApi.archiveAllDeviceSessions(this.serverUrl(), this.token(),
        device.id, true, 'all');
      this.errorMessage = '';
      showToast($r('app.string.devices_archive_all_toast', sessions.length));
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
      showToast($r('app.string.devices_archive_all_failed'));
    }
    this.pendingArchiveDevice = null;
    this.busy = false;
  }

  // --- Runtime management: discover / activate / configure / delete ---------

  private async reloadRuntimes(deviceId: string): Promise<void> {
    if (this.expandedId !== deviceId) {
      return;
    }
    this.runtimesRequestSeq++;
    const requestSeq = this.runtimesRequestSeq;
    try {
      const list = await this.devicesApi.listDeviceRuntimes(this.serverUrl(), this.token(), deviceId);
      if (this.runtimesRequestSeq !== requestSeq) {
        return;
      }
      this.runtimes = list.runtimes;
      this.runtimesError = '';
      this.runtimesLoading = false;
    } catch (error) {
      if (this.runtimesRequestSeq !== requestSeq) {
        return;
      }
      this.runtimesError = errorMessageFrom(error as Object);
      this.runtimesLoading = false;
    }
  }

  // "Add runtime" entry: ask the connector to rescan, then list every
  // available (present, possibly unconfigured) runtime in the expanded row.
  private async discoverRuntimes(deviceId: string): Promise<void> {
    if (this.discovering) {
      return;
    }
    this.discovering = true;
    this.runtimesRequestSeq++;
    const requestSeq = this.runtimesRequestSeq;
    try {
      const list = await this.devicesApi.discoverDeviceRuntimes(this.serverUrl(), this.token(), deviceId);
      if (this.runtimesRequestSeq === requestSeq) {
        this.runtimes = list.runtimes;
        this.runtimesError = '';
        this.runtimesLoading = false;
        showToast($r('app.string.devices_runtime_discover_done', list.runtimes.length));
      }
    } catch (error) {
      if (this.runtimesRequestSeq === requestSeq) {
        this.runtimesError = errorMessageFrom(error as Object);
        this.runtimesLoading = false;
      }
    }
    this.discovering = false;
  }

  private async toggleRuntimeActive(runtime: RemoteDeviceRuntime): Promise<void> {
    if (this.runtimeBusyId.length > 0) {
      return;
    }
    this.runtimeBusyId = runtime.runtimeId;
    try {
      await this.devicesApi.setDeviceRuntimeActive(this.serverUrl(), this.token(),
        runtime.connectorId, runtime.runtimeId, !runtime.active);
      await this.reloadRuntimes(runtime.connectorId);
    } catch (error) {
      showToast($r('app.string.devices_runtime_update_failed'));
    }
    this.runtimeBusyId = '';
  }

  private openConfigure(runtime: RemoteDeviceRuntime): void {
    this.configureError = '';
    this.configureSaving = false;
    this.configureTarget = runtime;
  }

  private closeConfigure(): void {
    if (this.configureSaving) {
      return;
    }
    this.configureTarget = null;
    this.configureError = '';
  }

  private async saveRuntimeConfig(config: Record<string, Object>): Promise<void> {
    const target = this.configureTarget;
    if (target === null || this.configureSaving) {
      return;
    }
    this.configureSaving = true;
    this.configureError = '';
    try {
      await this.devicesApi.putDeviceRuntimeConfig(this.serverUrl(), this.token(),
        target.connectorId, target.runtimeId, config);
      this.configureTarget = null;
      showToast($r('app.string.devices_runtime_config_saved'));
      await this.reloadRuntimes(target.connectorId);
    } catch (error) {
      this.configureError = errorMessageFrom(error as Object);
    }
    this.configureSaving = false;
  }

  private requestDeleteRuntime(runtime: RemoteDeviceRuntime): void {
    this.pendingDeleteRuntime = runtime;
    this.confirmDeleteRuntimeDialog.open();
  }

  private async deleteRuntime(runtime: RemoteDeviceRuntime): Promise<void> {
    if (this.runtimeBusyId.length > 0) {
      return;
    }
    this.runtimeBusyId = runtime.runtimeId;
    try {
      await this.devicesApi.deleteDeviceRuntimeConfig(this.serverUrl(), this.token(),
        runtime.connectorId, runtime.runtimeId);
      await this.reloadRuntimes(runtime.connectorId);
    } catch (error) {
      showToast($r('app.string.devices_runtime_delete_failed'));
    }
    this.pendingDeleteRuntime = null;
    this.runtimeBusyId = '';
  }

  private openPairing(): void {
    this.navPathStack.pushPathByName('pairing', '');
  }

  private refreshAfterPairing(): void {
    this.expandedId = '';
    this.runtimes = [];
    this.errorMessage = '';
    this.loadDevices();
  }

  private statusColor(status: string): string {
    if (status === 'online') {
      return getColors().runtimeRunning;
    }
    return getColors().muted;
  }

  private formatTimestamp(value: string | null): string {
    if (value === null || value.length < 16) {
      return 'unknown';
    }
    return value.substring(0, 16).replace('T', ' ');
  }

  @Builder
  runtimeRow(runtime: RemoteDeviceRuntime) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text(runtime.displayName)
            .fontSize(16.5)
            .fontWeight(FontWeight.Bold)
            .fontColor(getColors().ink)
          Text(`${runtime.runtimeType} · ${runtime.status}`)
            .fontSize(11.5)
            .fontWeight(FontWeight.Medium)
            .fontColor(getColors().muted)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        if (this.runtimeBusyId === runtime.runtimeId) {
          LoadingProgress()
            .width(14)
            .height(14)
        } else if (runtime.active) {
          Text($r('app.string.devices_status_active'))
            .fontSize(11)
            .fontColor(getColors().primaryAction)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor(getColors().accentSurface)
        } else if (runtime.present) {
          Text($r('app.string.devices_status_present'))
            .fontSize(11)
            .fontColor(getColors().sessionStatusAccent)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor(getColors().successSurface)
        } else {
          Text($r('app.string.devices_status_absent'))
            .fontSize(11)
            .fontColor(getColors().muted)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .borderRadius(8)
            .backgroundColor(getColors().sessionCodeSurface)
        }
      }
      .width('100%')
      if (runtime.configured) {
        Row({ space: 6 }) {
          Button(runtime.active ? $r('app.string.devices_runtime_deactivate') :
            $r('app.string.devices_runtime_activate'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .height(34)
            .borderRadius(6)
            .backgroundColor(getColors().subtle)
            .fontColor(getColors().ink)
            .enabled(this.runtimeBusyId.length === 0 &&
              (runtime.active || (runtime.present && runtime.configured)))
            .onClick(() => {
              this.toggleRuntimeActive(runtime);
            })
          Button($r('app.string.devices_runtime_configure'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .height(34)
            .borderRadius(6)
            .backgroundColor(getColors().subtle)
            .fontColor(getColors().ink)
            .enabled(this.runtimeBusyId.length === 0)
            .onClick(() => {
              this.openConfigure(runtime);
            })
          Button($r('app.string.devices_runtime_delete'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .height(34)
            .borderRadius(6)
            .backgroundColor(getColors().errorSurface)
            .fontColor(getColors().errorText)
            .enabled(this.runtimeBusyId.length === 0)
            .onClick(() => {
              this.requestDeleteRuntime(runtime);
            })
        }
        .width('100%')
      } else if (runtime.present) {
        Row({ space: 6 }) {
          Button($r('app.string.devices_runtime_configure'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .height(34)
            .borderRadius(6)
            .backgroundColor(getColors().subtle)
            .fontColor(getColors().ink)
            .enabled(this.runtimeBusyId.length === 0)
            .onClick(() => {
              this.openConfigure(runtime);
            })
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  build() {
    NavDestination() {
      Stack() {
        Column() {
          if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(13.5)
            .fontWeight(FontWeight.Medium)
            .lineHeight(17)
            .fontColor(getColors().errorText)
            .width('100%')
            .padding({ left: 16, right: 16, top: 4, bottom: 4 })
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
            List({ space: 10 }) {
              if (this.devices.length === 0) {
                ListItem() {
                  Text($r('app.string.devices_no_devices'))
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .lineHeight(21.5)
                    .fontColor(getColors().inkSoft)
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 32, bottom: 32 })
                }
              }
              ForEach(this.devices, (device: RemoteDevice) => {
                ListItem() {
                  Column({ space: 8 }) {
                    Row({ space: 8 }) {
                      Circle()
                        .width(10)
                        .height(10)
                        .fill(this.statusColor(device.status))
                      Text(device.name)
                        .fontSize(17)
                        .fontWeight(600)
                        .lineHeight(21)
                        .fontColor(getColors().inkSoft)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(device.status)
                        .fontSize(13)
                        .fontWeight(FontWeight.Medium)
                        .lineHeight(16)
                        .fontColor(device.status === 'online' ? getColors().runtimeRunning : getColors().muted)
                    }
                    .width('100%')
                    .onClick(() => {
                      this.toggleExpanded(device.id);
                    })
                    Text(`${device.deviceOs ?? 'unknown OS'} · seen ${this.formatTimestamp(device.lastSeenAt)}`)
                      .fontSize(13)
                      .fontWeight(FontWeight.Medium)
                      .lineHeight(16)
                      .fontColor(getColors().faint)
                      .width('100%')
                    if (this.expandedId === device.id) {
                      if (this.runtimesLoading) {
                        LoadingProgress()
                          .width(24)
                          .height(24)
                      } else if (this.runtimesError.length > 0) {
                        Text(this.runtimesError)
                          .fontSize(12.5)
                          .fontWeight(600)
                          .lineHeight(17)
                          .fontColor(getColors().errorText)
                      } else if (this.runtimes.length === 0) {
                        Text($r('app.string.devices_no_runtimes'))
                          .fontSize(13)
                          .fontWeight(FontWeight.Medium)
                          .lineHeight(17)
                          .fontColor(getColors().muted)
                      } else {
                        ForEach(this.runtimes, (runtime: RemoteDeviceRuntime) => {
                          this.runtimeRow(runtime)
                        // Key includes displayed state so activate/deactivate
                        // or reloaded runtime data rebuilds the row.
                        }, (runtime: RemoteDeviceRuntime) =>
                          `${runtime.runtimeId}_${runtime.displayName}_${runtime.status}_${runtime.active ? 1 : 0}_${runtime.present ? 1 : 0}_${runtime.configured ? 1 : 0}`)
                      }
                      if (this.discovering) {
                        Row({ space: 8 }) {
                          LoadingProgress()
                            .width(16)
                            .height(16)
                          Text($r('app.string.devices_runtime_discovering'))
                            .fontSize(12)
                            .fontColor(getColors().muted)
                        }
                        .width('100%')
                      }
                      Button($r('app.string.devices_runtime_add'))
                        .fontSize(14)
                        .fontWeight(FontWeight.Bold)
                        .height(34)
                        .width('100%')
                        .borderRadius(6)
                        .backgroundColor(getColors().subtle)
                        .fontColor(getColors().ink)
                        .enabled(!this.discovering && !this.busy)
                        .onClick(() => {
                          this.discoverRuntimes(device.id);
                        })
                      if (this.renameTargetId === device.id) {
                        Row({ space: 8 }) {
                          TextInput({ text: this.renameInput, placeholder: $r('app.string.devices_rename_placeholder') })
                            .fontSize(16)
                            .fontWeight(FontWeight.Bold)
                            .height(50)
                            .layoutWeight(1)
                            .borderRadius(12)
                            .backgroundColor(getColors().subtle)
                            .border({ width: 1, color: getColors().border })
                            .fontColor(getColors().ink)
                            .placeholderColor(getColors().faint)
                            .onChange((value: string) => {
                              this.renameInput = value;
                            })
                          Button($r('app.string.session_ok'))
                            .fontSize(15)
                            .fontWeight(FontWeight.Bold)
                            .height(44)
                            .borderRadius(22)
                            .backgroundColor(getColors().primaryAction)
                            .fontColor(getColors().onPrimaryAction)
                            .enabled(!this.busy)
                            .onClick(() => {
                              this.confirmRename();
                            })
                          Button($r('app.string.devices_delete_cancel'))
                            .fontSize(15)
                            .fontWeight(FontWeight.Bold)
                            .height(44)
                            .borderRadius(22)
                            .backgroundColor(getColors().secondaryActionSurface)
                            .fontColor(getColors().ink)
                            .border({ width: 1, color: getColors().border })
                            .onClick(() => {
                              this.cancelRename();
                            })
                        }
                        .width('100%')
                      } else {
                        Row({ space: 8 }) {
                          Button($r('app.string.devices_rename'))
                            .fontSize(14)
                            .fontWeight(FontWeight.Bold)
                            .height(34)
                            .borderRadius(6)
                            .backgroundColor(getColors().subtle)
                            .fontColor(getColors().ink)
                            .onClick(() => {
                              this.beginRename(device);
                            })
                          Button($r('app.string.devices_archive_all'))
                            .fontSize(14)
                            .fontWeight(FontWeight.Bold)
                            .height(34)
                            .borderRadius(6)
                            .backgroundColor(getColors().subtle)
                            .fontColor(getColors().ink)
                            .enabled(!this.busy)
                            .onClick(() => {
                              this.requestArchiveAll(device);
                            })
                          Button($r('app.string.devices_delete_confirm'))
                            .fontSize(14)
                            .fontWeight(FontWeight.Bold)
                            .height(34)
                            .borderRadius(6)
                            .backgroundColor(getColors().errorSurface)
                            .fontColor(getColors().errorText)
                            .enabled(!this.busy)
                            .onClick(() => {
                              this.requestDelete(device);
                            })
                        }
                        .width('100%')
                      }
                    }
                  }
                  .width('100%')
                  .alignItems(HorizontalAlign.Start)
                  .padding(12)
                  .borderRadius(15)
                  .backgroundColor(getColors().raisedSurface)
                  .border({ width: 1, color: getColors().border })
                }
              // Key includes displayed fields so replacing an item (rename,
              // refresh) rebuilds the row; a plain device.id key would keep
              // the stale row until the page is re-entered.
              }, (device: RemoteDevice) =>
                `${device.id}_${device.name}_${device.status}_${device.deviceOs ?? ''}_${device.lastSeenAt ?? ''}`)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 24, right: 24, top: 8, bottom: 28 })
          }
          .onRefreshing(() => {
            this.loadDevices();
          })
          .width('100%')
          .layoutWeight(1)
        }
        Button($r('app.string.devices_pair'))
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .height(44)
          .width('90%')
          .borderRadius(22)
          .backgroundColor(getColors().primaryAction)
          .fontColor(getColors().onPrimaryAction)
          .margin({ bottom: 16 })
          .onClick(() => {
            this.openPairing();
          })
        }
        .width('100%')
        .height('100%')
        if (this.configureTarget !== null) {
          RuntimeConfigureSheetOverlay({
            runtime: this.configureTarget,
            saving: this.configureSaving,
            errorText: this.configureError,
            onSave: (config: Record<string, Object>): void => {
              this.saveRuntimeConfig(config);
            },
            onClose: (): void => {
              this.closeConfigure();
            }
          })
        }
      }
      .width('100%')
      .height('100%')
    }
    .title($r('app.string.devices_title'))
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
      this.loadDevices();
    })
  }
}

@Builder
export function DevicesPageBuilder() {
  DevicesPage()
}
