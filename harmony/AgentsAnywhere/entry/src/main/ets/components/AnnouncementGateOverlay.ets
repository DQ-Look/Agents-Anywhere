import { MdBlock } from '../common/Markdown';
import { AgentMarkdownView } from './AgentMarkdownView';

@Component
export struct AnnouncementGateOverlay {
  blocks: MdBlock[] = [];
  onClose: () => void = () => {};

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
      Column({ space: 14 }) {
        Text('Announcement')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#111827')
          .width('100%')
        Scroll() {
          Column() {
            AgentMarkdownView({
              blocks: this.blocks,
              textColor: '#374151',
              linkColor: '#2563EB',
              inlineCodeColor: '#92400E',
              codePanelColor: '#F3F4F6',
              codePanelTextColor: '#1F2937',
              fontSize: 14
            })
          }
          .constraintSize({ minHeight: 20 })
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)
        .width('100%')
        .constraintSize({ maxHeight: 320 })
        Button('Got it')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor('#2563EB')
          .height(42)
          .width('100%')
          .onClick(() => {
            this.onClose();
          })
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
