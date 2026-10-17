import { ApiClient } from '../api/ApiClient';
import { DevicesApi, RemoteDevice, RemoteDeviceRuntime } from '../api/DevicesApi';
import { SharedApiClient } from '../api/SharedApiClient';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';

@Component
export struct DevicesPage {
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
  private navPathStack: NavPathStack = new NavPathStack();
  private runtimesRequestSeq: number = 0;
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private client: ApiClient = SharedApiClient.getInstance();
  private devicesApi: DevicesApi = new DevicesApi(this.client);

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
    AlertDialog.show({
      title: 'Delete device',
      message: `Delete "${device.name}"? Its connector token will stop working.`,
      primaryButton: {
        value: 'Cancel',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: 'Delete',
        fontColor: '#D93025',
        action: ():void => {
          this.deleteDevice(device.id);
        }
      }
    });
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

  private showPairingPlaceholder(): void {
    AlertDialog.show({
      title: 'Pair a device',
      message: 'Run the Connector on your work device and sign in there. ' +
        'Paired devices appear in this list automatically. (Pairing flow is coming soon.)',
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

  private statusColor(status: string): string {
    if (status === 'online') {
      return '#22C55E';
    }
    return '#9CA3AF';
  }

  private formatTimestamp(value: string | null): string {
    if (value === null || value.length < 16) {
      return 'unknown';
    }
    return value.substring(0, 16).replace('T', ' ');
  }

  @Builder
  runtimeRow(runtime: RemoteDeviceRuntime) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(runtime.displayName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
        Text(`${runtime.runtimeType} · ${runtime.status}`)
          .fontSize(12)
          .fontColor('#6B7280')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (runtime.active) {
        Text('active')
          .fontSize(11)
          .fontColor('#2563EB')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor('#DBEAFE')
      } else if (runtime.present) {
        Text('present')
          .fontSize(11)
          .fontColor('#059669')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor('#D1FAE5')
      } else {
        Text('absent')
          .fontSize(11)
          .fontColor('#6B7280')
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(8)
          .backgroundColor('#F3F4F6')
      }
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
  }

  build() {
    NavDestination() {
      Column() {
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(13)
            .fontColor('#D93025')
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
            List({ space: 8 }) {
              if (this.devices.length === 0) {
                ListItem() {
                  Text('No devices paired yet.')
                    .fontSize(14)
                    .fontColor('#999999')
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
                        .fontSize(16)
                        .fontWeight(FontWeight.Medium)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      Text(device.status)
                        .fontSize(12)
                        .fontColor('#6B7280')
                    }
                    .width('100%')
                    .onClick(() => {
                      this.toggleExpanded(device.id);
                    })
                    Text(`${device.deviceOs ?? 'unknown OS'} · seen ${this.formatTimestamp(device.lastSeenAt)}`)
                      .fontSize(12)
                      .fontColor('#9CA3AF')
                      .width('100%')
                    if (this.expandedId === device.id) {
                      if (this.runtimesLoading) {
                        LoadingProgress()
                          .width(24)
                          .height(24)
                      } else if (this.runtimesError.length > 0) {
                        Text(this.runtimesError)
                          .fontSize(12)
                          .fontColor('#D93025')
                      } else if (this.runtimes.length === 0) {
                        Text('No runtimes discovered on this device.')
                          .fontSize(12)
                          .fontColor('#9CA3AF')
                      } else {
                        ForEach(this.runtimes, (runtime: RemoteDeviceRuntime) => {
                          this.runtimeRow(runtime)
                        }, (runtime: RemoteDeviceRuntime) => runtime.runtimeId)
                      }
                      if (this.renameTargetId === device.id) {
                        Row({ space: 8 }) {
                          TextInput({ text: this.renameInput, placeholder: 'Device name' })
                            .fontSize(14)
                            .height(36)
                            .layoutWeight(1)
                            .onChange((value: string) => {
                              this.renameInput = value;
                            })
                          Button('OK')
                            .fontSize(13)
                            .height(36)
                            .enabled(!this.busy)
                            .onClick(() => {
                              this.confirmRename();
                            })
                          Button('Cancel')
                            .fontSize(13)
                            .height(36)
                            .backgroundColor('#F3F4F6')
                            .fontColor('#374151')
                            .onClick(() => {
                              this.cancelRename();
                            })
                        }
                        .width('100%')
                      } else {
                        Row({ space: 8 }) {
                          Button('Rename')
                            .fontSize(13)
                            .height(32)
                            .backgroundColor('#F3F4F6')
                            .fontColor('#374151')
                            .onClick(() => {
                              this.beginRename(device);
                            })
                          Button('Delete')
                            .fontSize(13)
                            .height(32)
                            .backgroundColor('#FEE2E2')
                            .fontColor('#DC2626')
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
                  .borderRadius(12)
                  .backgroundColor('#F8FAFC')
                }
              }, (device: RemoteDevice) => device.id)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 16, right: 16, top: 8, bottom: 16 })
          }
          .onRefreshing(() => {
            this.loadDevices();
          })
          .width('100%')
          .layoutWeight(1)
        }
        Button('Pair a device')
          .fontSize(14)
          .height(40)
          .width('90%')
          .margin({ bottom: 16 })
          .onClick(() => {
            this.showPairingPlaceholder();
          })
      }
      .width('100%')
      .height('100%')
    }
    .title('Devices')
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
