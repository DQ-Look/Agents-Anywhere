import { AuthSessionStore } from '../auth/AuthSessionStore';
import { HomePage } from './HomePage';
import { LoginPage } from './LoginPage';

@Entry
@Component
struct Index {
  @State ready: boolean = false;
  @State signedIn: boolean = false;
  // Keep in sync with the key in api/SharedApiClient.ets.
  @StorageLink('authSessionExpiredTick') @Watch('onAuthSessionExpired') authExpiredTick: number = 0;
  private pathStack: NavPathStack = new NavPathStack();
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();

  aboutToAppear(): void {
    this.waitUntilReady();
  }

  private async waitUntilReady(): Promise<void> {
    await this.authStore.waitUntilReady();
    try {
      this.signedIn = this.authStore.hasAuthSession();
    } catch (error) {
      this.signedIn = false;
    }
    this.ready = true;
  }

  private onAuthSessionExpired(): void {
    if (!this.signedIn) {
      return;
    }
    this.pathStack.clear();
    this.signedIn = false;
  }

  build() {
    Column() {
      if (!this.ready) {
        LoadingProgress()
          .width(44)
          .height(44)
      } else if (this.signedIn) {
        Navigation(this.pathStack) {
          HomePage({
            pathStack: this.pathStack,
            onSignedOut: () => {
              this.pathStack.clear();
              this.signedIn = false;
            }
          })
        }
        .mode(NavigationMode.Stack)
        .hideTitleBar(true)
        .width('100%')
        .layoutWeight(1)
      } else {
        LoginPage({ onSignedIn: () => {
          this.signedIn = true;
        } })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#FFFFFF')
  }
}
