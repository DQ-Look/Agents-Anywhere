import { RemoteDeviceRuntime } from '../api/DevicesApi';
import { objGetArray, objGetOptString, objGetRecord } from '../common/Json';
import { getColors } from '../designsystem/ColorTokens';
import { RadiusTokens } from '../designsystem/TypeTokens';

/**
 * Draft of a single environment variable inside the runtime configure sheet.
 * `removeInherited` mirrors android RuntimeEnvironmentVariable.removeInheritedValue:
 * when set, the variable is submitted as an explicit null to clear an
 * inherited value on the connector.
 */
export interface RuntimeEnvVarDraft {
  name: string;
  value: string;
  removeInherited: boolean;
}

/**
 * Bottom-sheet overlay for editing a device runtime's configuration
 * (mirrors android DeviceRuntimeConfigureSheet):
 * - "executablePath" text field, when advertised by the runtime schema;
 * - "environment" variable editors (name / value / remove-inherited / delete),
 *   when advertised by the runtime schema;
 * - validation errors shown inline, save failures surfaced via `errorText`.
 * The sheet is created fresh each time the parent renders it, so the draft
 * state initialized in aboutToAppear always reflects the latest runtime.
 */
@Component
export struct RuntimeConfigureSheetOverlay {
  runtime: RemoteDeviceRuntime | null = null;
  @Prop saving: boolean = false;
  @Prop errorText: string = '';
  onSave: (config: Record<string, Object>) => void = () => {};
  onClose: () => void = () => {};
  @State executablePathInput: string = '';
  @State envVars: RuntimeEnvVarDraft[] = [];
  @State validationErrorKey: string = '';
  private fieldOrder: string[] = [];
  private supportsExecutablePath: boolean = false;
  private supportsEnvironment: boolean = false;

  aboutToAppear(): void {
    const rt = this.runtime;
    if (rt === null) {
      return;
    }
    const properties = rt.schemaRecord === null ? null : objGetRecord(rt.schemaRecord, 'properties');
    this.supportsExecutablePath = properties !== null && properties['executablePath'] !== undefined;
    this.supportsEnvironment = properties !== null && properties['environment'] !== undefined;
    const configRecord = rt.configRecord;
    let currentPath: string | null = configRecord === null ? null : objGetOptString(configRecord, 'executablePath');
    if (currentPath === null && properties !== null) {
      const pathSchema = objGetRecord(properties, 'executablePath');
      if (pathSchema !== null) {
        currentPath = objGetOptString(pathSchema, 'default');
      }
    }
    this.executablePathInput = currentPath ?? '';
    const drafts: RuntimeEnvVarDraft[] = [];
    if (configRecord !== null) {
      const envRecord = objGetRecord(configRecord, 'environment');
      if (envRecord !== null) {
        const names: string[] = Object.keys(envRecord);
        for (const name of names) {
          const raw = envRecord[name];
          if (typeof raw === 'string') {
            const draft: RuntimeEnvVarDraft = { name: name, value: raw, removeInherited: false };
            drafts.push(draft);
          } else if (raw === null || raw === undefined) {
            const draft: RuntimeEnvVarDraft = { name: name, value: '', removeInherited: true };
            drafts.push(draft);
          }
        }
      }
    }
    drafts.sort((left: RuntimeEnvVarDraft, right: RuntimeEnvVarDraft): number => {
      const a = left.name.toLowerCase();
      const b = right.name.toLowerCase();
      if (a < b) {
        return -1;
      }
      if (a > b) {
        return 1;
      }
      return 0;
    });
    this.envVars = drafts;
    const order: string[] = [];
    if (rt.uiSchemaRecord !== null) {
      for (const entry of objGetArray(rt.uiSchemaRecord, 'order')) {
        if (typeof entry === 'string') {
          order.push(entry);
        }
      }
    }
    if (this.supportsExecutablePath && !order.includes('executablePath')) {
      order.push('executablePath');
    }
    if (this.supportsEnvironment && !order.includes('environment')) {
      order.push('environment');
    }
    this.fieldOrder = order;
  }

  private requestClose(): void {
    if (!this.saving) {
      this.onClose();
    }
  }

  private addEnvVar(): void {
    const draft: RuntimeEnvVarDraft = { name: '', value: '', removeInherited: false };
    this.envVars.push(draft);
  }

  private removeEnvVar(index: number): void {
    this.envVars.splice(index, 1);
  }

  private updateEnvVar(index: number, name: string, value: string, removeInherited: boolean): void {
    const updated: RuntimeEnvVarDraft = { name: name, value: value, removeInherited: removeInherited };
    this.envVars[index] = updated;
  }

  // Mirrors android DeviceRuntimeConfigDraft.validationError(): '' when valid,
  // otherwise one of 'blank' | 'invalid' | 'duplicate'.
  private validateEnvVars(): string {
    if (!this.supportsEnvironment) {
      return '';
    }
    for (const draft of this.envVars) {
      if (draft.name.trim().length === 0) {
        return 'blank';
      }
      if (draft.name.includes('=') || draft.name.includes('\u0000')) {
        return 'invalid';
      }
    }
    for (let i = 0; i < this.envVars.length; i++) {
      for (let j = i + 1; j < this.envVars.length; j++) {
        if (this.envVars[i].name === this.envVars[j].name) {
          return 'duplicate';
        }
      }
    }
    return '';
  }

  // Builds the config payload for PUT .../config: keeps unknown base-config
  // fields, replaces the advertised sections with the draft values. Env vars
  // flagged removeInherited are sent as explicit nulls (clear inherited value).
  private buildConfig(): Record<string, Object> {
    const config: Record<string, Object> = {};
    const base = this.runtime === null ? null : this.runtime.configRecord;
    if (base !== null) {
      const keys: string[] = Object.keys(base);
      for (const key of keys) {
        if (this.supportsExecutablePath && key === 'executablePath') {
          continue;
        }
        if (this.supportsEnvironment && key === 'environment') {
          continue;
        }
        config[key] = base[key];
      }
    }
    if (this.supportsExecutablePath) {
      const trimmed = this.executablePathInput.trim();
      if (trimmed.length > 0) {
        config['executablePath'] = trimmed;
      }
    }
    if (this.supportsEnvironment) {
      const env: Record<string, string | null> = {};
      for (const draft of this.envVars) {
        env[draft.name] = draft.removeInherited ? null : draft.value;
      }
      config['environment'] = env;
    }
    return config;
  }

  private submit(): void {
    if (this.saving) {
      return;
    }
    this.validationErrorKey = this.validateEnvVars();
    if (this.validationErrorKey.length > 0) {
      return;
    }
    this.onSave(this.buildConfig());
  }

  @Builder
  validationErrorText() {
    if (this.validationErrorKey === 'blank') {
      Text($r('app.string.devices_runtime_config_env_blank_name'))
        .fontSize(12.5)
        .fontWeight(600)
        .lineHeight(17)
        .fontColor(getColors().errorText)
        .width('100%')
    } else if (this.validationErrorKey === 'invalid') {
      Text($r('app.string.devices_runtime_config_env_invalid_name'))
        .fontSize(12.5)
        .fontWeight(600)
        .lineHeight(17)
        .fontColor(getColors().errorText)
        .width('100%')
    } else {
      Text($r('app.string.devices_runtime_config_env_duplicate_name'))
        .fontSize(12.5)
        .fontWeight(600)
        .lineHeight(17)
        .fontColor(getColors().errorText)
        .width('100%')
    }
  }

  @Builder
  executablePathSection() {
    Column({ space: 6 }) {
      Text($r('app.string.devices_runtime_config_executable_path'))
        .fontSize(14)
        .fontWeight(700)
        .fontColor(getColors().ink)
        .width('100%')
      Text($r('app.string.devices_runtime_config_executable_path_desc'))
        .fontSize(12)
        .lineHeight(16)
        .fontColor(getColors().muted)
        .width('100%')
      TextInput({ text: this.executablePathInput,
        placeholder: $r('app.string.devices_runtime_config_executable_path_placeholder') })
        .fontSize(13.5)
        .fontWeight(500)
        .fontFamily('monospace')
        .height(44)
        .width('100%')
        .backgroundColor(getColors().raisedSurface)
        .borderRadius(12)
        .border({ width: 1, color: getColors().border })
        .enabled(!this.saving)
        .onChange((value: string) => {
          this.executablePathInput = value;
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  envVarRow(item: RuntimeEnvVarDraft, index: number) {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: item.name, placeholder: $r('app.string.devices_runtime_config_env_name') })
          .fontSize(13.5)
          .fontWeight(500)
          .fontFamily('monospace')
          .height(44)
          .layoutWeight(1)
          .backgroundColor(getColors().raisedSurface)
          .borderRadius(12)
          .border({ width: 1, color: getColors().border })
          .enabled(!this.saving)
          .onChange((value: string) => {
            this.updateEnvVar(index, value, item.value, item.removeInherited);
          })
        Button($r('app.string.devices_runtime_config_env_remove'))
          .fontSize(12)
          .height(38)
          .backgroundColor(getColors().errorSurface)
          .fontColor(getColors().errorText)
          .enabled(!this.saving)
          .onClick(() => {
            this.removeEnvVar(index);
          })
      }
      .width('100%')
      TextInput({ text: item.value, placeholder: $r('app.string.devices_runtime_config_env_value') })
        .fontSize(13.5)
        .fontWeight(500)
        .fontFamily('monospace')
        .height(44)
        .width('100%')
        .backgroundColor(getColors().raisedSurface)
        .borderRadius(12)
        .border({ width: 1, color: getColors().border })
        .enabled(!this.saving && !item.removeInherited)
        .onChange((value: string) => {
          this.updateEnvVar(index, item.name, value, item.removeInherited);
        })
      Row() {
        Text($r('app.string.devices_runtime_config_env_unset'))
          .fontSize(12.5)
          .fontWeight(600)
          .fontColor(getColors().muted)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: item.removeInherited })
          .enabled(!this.saving)
          .onChange((isOn: boolean) => {
            this.updateEnvVar(index, item.name, item.value, isOn);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(10)
    .borderRadius(RadiusTokens.card)
    .backgroundColor(getColors().subtleSurface)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  environmentSection() {
    Column({ space: 8 }) {
      Text($r('app.string.devices_runtime_config_environment'))
        .fontSize(14)
        .fontWeight(700)
        .fontColor(getColors().ink)
        .width('100%')
      Text($r('app.string.devices_runtime_config_environment_desc'))
        .fontSize(12)
        .lineHeight(16)
        .fontColor(getColors().muted)
        .width('100%')
      ForEach(this.envVars, (item: RuntimeEnvVarDraft, index: number) => {
        this.envVarRow(item, index)
      }, (item: RuntimeEnvVarDraft, index: number) => index.toString())
      Button($r('app.string.devices_runtime_config_env_add'))
        .fontSize(13)
        .height(34)
        .width('100%')
        .backgroundColor(getColors().sessionCodeSurface)
        .fontColor(getColors().inkSoft)
        .enabled(!this.saving)
        .onClick(() => {
          this.addEnvVar();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.45)')
      .onClick(() => {
        this.requestClose();
      })
      Column({ space: 12 }) {
        Text($r('app.string.devices_runtime_configure_title'))
          .fontSize(20)
          .fontWeight(800)
          .fontColor(getColors().headingText)
          .width('100%')
        Text(this.runtime === null ? '' : this.runtime.displayName)
          .fontSize(12)
          .fontWeight(600)
          .fontColor(getColors().muted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Scroll() {
          Column({ space: 14 }) {
            if (this.fieldOrder.length === 0) {
              Text($r('app.string.devices_runtime_configure_no_fields'))
                .fontSize(13)
                .fontColor(getColors().muted)
                .width('100%')
            }
            ForEach(this.fieldOrder, (field: string) => {
              if (field === 'executablePath' && this.supportsExecutablePath) {
                this.executablePathSection()
              } else if (field === 'environment' && this.supportsEnvironment) {
                this.environmentSection()
              }
            }, (field: string) => field)
            if (this.validationErrorKey.length > 0) {
              this.validationErrorText()
            }
            if (this.errorText.length > 0) {
              Text(this.errorText)
                .fontSize(12.5)
                .fontWeight(600)
                .lineHeight(17)
                .fontColor(getColors().errorText)
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
          Button($r('app.string.devices_delete_cancel'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(getColors().inkSoft)
            .backgroundColor(getColors().subtle)
            .height(44)
            .layoutWeight(1)
            .enabled(!this.saving)
            .onClick(() => {
              this.requestClose();
            })
          Button(this.saving ? $r('app.string.devices_runtime_config_saving') :
            $r('app.string.devices_runtime_configure_save'))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(getColors().onPrimaryAction)
            .backgroundColor(getColors().primaryAction)
            .height(44)
            .layoutWeight(1)
            .enabled(!this.saving)
            .onClick(() => {
              this.submit();
            })
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: '82%' })
      .padding({ left: 22, right: 22, top: 16, bottom: 20 })
      .borderRadius({ topLeft: RadiusTokens.sheetTop, topRight: RadiusTokens.sheetTop })
      .backgroundColor(getColors().raisedSurface)
    }
    .width('100%')
    .height('100%')
  }
}
