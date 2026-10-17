import { RemoteDevice, RemoteDeviceRuntime } from '../api/DevicesApi';

@Component
export struct NewSessionSheetOverlay {
  @Prop devices: RemoteDevice[] = [];
  @Prop runtimes: RemoteDeviceRuntime[] = [];
  @Prop runtimesLoading: boolean = false;
  @Prop selectedDeviceId: string = '';
  @Prop selectedRuntimeType: string = '';
  @Prop cwdInput: string = '';
  @Prop messageInput: string = '';
  @Prop creating: boolean = false;
  @Prop errorText: string = '';
  onDeviceSelected: (deviceId: string) => void = () => {};
  onRuntimeSelected: (runtimeType: string) => void = () => {};
  onCwdChange: (value: string) => void = () => {};
  onMessageChange: (value: string) => void = () => {};
  onCreate: () => void = () => {};
  onClose: () => void = () => {};

  private deviceName(deviceId: string): string {
    for (const device of this.devices) {
      if (device.id === deviceId) {
        return device.name;
      }
    }
    return '';
  }

  @Builder
  deviceChip(device: RemoteDevice) {
    Text(device.name)
      .fontSize(13)
      .fontColor(this.selectedDeviceId === device.id ? Color.White : '#374151')
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.selectedDeviceId === device.id ? '#2563EB' : '#F2F3F5')
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onDeviceSelected(device.id);
      })
  }

  @Builder
  runtimeChip(runtime: RemoteDeviceRuntime) {
    Text(runtime.displayName)
      .fontSize(13)
      .fontColor(this.selectedRuntimeType === runtime.runtimeType ? Color.White : '#374151')
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .borderRadius(16)
      .backgroundColor(this.selectedRuntimeType === runtime.runtimeType ? '#2563EB' : '#F2F3F5')
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onRuntimeSelected(runtime.runtimeType);
      })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.45)')
      .onClick(() => {
        this.onClose();
      })
      Column({ space: 12 }) {
        Text('New session')
          .fontSize(17)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
        Scroll() {
          Column({ space: 12 }) {
            Column({ space: 6 }) {
              Text('Device')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#6B7280')
                .width('100%')
              if (this.devices.length === 0) {
                Text('No connected devices. Pair a device first.')
                  .fontSize(13)
                  .fontColor('#9CA3AF')
                  .width('100%')
              } else {
                Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
                  ForEach(this.devices, (device: RemoteDevice) => {
                    this.deviceChip(device)
                  }, (device: RemoteDevice) => device.id)
                }
                .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            Column({ space: 6 }) {
              Text('Runtime')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#6B7280')
                .width('100%')
              if (this.selectedDeviceId.length === 0) {
                Text('Select a device first.')
                  .fontSize(13)
                  .fontColor('#9CA3AF')
                  .width('100%')
              } else if (this.runtimesLoading) {
                LoadingProgress()
                  .width(22)
                  .height(22)
              } else if (this.runtimes.length === 0) {
                Text('No runtimes discovered on this device.')
                  .fontSize(13)
                  .fontColor('#9CA3AF')
                  .width('100%')
              } else {
                Flex({ direction: FlexDirection.Row, wrap: FlexWrap.Wrap }) {
                  ForEach(this.runtimes, (runtime: RemoteDeviceRuntime) => {
                    this.runtimeChip(runtime)
                  }, (runtime: RemoteDeviceRuntime) => `${runtime.runtimeId}:${runtime.runtimeType}`)
                }
                .width('100%')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            Column({ space: 6 }) {
              Text('Workspace directory (optional)')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#6B7280')
                .width('100%')
              TextInput({ text: this.cwdInput, placeholder: '~' })
                .fontSize(14)
                .height(40)
                .width('100%')
                .enabled(!this.creating)
                .onChange((value: string) => {
                  this.onCwdChange(value);
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            Column({ space: 6 }) {
              Text('First message')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor('#6B7280')
                .width('100%')
              TextArea({ text: this.messageInput, placeholder: 'Describe the task for the agent' })
                .fontSize(14)
                .constraintSize({ minHeight: 72 })
                .width('100%')
                .enabled(!this.creating)
                .onChange((value: string) => {
                  this.onMessageChange(value);
                })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(13)
                .fontColor('#D93025')
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .layoutWeight(1)
        .align(Alignment.Top)
        .edgeEffect(EdgeEffect.Spring)
        Row({ space: 10 }) {
          Button('Cancel')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#374151')
            .backgroundColor('#F2F3F5')
            .height(44)
            .layoutWeight(1)
            .enabled(!this.creating)
            .onClick(() => {
              this.onClose();
            })
          Button(this.creating ? 'Creating…' : 'Create')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('#2563EB')
            .height(44)
            .layoutWeight(1)
            .enabled(!this.creating)
            .onClick(() => {
              this.onCreate();
            })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: '82%' })
      .padding({ left: 18, right: 18, top: 16, bottom: 20 })
      .borderRadius({ topLeft: 20, topRight: 20 })
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
  }
}
