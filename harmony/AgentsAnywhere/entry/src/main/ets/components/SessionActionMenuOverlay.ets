@Component
export struct SessionActionMenuOverlay {
  @Prop sessionTitle: string = '';
  @Prop archived: boolean = false;
  @Prop pinned: boolean = false;
  onRename: () => void = () => {};
  onToggleArchived: () => void = () => {};
  onTogglePinned: () => void = () => {};
  onClose: () => void = () => {};

  @Builder
  menuRow(label: string, action: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor('#111827')
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 16, right: 16 })
    .onClick(() => {
      action();
    })
  }

  build() {
    Stack() {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.45)')
      .onClick(() => {
        this.onClose();
      })
      Column() {
        Text(this.sessionTitle)
          .fontSize(13)
          .fontColor('#9CA3AF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding({ top: 12, left: 16, right: 16 })
        this.menuRow('Rename', (): void => {
          this.onRename();
        })
        Divider()
          .color('#F3F4F6')
        this.menuRow(this.archived ? 'Unarchive' : 'Archive', (): void => {
          this.onToggleArchived();
        })
        Divider()
          .color('#F3F4F6')
        this.menuRow(this.pinned ? 'Unpin' : 'Pin', (): void => {
          this.onTogglePinned();
        })
        Divider()
          .color('#F3F4F6')
        this.menuRow('Cancel', (): void => {
          this.onClose();
        })
      }
      .width('72%')
      .borderRadius(16)
      .backgroundColor(Color.White)
      .padding({ bottom: 6 })
    }
    .width('100%')
    .height('100%')
  }
}
