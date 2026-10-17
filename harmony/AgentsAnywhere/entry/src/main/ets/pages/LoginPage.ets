import { webview } from '@kit.ArkWeb';
import { ApiClient } from '../api/ApiClient';
import { AuthApi } from '../api/AuthApi';
import { SharedApiClient } from '../api/SharedApiClient';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { LoginServerConnection, resolveLoginServer } from '../auth/LoginServer';
import {
  createWebLoginSession,
  parseWebLoginCallback,
  WebLoginCallback,
  WebLoginCallbackKind,
  WebLoginSession,
  WEB_LOGIN_CALLBACK_URI
} from '../auth/WebLoginModels';
import { ApiException, errorMessageFrom } from '../common/ApiException';

const PHASE_HOST_FORM = 0;
const PHASE_WEB_LOGIN = 1;
const PHASE_EXCHANGING = 2;

@Component
export struct LoginPage {
  onSignedIn: () => void = () => {};
  @State phase: number = PHASE_HOST_FORM;
  @State busy: boolean = false;
  @State hostInput: string = '';
  @State errorMessage: string = '';
  @State authorizeUrl: string = '';
  private webController: webview.WebviewController = new webview.WebviewController();
  private loginSession: WebLoginSession | null = null;
  private client: ApiClient = SharedApiClient.getInstance();
  private authApi: AuthApi = new AuthApi(this.client);
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();

  aboutToAppear(): void {
    try {
      const serverUrl = this.authStore.readServerUrl();
      if (serverUrl.length > 0) {
        this.hostInput = serverUrl;
      }
    } catch (error) {
    }
  }

  private async startWebLogin(): Promise<void> {
    this.busy = true;
    this.errorMessage = '';
    const input = this.hostInput.trim();
    try {
      const candidate = input.length > 0 ? input : this.authStore.readServerUrl();
      const connection = resolveLoginServer(candidate);
      if (connection === null) {
        throw new ApiException('Enter a valid backend address.');
      }
      await this.authApi.requireHealthyServer(connection.serverUrl);
      await this.authApi.requireWebLoginHost(connection.oauthWebOrigin);
      this.authStore.saveServerUrl(connection.serverUrl);
      const session = await createWebLoginSession(connection);
      this.loginSession = session;
      this.webController = new webview.WebviewController();
      this.authorizeUrl = session.authorizeUrl;
      this.phase = PHASE_WEB_LOGIN;
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.busy = false;
  }

  private handleCallbackUrl(url: string): void {
    const session = this.loginSession;
    if (session === null) {
      return;
    }
    const callback = parseWebLoginCallback(url, session);
    if (callback.kind === WebLoginCallbackKind.Success) {
      this.exchangeCode(session, callback.code);
      return;
    }
    this.loginSession = null;
    this.phase = PHASE_HOST_FORM;
    this.errorMessage = callback.message;
  }

  private async exchangeCode(session: WebLoginSession, code: string): Promise<void> {
    this.phase = PHASE_EXCHANGING;
    try {
      const token = await this.authApi.oauthToken(session.serverUrl, code, session.codeVerifier);
      const me = await this.authApi.me(session.serverUrl, token.accessToken);
      this.authStore.saveAuthSession(session.serverUrl, me.userId, me.role,
        token.accessToken, token.tokenType);
      this.loginSession = null;
      this.onSignedIn();
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
      this.loginSession = null;
      this.phase = PHASE_HOST_FORM;
    }
  }

  @Builder
  HostForm() {
    Column({ space: 12 }) {
      Text('Agents Anywhere')
        .fontSize(26)
        .fontWeight(FontWeight.Bold)
      Text('Sign in to your workspace')
        .fontSize(14)
        .fontColor('#666666')
      TextInput({ placeholder: 'https://your-server.example.com', text: this.hostInput })
        .onChange((value: string) => {
          this.hostInput = value;
        })
        .width('100%')
        .height(48)
        .backgroundColor('#F2F3F5')
        .borderRadius(10)
      Button('Continue')
        .width('100%')
        .height(46)
        .fontSize(16)
        .enabled(!this.busy)
        .onClick(() => {
          this.startWebLogin();
        })
      if (this.busy) {
        LoadingProgress()
          .width(24)
          .height(24)
      }
      if (this.errorMessage.length > 0) {
        Text(this.errorMessage)
          .fontSize(13)
          .fontColor('#D93025')
          .width('100%')
      }
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 24, right: 24 })
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Column() {
      if (this.phase === PHASE_HOST_FORM) {
        this.HostForm()
      } else if (this.phase === PHASE_WEB_LOGIN) {
        Web({ src: this.authorizeUrl, controller: this.webController })
          .width('100%')
          .layoutWeight(1)
          .onLoadIntercept((event) => {
            const url = event.data.getRequestUrl();
            if (url.toLowerCase().startsWith(WEB_LOGIN_CALLBACK_URI)) {
              this.handleCallbackUrl(url);
              return true;
            }
            return false;
          })
      } else {
        Column({ space: 12 }) {
          LoadingProgress()
            .width(44)
            .height(44)
          Text('Signing in…')
            .fontSize(14)
            .fontColor('#666666')
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
  }
}
