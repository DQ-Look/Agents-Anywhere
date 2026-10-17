@Component
export struct AppUpdatePromptOverlay {
  versionName: string = '';
  downloadUrl: string = '';
  onDownload: () => void = () => {};
  onIgnore: () => void = () => {};

  build() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.45)')
      .onClick(() => {
        this.onIgnore();
      })
      Column({ space: 14 }) {
        Text('Update available')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
        Text(`A new version ${this.versionName} is available. Open the download page in your browser and install the update manually.`)
          .fontSize(14)
          .fontColor('#4B5563')
          .width('100%')
          .lineHeight(20)
        Row({ space: 10 }) {
          Button('Ignore')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#374151')
            .backgroundColor('#F2F3F5')
            .height(42)
            .layoutWeight(1)
            .onClick(() => {
              this.onIgnore();
            })
          Button('Download')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor('#2563EB')
            .height(42)
            .layoutWeight(1)
            .onClick(() => {
              this.onDownload();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(18)
      .borderRadius(16)
      .backgroundColor(Color.White)
    }
    .width('100%')
    .height('100%')
  }
}
