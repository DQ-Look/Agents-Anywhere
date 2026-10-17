import { AuthApi } from '../api/AuthApi';
import { AuthMeResponse } from '../api/AuthDtos';
import { SharedApiClient, notifyAuthSessionExpired } from '../api/SharedApiClient';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';

@Component
export struct ProfilePage {
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State account: AuthMeResponse | null = null;
  @State editingName: boolean = false;
  @State nameInput: string = '';
  @State changingPassword: boolean = false;
  @State passwordInput: string = '';
  @State busy: boolean = false;
  private navPathStack: NavPathStack = new NavPathStack();
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private authApi: AuthApi = new AuthApi(SharedApiClient.getInstance());

  aboutToAppear(): void {
    this.loadAccount();
  }

  private serverUrl(): string {
    return this.authStore.readServerUrl();
  }

  private token(): string {
    return this.authStore.readAccessToken();
  }

  private async loadAccount(): Promise<void> {
    try {
      this.account = await this.authApi.me(this.serverUrl(), this.token());
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loading = false;
  }

  private prettyRole(role: string): string {
    if (role.length === 0) {
      return 'member';
    }
    return role.charAt(0).toUpperCase() + role.substring(1);
  }

  private accountLabel(): string {
    const account = this.account;
    if (account === null) {
      return 'Account';
    }
    if (account.displayName.trim().length > 0) {
      return account.displayName;
    }
    return account.email ?? 'Account';
  }

  private beginEditName(): void {
    const account = this.account;
    this.nameInput = account === null ? '' : account.displayName;
    this.editingName = true;
  }

  private cancelEditName(): void {
    this.editingName = false;
    this.nameInput = '';
  }

  private async confirmEditName(): Promise<void> {
    const name = this.nameInput.trim();
    if (name.length === 0) {
      this.errorMessage = 'A display name is required.';
      return;
    }
    this.busy = true;
    try {
      this.account = await this.authApi.updateDisplayName(this.serverUrl(), this.token(), name);
      this.editingName = false;
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.busy = false;
  }

  private beginChangePassword(): void {
    this.passwordInput = '';
    this.changingPassword = true;
  }

  private cancelChangePassword(): void {
    this.changingPassword = false;
    this.passwordInput = '';
  }

  private async confirmChangePassword(): Promise<void> {
    const password = this.passwordInput;
    if (password.length < 8) {
      this.errorMessage = 'The new password must be at least 8 characters.';
      return;
    }
    this.busy = true;
    try {
      await this.authApi.changePassword(this.serverUrl(), this.token(), password);
      this.changingPassword = false;
      this.passwordInput = '';
      this.errorMessage = '';
      AlertDialog.show({
        title: 'Password updated',
        message: 'Your password has been changed. Use it the next time you sign in.',
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
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.busy = false;
  }

  private requestSignOut(): void {
    AlertDialog.show({
      title: 'Sign out',
      message: 'Sign out of this account on this device?',
      primaryButton: {
        value: 'Cancel',
        action: (): void => {
        }
      },
      secondaryButton: {
        value: 'Sign out',
        fontColor: '#D93025',
        action: (): void => {
          this.signOut();
        }
      }
    });
  }

  private signOut(): void {
    try {
      this.authStore.clearAuthSession();
    } catch (error) {
    }
    notifyAuthSessionExpired();
  }

  @Builder
  infoRow(label: string, value: string) {
    Row({ space: 8 }) {
      Text(label)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111827')
        .layoutWeight(1)
      Text(value)
        .fontSize(14)
        .fontColor('#6B7280')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '60%' })
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  actionRow(label: string, danger: boolean, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(danger ? '#DC2626' : '#111827')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 13, bottom: 13 })
    .onClick(() => {
      action();
    })
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
          Scroll() {
            Column({ space: 16 }) {
              Column({ space: 4 }) {
                Text(this.accountLabel())
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#111827')
                Text(this.account === null ? '' : this.prettyRole(this.account.role))
                  .fontSize(13)
                  .fontColor('#6B7280')
              }
              .width('100%')
              .padding({ top: 8 })
              Column() {
                if (this.editingName) {
                  Column({ space: 8 }) {
                    Text('Display name')
                      .fontSize(13)
                      .fontColor('#6B7280')
                      .width('100%')
                    TextInput({ text: this.nameInput, placeholder: 'Display name' })
                      .fontSize(14)
                      .height(40)
                      .width('100%')
                      .onChange((value: string) => {
                        this.nameInput = value;
                      })
                    Row({ space: 8 }) {
                      Button('Save')
                        .fontSize(13)
                        .height(36)
                        .layoutWeight(1)
                        .enabled(!this.busy)
                        .onClick(() => {
                          this.confirmEditName();
                        })
                      Button('Cancel')
                        .fontSize(13)
                        .height(36)
                        .layoutWeight(1)
                        .backgroundColor('#F3F4F6')
                        .fontColor('#374151')
                        .enabled(!this.busy)
                        .onClick(() => {
                          this.cancelEditName();
                        })
                    }
                    .width('100%')
                  }
                  .width('100%')
                } else {
                  this.infoRow('Display name',
                    this.account === null ? '' : this.account.displayName)
                  Divider()
                    .color('#F3F4F6')
                  this.infoRow('Email', this.account === null ? '' : (this.account.email ?? 'Not bound'))
                  Divider()
                    .color('#F3F4F6')
                  this.infoRow('Role', this.account === null ? '' : this.prettyRole(this.account.role))
                  Divider()
                    .color('#F3F4F6')
                  this.actionRow('Edit display name', false, (): void => {
                    this.beginEditName();
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              .borderRadius(12)
              .backgroundColor('#F8FAFC')
              Column() {
                if (this.changingPassword) {
                  Column({ space: 8 }) {
                    Text('New password (at least 8 characters)')
                      .fontSize(13)
                      .fontColor('#6B7280')
                      .width('100%')
                    TextInput({ text: this.passwordInput, placeholder: 'New password' })
                      .type(InputType.Password)
                      .fontSize(14)
                      .height(40)
                      .width('100%')
                      .onChange((value: string) => {
                        this.passwordInput = value;
                      })
                    Row({ space: 8 }) {
                      Button('Save')
                        .fontSize(13)
                        .height(36)
                        .layoutWeight(1)
                        .enabled(!this.busy)
                        .onClick(() => {
                          this.confirmChangePassword();
                        })
                      Button('Cancel')
                        .fontSize(13)
                        .height(36)
                        .layoutWeight(1)
                        .backgroundColor('#F3F4F6')
                        .fontColor('#374151')
                        .enabled(!this.busy)
                        .onClick(() => {
                          this.cancelChangePassword();
                        })
                    }
                    .width('100%')
                  }
                  .width('100%')
                } else {
                  this.actionRow('Change password', false, (): void => {
                    this.beginChangePassword();
                  })
                }
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              .borderRadius(12)
              .backgroundColor('#F8FAFC')
              Column() {
                this.actionRow('Sign out', true, (): void => {
                  this.requestSignOut();
                })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 4 })
              .borderRadius(12)
              .backgroundColor('#F8FAFC')
            }
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 24 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
    }
    .title('Profile')
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
    })
  }
}

@Builder
export function ProfilePageBuilder() {
  ProfilePage()
}
