import { buffer } from '@kit.ArkTS';
import { ApiClient } from '../api/ApiClient';
import { DevicesApi, RemoteDevice } from '../api/DevicesApi';
import { RealtimeSocketListener, RealtimeWebSocket } from '../api/RealtimeWebSocket';
import { SharedApiClient } from '../api/SharedApiClient';
import { RemoteTerminal, TerminalApi } from '../api/TerminalApi';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';
import { objGetOptNumber, objGetString, parseJsonRecord } from '../common/Json';

const TERMINAL_LABEL_PREFIX = 'HMOS ';
const MAX_OUTPUT_CHARS = 60000;
const DEFAULT_COLS = 80;
const DEFAULT_ROWS = 24;

interface DeviceOption {
  value: string;
  icon?: Resource;
}

const ANSI_PATTERN = new RegExp('\u001b\\[[0-9;?]*[ -/]*[@-~]' +
  '|\u001b\\][^\u0007\u001b]*\u0007' +
  '|\u001b\\][^\u0007\u001b]*\u001b\\\\' +
  '|\u0008|\u000d', 'g');

function stripAnsiCodes(text: string): string {
  return text.replace(ANSI_PATTERN, '');
}

function encodeBase64Utf8(text: string): string {
  return buffer.from(text, 'utf-8').toString('base64');
}

function decodeBase64Utf8(text: string): string {
  return buffer.from(text, 'base64').toString('utf-8');
}

@Component
export struct TerminalPage {
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State devices: RemoteDevice[] = [];
  @State deviceOptions: DeviceOption[] = [];
  @State selectedDeviceIndex: number = 0;
  @State deviceId: string = '';
  @State terminalLabel: string = '';
  @State outputText: string = '';
  @State connected: boolean = false;
  @State exited: boolean = false;
  @State inputText: string = '';
  @State connecting: boolean = false;
  private terminal: RemoteTerminal | null = null;
  private lastSeq: number = 0;
  private ephemeralGroupId: string = `hmos_${Date.now().toString(36)}`;
  private optCounter: number = 0;
  private navPathStack: NavPathStack = new NavPathStack();
  private scroller: Scroller = new Scroller();
  private socket: RealtimeWebSocket = new RealtimeWebSocket();
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private client: ApiClient = SharedApiClient.getInstance();
  private devicesApi: DevicesApi = new DevicesApi(this.client);
  private terminalApi: TerminalApi = new TerminalApi(this.client);

  aboutToDisappear(): void {
    this.socket.destroy();
    this.closeOwnedTerminal();
  }

  private closeOwnedTerminal(): void {
    const terminal = this.terminal;
    if (terminal === null || this.deviceId.length === 0) {
      return;
    }
    if (terminal.label.indexOf(TERMINAL_LABEL_PREFIX) !== 0) {
      return;
    }
    this.terminalApi.closeTerminal(this.serverUrl(), this.token(), this.deviceId, terminal.terminalId)
      .catch(() => {
      });
  }

  private serverUrl(): string {
    return this.authStore.readServerUrl();
  }

  private token(): string {
    return this.authStore.readAccessToken();
  }

  private nextId(): string {
    this.optCounter++;
    return `${this.ephemeralGroupId}_${this.optCounter}`;
  }

  private appendOutput(chunk: string): void {
    const merged = this.outputText + chunk;
    if (merged.length > MAX_OUTPUT_CHARS) {
      this.outputText = merged.substring(merged.length - MAX_OUTPUT_CHARS);
    } else {
      this.outputText = merged;
    }
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 60);
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

  private async startTerminal(): Promise<void> {
    this.connecting = true;
    this.errorMessage = '';
    try {
      if (this.deviceId.length === 0) {
        await this.pickDevice();
      }
      if (this.deviceId.length === 0) {
        this.connecting = false;
        return;
      }
      const terminal = await this.acquireTerminal();
      this.terminal = terminal;
      this.terminalLabel = terminal.label;
      this.connectStream(0);
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.connecting = false;
    this.loading = false;
  }

  private async acquireTerminal(): Promise<RemoteTerminal> {
    const terminals = await this.terminalApi.listTerminals(this.serverUrl(), this.token(), this.deviceId);
    for (const terminal of terminals) {
      if (terminal.status !== 'exited' && terminal.label.indexOf(TERMINAL_LABEL_PREFIX) === 0) {
        return terminal;
      }
    }
    return this.terminalApi.createTerminal(this.serverUrl(), this.token(), this.deviceId, '~',
      DEFAULT_COLS, DEFAULT_ROWS, '.', this.ephemeralGroupId, `${TERMINAL_LABEL_PREFIX}Terminal`);
  }

  private connectStream(fromSeq: number): void {
    const terminal = this.terminal;
    if (terminal === null) {
      return;
    }
    this.socket.destroy();
    const url = this.terminalApi.streamUrl(this.serverUrl(), this.deviceId, terminal.terminalId, fromSeq);
    const headers: Record<string, string> = {
      'Authorization': `Bearer ${this.token()}`
    };
    this.socket.connect(url, this.createSocketListener(), headers);
  }

  private createSocketListener(): RealtimeSocketListener {
    const listener: RealtimeSocketListener = {
      onOpen: (): void => {
        this.connected = true;
      },
      onMessage: (text: string): void => {
        this.handleFrame(text);
      },
      onClose: (code: number, reason: string): void => {
        this.connected = false;
      },
      onError: (message: string): void => {
        this.connected = false;
        this.errorMessage = message;
      }
    };
    return listener;
  }

  private handleFrame(text: string): void {
    let frame: Record<string, Object>;
    try {
      frame = parseJsonRecord(text);
    } catch (error) {
      return;
    }
    const type = objGetString(frame, 'type', '');
    if (type === 'output' || type === 'replay') {
      const data = objGetString(frame, 'data', '');
      if (data.length === 0) {
        return;
      }
      const seq = objGetOptNumber(frame, 'seq');
      if (seq !== null && seq > 0 && seq <= this.lastSeq) {
        return;
      }
      if (seq !== null && seq > this.lastSeq) {
        this.lastSeq = seq;
      }
      this.appendOutput(stripAnsiCodes(decodeBase64Utf8(data)));
      return;
    }
    if (type === 'exit') {
      this.exited = true;
      this.appendOutput('\n[process exited]\n');
      return;
    }
    if (type === 'error') {
      this.errorMessage = objGetString(frame, 'message', 'Terminal error.');
    }
  }

  private sendInput(): void {
    const text = this.inputText;
    if (text.length === 0 || this.exited || !this.connected) {
      return;
    }
    const payload: Record<string, Object> = {
      'type': 'input',
      'data': encodeBase64Utf8(text)
    };
    this.socket.send(JSON.stringify(payload)).catch(() => {
      this.errorMessage = 'Could not send input. Reconnecting…';
    });
    this.inputText = '';
    this.appendOutput(stripAnsiCodes(text) + '\n');
  }

  private reconnect(): void {
    if (this.connecting) {
      return;
    }
    this.connectStream(this.lastSeq);
  }

  private async reopenTerminal(): Promise<void> {
    if (this.connecting) {
      return;
    }
    this.connecting = true;
    this.errorMessage = '';
    this.exited = false;
    this.socket.destroy();
    this.terminal = null;
    this.terminalLabel = '';
    this.outputText = '';
    this.lastSeq = 0;
    try {
      const terminal = await this.acquireTerminal();
      this.terminal = terminal;
      this.terminalLabel = terminal.label;
      this.connectStream(0);
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.connecting = false;
    this.loading = false;
  }

  private showResizePlaceholder(): void {
    AlertDialog.show({
      title: 'Resize',
      message: `Current size: ${DEFAULT_COLS} x ${DEFAULT_ROWS}. Interactive resizing is coming soon.`,
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

  private statusText(): string {
    if (this.exited) {
      return 'exited';
    }
    if (this.connected) {
      return 'connected';
    }
    return 'disconnected';
  }

  private emptyStateText(): string {
    return this.connecting ? 'Connecting to terminal…' : 'Terminal is ready. Type a command below.';
  }

  private inputPlaceholder(): string {
    return this.exited ? 'Terminal exited' : 'Type a command…';
  }

  private statusColor(): string {
    if (this.exited) {
      return '#9CA3AF';
    }
    if (this.connected) {
      return '#16A34A';
    }
    return '#D97706';
  }

  private sendButtonLabel(): string {
    if (this.connected && !this.exited) {
      return 'Send';
    }
    return 'Reconnect';
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
        Row({ space: 8 }) {
          Circle()
            .width(8)
            .height(8)
            .fill(this.statusColor())
          Text(this.statusText())
            .fontSize(12)
            .fontColor(this.statusColor())
          Text(this.terminalLabel)
            .fontSize(12)
            .fontColor('#9CA3AF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          Button('⤢')
            .fontSize(13)
            .height(28)
            .padding({ left: 10, right: 10 })
            .backgroundColor('#F3F4F6')
            .fontColor('#374151')
            .onClick(() => {
              this.showResizePlaceholder();
            })
          Button('⟳')
            .fontSize(13)
            .height(28)
            .padding({ left: 10, right: 10 })
            .backgroundColor('#F3F4F6')
            .fontColor('#374151')
            .onClick(() => {
              this.reconnect();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 4, bottom: 4 })
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
        } else if (this.outputText.length === 0) {
          Column() {
            Text(this.emptyStateText())
              .fontSize(13)
              .fontColor('#9CA3AF')
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll(this.scroller) {
            Text(this.outputText)
              .fontSize(12)
              .fontFamily('monospace')
              .fontColor('#D1FAE5')
              .textAlign(TextAlign.Start)
              .width('100%')
          }
          .backgroundColor('#111827')
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.TopStart)
          .padding(8)
        }
        if (this.exited) {
          Button('Reopen terminal')
            .fontSize(13)
            .height(36)
            .width('100%')
            .margin({ left: 12, right: 12, top: 8 })
            .backgroundColor('#059669')
            .fontColor('#FFFFFF')
            .enabled(!this.connecting)
            .onClick(() => {
              this.reopenTerminal();
            })
        }
        Row({ space: 8 }) {
          TextInput({ text: this.inputText, placeholder: this.inputPlaceholder() })
            .fontSize(13)
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#F8FAFC')
            .enabled(!this.exited)
            .onChange((value: string) => {
              this.inputText = value;
            })
            .onSubmit(() => {
              this.handlePrimaryAction();
            })
          Button(this.sendButtonLabel())
            .fontSize(13)
            .height(40)
            .padding({ left: 16, right: 16 })
            .backgroundColor('#2563EB')
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.handlePrimaryAction();
            })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
      }
      .width('100%')
      .height('100%')
    }
    .title('Terminal')
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
      const raw = ctx.pathInfo.param as string;
      if (typeof raw === 'string' && raw.length > 0) {
        this.deviceId = raw;
      }
      this.startTerminal();
    })
  }

  private handleDeviceChange(index: number): void {
    if (index < 0 || index >= this.devices.length) {
      return;
    }
    this.selectedDeviceIndex = index;
    this.deviceId = this.devices[index].id;
    this.terminal = null;
    this.terminalLabel = '';
    this.outputText = '';
    this.lastSeq = 0;
    this.exited = false;
    this.socket.destroy();
    this.startTerminal();
  }

  private handlePrimaryAction(): void {
    if (this.connected && !this.exited) {
      this.sendInput();
    } else {
      this.reconnect();
    }
  }
}

@Builder
export function TerminalPageBuilder() {
  TerminalPage()
}
