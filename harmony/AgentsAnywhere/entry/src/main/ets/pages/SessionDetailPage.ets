import { ApiClient } from '../api/ApiClient';
import { RealtimeApi } from '../api/RealtimeApi';
import { RealtimeSocketListener, RealtimeWebSocket } from '../api/RealtimeWebSocket';
import { SharedApiClient } from '../api/SharedApiClient';
import {
  RemoteCommandResult,
  RemoteNoticeAction,
  RemoteRuntimeCommand,
  RemoteRuntimeNotice,
  RemoteSession,
  RemoteSessionEventEnvelope,
  RemoteTimelineAttachment,
  RemoteTimelineItem,
  RemoteUploadedAttachment
} from '../api/SessionDtos';
import { SessionsApi } from '../api/SessionsApi';
import { AuthSessionStore } from '../auth/AuthSessionStore';
import { errorMessageFrom } from '../common/ApiException';
import { MdBlock, parseMarkdownBlocks } from '../common/Markdown';
import { AgentMarkdownView } from '../components/AgentMarkdownView';
import { AttachmentImageView } from '../components/AttachmentImageView';

interface TimelineEntry {
  item: RemoteTimelineItem;
  blocks: MdBlock[];
  attachments: RemoteTimelineAttachment[];
}

interface SlashIntent {
  command: string;
  suffix: string;
  raw: string;
  multiline: boolean;
  commandLike: boolean;
}

const OPTIMISTIC_PREFIX = 'opt_';
const BUSY_STATUSES: string[] = ['waiting', 'pending', 'running', 'stopping', 'waiting_approval', 'blocked'];
const RETRY_BASE_DELAY_MS = 1000;
const RETRY_MAX_DELAY_MS = 30000;
const MAX_PROCESSED_EVENT_IDS = 1000;
const RETAINED_PROCESSED_EVENT_IDS = 500;
const MAX_SUGGESTIONS = 6;
const MAX_PENDING_ATTACHMENTS = 10;

function isBusyStatus(status: string): boolean {
  return BUSY_STATUSES.indexOf(status) >= 0;
}

function isCommandLikeToken(token: string): boolean {
  return /^[a-z0-9][a-z0-9_:.\\-]*$/.test(token);
}

function parseSlashIntent(raw: string): SlashIntent | null {
  let trimmed = raw;
  let lead = 0;
  while (lead < trimmed.length && (trimmed.charAt(lead) === ' ' || trimmed.charAt(lead) === '\t')) {
    lead++;
  }
  trimmed = trimmed.substring(lead);
  if (!trimmed.startsWith('/')) {
    return null;
  }
  const body = trimmed.substring(1);
  let tokenEnd = 0;
  while (tokenEnd < body.length && body.charAt(tokenEnd) !== ' ' && body.charAt(tokenEnd) !== '\t' &&
    body.charAt(tokenEnd) !== '\n' && body.charAt(tokenEnd) !== '\r') {
    tokenEnd++;
  }
  const token = body.substring(0, tokenEnd);
  const intent: SlashIntent = {
    command: token.toLowerCase(),
    suffix: body.substring(tokenEnd),
    raw: raw,
    multiline: raw.indexOf('\n') >= 0 || raw.indexOf('\r') >= 0,
    commandLike: token.length === 0 || isCommandLikeToken(token)
  };
  return intent;
}

function sortItems(items: RemoteTimelineItem[]): RemoteTimelineItem[] {
  const sorted = items.slice(0);
  sorted.sort((left: RemoteTimelineItem, right: RemoteTimelineItem): number => {
    if (left.orderSeq !== right.orderSeq) {
      return left.orderSeq - right.orderSeq;
    }
    if (left.updatedSeq !== right.updatedSeq) {
      return left.updatedSeq - right.updatedSeq;
    }
    return left.createdAt.localeCompare(right.createdAt);
  });
  return sorted;
}

function shouldReplaceItem(current: RemoteTimelineItem, incoming: RemoteTimelineItem): boolean {
  if (incoming.revision !== current.revision) {
    return incoming.revision > current.revision;
  }
  return incoming.updatedSeq >= current.updatedSeq;
}

function isRenderableItem(item: RemoteTimelineItem): boolean {
  if (item.type !== 'message') {
    return item.text.length > 0;
  }
  if (item.text.trim().length > 0) {
    return true;
  }
  return item.attachments.length > 0;
}

function eventCursorSequenceOrNull(cursor: string): number | null {
  const withoutPrefix = cursor.startsWith('seq:') ? cursor.substring(4) : cursor;
  if (withoutPrefix.length === 0) {
    return null;
  }
  const parsed = Number(withoutPrefix);
  if (!Number.isFinite(parsed) || parsed < 0) {
    return null;
  }
  return parsed;
}

function eventCursorSequence(cursor: string): number {
  return eventCursorSequenceOrNull(cursor) ?? 0;
}

function laterEventCursor(current: string, incoming: string): string {
  const currentSequence = eventCursorSequence(current);
  const incomingSequence = eventCursorSequenceOrNull(incoming);
  if (incomingSequence === null) {
    return current;
  }
  return incomingSequence >= currentSequence ? incoming : current;
}

// Mirrors Android RealtimeRetry.reconnectDelayMillis: exponential backoff with
// a 30s cap and ±25% jitter, no retry limit.
function reconnectDelayMs(attempt: number): number {
  const safeAttempt = attempt < 0 ? 0 : attempt;
  const exponent = safeAttempt > 5 ? 5 : safeAttempt;
  const base = Math.min(RETRY_BASE_DELAY_MS * (1 << exponent), RETRY_MAX_DELAY_MS);
  const jitter = Math.floor(base * 0.25 * Math.random());
  return Math.min(base + jitter, RETRY_MAX_DELAY_MS);
}

@Component
export struct SessionDetailPage {
  @State loading: boolean = true;
  @State errorMessage: string = '';
  @State title: string = 'Session';
  @State runtimeLabel: string = '';
  @State statusLabel: string = 'idle';
  @State entries: TimelineEntry[] = [];
  @State notices: RemoteRuntimeNotice[] = [];
  @State composerInput: string = '';
  @State commandSuggestions: RemoteRuntimeCommand[] = [];
  @State attachmentPanelOpen: boolean = false;
  @State attachmentUrlInput: string = '';
  @State uploadingAttachment: boolean = false;
  @State pendingAttachments: RemoteUploadedAttachment[] = [];
  @State sending: boolean = false;
  @State interrupting: boolean = false;
  @State executingCommand: boolean = false;
  @State respondingNoticeId: string = '';
  @State realtimeConnected: boolean = false;
  @State hasMoreHistory: boolean = false;
  @State loadingHistory: boolean = false;
  @State canInterrupt: boolean = false;
  private sessionId: string = '';
  private session: RemoteSession | null = null;
  private items: RemoteTimelineItem[] = [];
  private commands: RemoteRuntimeCommand[] = [];
  private eventCursor: string = '';
  private timelineEventCursor: string = 'seq:0';
  private processedEventIds: string[] = [];
  private processedEventIdSet: Set<string> = new Set();
  private pageActive: boolean = false;
  private realtimeRetries: number = 0;
  private retryTimer: number = -1;
  private optCounter: number = 0;
  private navPathStack: NavPathStack = new NavPathStack();
  private scroller: Scroller = new Scroller();
  private socket: RealtimeWebSocket = new RealtimeWebSocket();
  private authStore: AuthSessionStore = AuthSessionStore.getInstance();
  private client: ApiClient = SharedApiClient.getInstance();
  private sessionsApi: SessionsApi = new SessionsApi(this.client);
  private realtimeApi: RealtimeApi = new RealtimeApi(this.client);

  aboutToDisappear(): void {
    this.pageActive = false;
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    this.socket.destroy();
  }

  private serverUrl(): string {
    return this.authStore.readServerUrl();
  }

  private token(): string {
    return this.authStore.readAccessToken();
  }

  private clientId(): string {
    this.optCounter++;
    return `hmos_${Date.now().toString(36)}_${this.optCounter}`;
  }

  private rebuildEntries(): void {
    const entries: TimelineEntry[] = [];
    for (const item of this.items) {
      if (!isRenderableItem(item)) {
        continue;
      }
      const entry: TimelineEntry = {
        item: item,
        blocks: parseMarkdownBlocks(item.text),
        attachments: item.attachments
      };
      entries.push(entry);
    }
    this.entries = entries;
  }

  private syncSessionMeta(session: RemoteSession): void {
    this.session = session;
    const title = session.title === null || session.title.length === 0 ? 'Session' : session.title;
    this.title = title;
    this.runtimeLabel = session.runtimeName;
    this.statusLabel = session.status;
    this.canInterrupt = isBusyStatus(session.status);
  }

  private syncStatus(status: string): void {
    this.statusLabel = status;
    this.canInterrupt = isBusyStatus(status);
  }

  private mergeItems(incoming: RemoteTimelineItem[]): void {
    if (incoming.length === 0) {
      return;
    }
    const map: Map<string, RemoteTimelineItem> = new Map();
    for (const existing of this.items) {
      map.set(existing.id, existing);
    }
    for (const item of incoming) {
      const current = map.get(item.id);
      if (current === undefined || shouldReplaceItem(current, item)) {
        map.set(item.id, item);
      }
      if (item.clientMessageId !== null) {
        for (const existing of map.keys()) {
          if (existing.startsWith(OPTIMISTIC_PREFIX)) {
            const optimistic = map.get(existing);
            if (optimistic !== undefined && optimistic.clientMessageId === item.clientMessageId) {
              map.delete(existing);
            }
          }
        }
      }
    }
    const merged: RemoteTimelineItem[] = [];
    map.forEach((value: RemoteTimelineItem) => {
      merged.push(value);
    });
    this.items = sortItems(merged);
    this.rebuildEntries();
  }

  private replaceItems(items: RemoteTimelineItem[]): void {
    // Preserve in-flight optimistic messages across a full snapshot replace:
    // re-attach those whose clientMessageId is not confirmed by the new list.
    const pendingOptimistic: RemoteTimelineItem[] = [];
    for (const item of this.items) {
      if (item.id.startsWith(OPTIMISTIC_PREFIX)) {
        pendingOptimistic.push(item);
      }
    }
    const confirmedClientMessageIds: Set<string> = new Set();
    for (const item of items) {
      if (item.clientMessageId !== null) {
        confirmedClientMessageIds.add(item.clientMessageId);
      }
    }
    const merged: RemoteTimelineItem[] = items.slice(0);
    for (const item of pendingOptimistic) {
      if (item.clientMessageId !== null && confirmedClientMessageIds.has(item.clientMessageId)) {
        continue;
      }
      merged.push(item);
    }
    this.items = sortItems(merged);
    this.rebuildEntries();
  }

  private async loadSnapshot(): Promise<void> {
    try {
      const snapshot = await this.sessionsApi.getSessionSnapshot(this.serverUrl(), this.token(),
        this.sessionId, 100);
      this.syncSessionMeta(snapshot.session);
      this.replaceItems(snapshot.timelineItems);
      this.eventCursor = snapshot.eventCursor;
      this.timelineEventCursor = snapshot.eventCursor;
      this.hasMoreHistory = snapshot.timelineHasMore;
      this.errorMessage = '';
      this.refreshNotices();
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loading = false;
  }

  private async loadRuntimeState(): Promise<void> {
    try {
      const response = await this.sessionsApi.getSessionRuntimeState(this.serverUrl(), this.token(),
        this.sessionId);
      this.syncStatus(response.state.status);
    } catch (error) {
      return;
    }
  }

  private async loadRuntimeCommands(): Promise<void> {
    try {
      const list = await this.sessionsApi.listRuntimeCommands(this.serverUrl(), this.token(),
        this.sessionId);
      const enabled: RemoteRuntimeCommand[] = [];
      for (const command of list.commands) {
        if (command.enabled) {
          enabled.push(command);
        }
      }
      this.commands = enabled;
    } catch (error) {
      this.commands = [];
    }
  }

  private async loadHistory(): Promise<void> {
    if (this.items.length === 0 || this.loadingHistory) {
      return;
    }
    let beforeOrderSeq = this.items[0].orderSeq;
    for (const item of this.items) {
      if (item.orderSeq < beforeOrderSeq) {
        beforeOrderSeq = item.orderSeq;
      }
    }
    this.loadingHistory = true;
    try {
      const page = await this.sessionsApi.getSessionTimelineHistory(this.serverUrl(), this.token(),
        this.sessionId, beforeOrderSeq, 50);
      this.mergeItems(page.items);
      this.hasMoreHistory = page.hasMore;
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.loadingHistory = false;
  }

  private async refreshNotices(): Promise<void> {
    try {
      const list = await this.sessionsApi.listRuntimeNotices(this.serverUrl(), this.token(),
        this.sessionId);
      const open: RemoteRuntimeNotice[] = [];
      for (const notice of list.notices) {
        if (notice.status === 'open' || notice.status === 'responding') {
          open.push(notice);
        }
      }
      this.notices = open;
    } catch (error) {
      return;
    }
  }

  private async respondNotice(notice: RemoteRuntimeNotice, actionId: string): Promise<void> {
    this.respondingNoticeId = notice.noticeId;
    try {
      const rpc = await this.sessionsApi.respondToRuntimeNotice(this.serverUrl(), this.token(),
        this.sessionId, notice.noticeId, actionId);
      if (!rpc.ok) {
        this.errorMessage = rpc.errorMessage === null ? 'Could not respond to the request.' : rpc.errorMessage;
      }
      await this.refreshNotices();
      await this.loadRuntimeState();
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.respondingNoticeId = '';
  }

  private addOptimisticMessage(content: string, clientMessageId: string,
    attachments: RemoteTimelineAttachment[]): void {
    let maxOrderSeq = 0;
    for (const item of this.items) {
      if (item.orderSeq > maxOrderSeq) {
        maxOrderSeq = item.orderSeq;
      }
    }
    const optimistic: RemoteTimelineItem = {
      id: `${OPTIMISTIC_PREFIX}${clientMessageId}`,
      sessionId: this.sessionId,
      type: 'message',
      status: 'pending',
      role: 'user',
      text: content,
      kind: null,
      clientMessageId: clientMessageId,
      orderSeq: maxOrderSeq + 1,
      revision: 1,
      updatedSeq: 0,
      createdAt: new Date().toISOString(),
      contentHash: '',
      attachments: attachments
    };
    this.mergeItems([optimistic]);
  }

  private removeOptimisticMessage(clientMessageId: string): void {
    const remaining: RemoteTimelineItem[] = [];
    for (const item of this.items) {
      if (item.id.startsWith(OPTIMISTIC_PREFIX) && item.clientMessageId === clientMessageId) {
        continue;
      }
      remaining.push(item);
    }
    this.items = remaining;
    this.rebuildEntries();
  }

  private commandMatchesPrefix(command: RemoteRuntimeCommand, prefix: string): boolean {
    if (prefix.length === 0) {
      return true;
    }
    if (command.id.toLowerCase().startsWith(prefix)) {
      return true;
    }
    if (command.title.toLowerCase().startsWith(prefix)) {
      return true;
    }
    for (const alias of command.aliases) {
      if (alias.toLowerCase().startsWith(prefix)) {
        return true;
      }
    }
    return false;
  }

  private updateCommandSuggestions(): void {
    const suggestions: RemoteRuntimeCommand[] = [];
    const intent = parseSlashIntent(this.composerInput);
    if (intent !== null && !intent.multiline && intent.commandLike &&
      intent.suffix.length === 0 && this.commands.length > 0) {
      for (const command of this.commands) {
        if (this.commandMatchesPrefix(command, intent.command)) {
          suggestions.push(command);
          if (suggestions.length >= MAX_SUGGESTIONS) {
            break;
          }
        }
      }
    }
    this.commandSuggestions = suggestions;
  }

  private exactCommand(intent: SlashIntent): RemoteRuntimeCommand | null {
    if (intent.command.length === 0) {
      return null;
    }
    for (const command of this.commands) {
      if (command.id.toLowerCase() === intent.command) {
        return command;
      }
      for (const alias of command.aliases) {
        if (alias.toLowerCase() === intent.command) {
          return command;
        }
      }
    }
    return null;
  }

  private commandResultText(result: RemoteCommandResult): string {
    const stateLabel = result.executionState === 'completed' ? 'Completed'
      : (result.executionState === 'accepted' ? 'Accepted' : 'Unknown');
    if (!result.ok) {
      const code = result.code.length > 0 ? ` (${result.code})` : '';
      return `${stateLabel}${code}: ${result.message}`;
    }
    return result.message.length > 0 ? result.message : stateLabel;
  }

  private showCommandResult(command: RemoteRuntimeCommand, result: RemoteCommandResult): void {
    AlertDialog.show({
      title: `/${command.id}`,
      message: this.commandResultText(result),
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

  private async runCommand(command: RemoteRuntimeCommand, intent: SlashIntent): Promise<void> {
    const suffix = intent.suffix.trim();
    if (suffix.length > 0 && !command.acceptsArgs) {
      this.errorMessage = `/${command.id} does not accept arguments.`;
      return;
    }
    const args: string[] = [];
    if (suffix.length > 0) {
      if (command.argsSchemaType === 'string') {
        const first = intent.suffix.charAt(0);
        const value = first === ' ' || first === '\t' ? intent.suffix.substring(1) : intent.suffix;
        args.push(value);
      } else {
        const words = suffix.split(/\s+/);
        for (const word of words) {
          if (word.length > 0) {
            args.push(word);
          }
        }
      }
    }
    this.executingCommand = true;
    try {
      const result = await this.sessionsApi.executeRuntimeCommand(this.serverUrl(), this.token(),
        this.sessionId, command.id, args, intent.raw);
      this.composerInput = '';
      this.commandSuggestions = [];
      this.showCommandResult(command, result);
      await this.loadRuntimeState();
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.executingCommand = false;
  }

  private restorePendingAttachments(attachments: RemoteTimelineAttachment[]): void {
    const restored: RemoteUploadedAttachment[] = [];
    for (const attachment of attachments) {
      const uploaded: RemoteUploadedAttachment = {
        fileId: attachment.fileId,
        name: attachment.name,
        mediaType: attachment.mediaType,
        size: attachment.size,
        sha256: attachment.sha256 === null ? '' : attachment.sha256
      };
      restored.push(uploaded);
    }
    this.pendingAttachments = restored;
  }

  private async sendMessage(): Promise<void> {
    const content = this.composerInput.trim();
    if ((content.length === 0 && this.pendingAttachments.length === 0) ||
      this.sending || this.executingCommand) {
      return;
    }
    if (content.startsWith('/')) {
      const intent = parseSlashIntent(content);
      if (intent !== null && !intent.multiline && intent.commandLike) {
        const command = this.exactCommand(intent);
        if (command !== null) {
          await this.runCommand(command, intent);
          return;
        }
      }
    }
    const clientMessageId = this.clientId();
    this.sending = true;
    this.composerInput = '';
    this.commandSuggestions = [];
    const attachmentFileIds: string[] = [];
    const optimisticAttachments: RemoteTimelineAttachment[] = [];
    for (const attachment of this.pendingAttachments) {
      attachmentFileIds.push(attachment.fileId);
      const timelineAttachment: RemoteTimelineAttachment = {
        fileId: attachment.fileId,
        name: attachment.name,
        mediaType: attachment.mediaType,
        size: attachment.size,
        sha256: attachment.sha256
      };
      optimisticAttachments.push(timelineAttachment);
    }
    this.pendingAttachments = [];
    this.addOptimisticMessage(content, clientMessageId, optimisticAttachments);
    this.scrollToBottom();
    try {
      const rpc = await this.sessionsApi.sendSessionMessage(this.serverUrl(), this.token(),
        this.sessionId, content, clientMessageId, attachmentFileIds);
      if (!rpc.ok) {
        throw new Error(rpc.errorMessage === null ? 'Could not send the message.' : rpc.errorMessage);
      }
      this.errorMessage = '';
    } catch (error) {
      this.composerInput = content;
      this.restorePendingAttachments(optimisticAttachments);
      this.removeOptimisticMessage(clientMessageId);
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.sending = false;
  }

  private async addAttachmentFromUrl(): Promise<void> {
    const url = this.attachmentUrlInput.trim();
    if (this.uploadingAttachment || url.length === 0) {
      return;
    }
    if (this.pendingAttachments.length >= MAX_PENDING_ATTACHMENTS) {
      this.errorMessage = `A message can carry at most ${MAX_PENDING_ATTACHMENTS} attachments.`;
      return;
    }
    this.uploadingAttachment = true;
    try {
      const response = await this.sessionsApi.uploadExternalFileAsAttachment(this.serverUrl(), this.token(),
        this.sessionId, url);
      if (response.attachments.length === 0) {
        throw new Error('The server did not accept the file.');
      }
      const updated = this.pendingAttachments.slice(0);
      updated.push(response.attachments[0]);
      this.pendingAttachments = updated;
      this.attachmentUrlInput = '';
      this.errorMessage = '';
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.uploadingAttachment = false;
  }

  private removePendingAttachment(fileId: string): void {
    const remaining: RemoteUploadedAttachment[] = [];
    for (const attachment of this.pendingAttachments) {
      if (attachment.fileId !== fileId) {
        remaining.push(attachment);
      }
    }
    this.pendingAttachments = remaining;
  }

  private async interruptRuntime(): Promise<void> {
    if (this.interrupting) {
      return;
    }
    this.interrupting = true;
    try {
      const rpc = await this.sessionsApi.interruptSession(this.serverUrl(), this.token(), this.sessionId);
      if (!rpc.ok) {
        this.errorMessage = rpc.errorMessage === null ? 'Could not interrupt.' : rpc.errorMessage;
      }
    } catch (error) {
      this.errorMessage = errorMessageFrom(error as Object);
    }
    this.interrupting = false;
  }

  private scrollToBottom(): void {
    setTimeout(() => {
      this.scroller.scrollEdge(Edge.Bottom);
    }, 120);
  }

  private rememberProcessedEvent(eventId: string): boolean {
    if (this.processedEventIdSet.has(eventId)) {
      return false;
    }
    this.processedEventIdSet.add(eventId);
    this.processedEventIds.push(eventId);
    if (this.processedEventIds.length > MAX_PROCESSED_EVENT_IDS) {
      const evicted = this.processedEventIds.splice(0,
        this.processedEventIds.length - RETAINED_PROCESSED_EVENT_IDS);
      for (const id of evicted) {
        this.processedEventIdSet.delete(id);
      }
    }
    return true;
  }

  private applyEvent(envelope: RemoteSessionEventEnvelope): void {
    if (envelope.protocolVersion !== '1.0' || envelope.sessionId !== this.sessionId) {
      return;
    }
    if (!this.rememberProcessedEvent(envelope.eventId)) {
      return;
    }
    const payload = envelope.payload;
    if (payload.session !== null) {
      this.syncSessionMeta(payload.session);
    }
    if (envelope.type === 'timeline.snapshot') {
      // A snapshot may only clobber the timeline when it is at least as new as
      // what we already hold (mirrors Android's sequence guard).
      const currentTimelineSequence = eventCursorSequence(this.timelineEventCursor);
      if (envelope.sequence >= currentTimelineSequence) {
        this.replaceItems(payload.items);
        this.timelineEventCursor = laterEventCursor(this.timelineEventCursor, envelope.cursor);
      }
    } else if (payload.items.length > 0) {
      this.mergeItems(payload.items);
      this.timelineEventCursor = laterEventCursor(this.timelineEventCursor, envelope.cursor);
      this.scrollToBottom();
    } else if (payload.item !== null) {
      this.mergeItems([payload.item]);
      this.timelineEventCursor = laterEventCursor(this.timelineEventCursor, envelope.cursor);
      this.scrollToBottom();
    }
    if (payload.state !== null) {
      this.syncStatus(payload.state.status);
    }
    if (envelope.type.indexOf('runtime.notice') === 0) {
      this.refreshNotices();
    }
    const cursor = payload.eventCursor;
    if (cursor !== null && cursor.length > 0) {
      this.eventCursor = cursor;
    } else if (envelope.cursor.length > 0) {
      this.eventCursor = envelope.cursor;
    }
  }

  private async recoverMissedEvents(): Promise<void> {
    if (this.eventCursor.length === 0) {
      return;
    }
    try {
      const recovery = await this.realtimeApi.recoverSessionEvents(this.serverUrl(), this.token(),
        this.sessionId, this.eventCursor);
      for (const event of recovery.events) {
        this.applyEvent(event);
      }
      if (recovery.snapshotRequired) {
        await this.loadSnapshot();
      }
    } catch (error) {
      return;
    }
  }

  private async connectRealtime(): Promise<void> {
    if (!this.pageActive || this.sessionId.length === 0) {
      return;
    }
    try {
      const ticket = await this.realtimeApi.createSessionTicket(this.serverUrl(), this.token(),
        this.clientId(), this.sessionId);
      // The ticket round-trip may outlive the page: never create a socket
      // (and leak its listeners) after aboutToDisappear has run.
      if (!this.pageActive) {
        return;
      }
      const url = this.realtimeApi.sessionWebSocketUrl(this.serverUrl(), this.sessionId, ticket.ticket);
      this.socket.connect(url, this.createSocketListener());
    } catch (error) {
      this.scheduleRealtimeRetry();
    }
  }

  private createSocketListener(): RealtimeSocketListener {
    const listener: RealtimeSocketListener = {
      onOpen: (): void => {
        this.realtimeConnected = true;
        this.realtimeRetries = 0;
        this.recoverMissedEvents();
      },
      onMessage: (text: string): void => {
        const envelope = this.realtimeApi.parseSessionMessage(text);
        if (envelope !== null) {
          this.applyEvent(envelope);
        }
      },
      onClose: (code: number, reason: string): void => {
        this.realtimeConnected = false;
        this.scheduleRealtimeRetry();
      },
      onError: (message: string): void => {
        this.realtimeConnected = false;
        this.scheduleRealtimeRetry();
      }
    };
    return listener;
  }

  private scheduleRealtimeRetry(): void {
    if (!this.pageActive) {
      return;
    }
    if (this.retryTimer >= 0) {
      return;
    }
    const attempt = this.realtimeRetries;
    this.realtimeRetries++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.connectRealtime();
    }, reconnectDelayMs(attempt));
  }

  private statusColor(): string {
    if (this.statusLabel === 'running' || this.statusLabel === 'pending' || this.statusLabel === 'waiting') {
      return '#2563EB';
    }
    if (this.statusLabel === 'waiting_approval' || this.statusLabel === 'blocked') {
      return '#D97706';
    }
    if (this.statusLabel === 'error' || this.statusLabel === 'failed') {
      return '#DC2626';
    }
    return '#16A34A';
  }

  private itemLabelColor(status: string): string {
    if (status === 'failed' || status === 'cancelled' || status === 'interrupted') {
      return '#DC2626';
    }
    if (status === 'running' || status === 'pending') {
      return '#2563EB';
    }
    return '#9CA3AF';
  }

  private itemRunning(status: string): boolean {
    return status === 'running' || status === 'pending';
  }

  private noticeSeverityColor(severity: string): string {
    if (severity === 'error') {
      return '#DC2626';
    }
    if (severity === 'warning') {
      return '#D97706';
    }
    if (severity === 'success') {
      return '#16A34A';
    }
    return '#2563EB';
  }

  private actionStyleColor(style: string): string {
    if (style === 'primary') {
      return '#2563EB';
    }
    if (style === 'danger') {
      return '#DC2626';
    }
    return '#4B5563';
  }

  private actionStyleBackground(style: string): string {
    if (style === 'primary') {
      return '#DBEAFE';
    }
    if (style === 'danger') {
      return '#FEE2E2';
    }
    return '#F3F4F6';
  }

  private realtimeDotColor(): string {
    return this.realtimeConnected ? '#22C55E' : '#D1D5DB';
  }

  private realtimeStatusLabel(): string {
    return this.realtimeConnected ? 'live' : 'offline';
  }

  private historyButtonLabel(): string {
    return this.loadingHistory ? 'Loading…' : 'Load earlier messages';
  }

  private interruptButtonLabel(): string {
    return this.interrupting ? '…' : '■';
  }

  private sendButtonLabel(): string {
    return this.sending ? '…' : '➤';
  }

  private attachmentButtonLabel(): string {
    return this.attachmentPanelOpen ? '×' : '＋';
  }

  private attachmentButtonBackground(): string {
    return this.attachmentPanelOpen ? '#E5E7EB' : '#F3F4F6';
  }

  private attachmentUploadLabel(): string {
    return this.uploadingAttachment ? '…' : 'Add';
  }

  private noticeTypeLabel(notice: RemoteRuntimeNotice): string {
    if (notice.interactionType === null || notice.interactionType.length === 0) {
      return notice.type;
    }
    return notice.interactionType;
  }

  private isImageAttachment(attachment: RemoteTimelineAttachment): boolean {
    return attachment.mediaType.startsWith('image/');
  }

  private attachmentSizeLabel(size: number): string {
    if (size >= 1048576) {
      const mb = Math.round(size / 104857.6) / 10;
      return `${mb} MB`;
    }
    if (size >= 1024) {
      const kb = Math.round(size / 102.4) / 10;
      return `${kb} KB`;
    }
    return `${size} B`;
  }

  @Builder
  attachmentView(attachment: RemoteTimelineAttachment) {
    if (this.isImageAttachment(attachment)) {
      AttachmentImageView({
        sessionId: this.sessionId,
        fileId: attachment.fileId
      })
    } else {
      Row({ space: 6 }) {
        Text('FILE')
          .fontSize(9)
          .fontColor('#6B7280')
          .padding({ left: 4, right: 4, top: 1, bottom: 1 })
          .borderRadius(3)
          .backgroundColor('#E5E7EB')
        Column({ space: 2 }) {
          Text(attachment.name)
            .fontSize(13)
            .fontColor('#1F2937')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
          Text(this.attachmentSizeLabel(attachment.size))
            .fontSize(11)
            .fontColor('#6B7280')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding(8)
      .borderRadius(8)
      .backgroundColor('rgba(0,0,0,0.06)')
    }
  }

  @Builder
  userContentView(entry: TimelineEntry) {
    Column({ space: 6 }) {
      ForEach(entry.attachments, (attachment: RemoteTimelineAttachment) => {
        this.attachmentView(attachment)
      }, (attachment: RemoteTimelineAttachment) => attachment.fileId)
      if (entry.blocks.length > 0) {
        AgentMarkdownView({
          blocks: entry.blocks,
          textColor: '#FFFFFF',
          linkColor: '#BFDBFE',
          inlineCodeColor: '#DBEAFE',
          codePanelColor: '#1E3A8A',
          codePanelTextColor: '#E5E7EB',
          fontSize: 15
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxWidth: '85%' })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor('#2563EB')
  }

  @Builder
  assistantContentView(entry: TimelineEntry) {
    Column({ space: 6 }) {
      ForEach(entry.attachments, (attachment: RemoteTimelineAttachment) => {
        this.attachmentView(attachment)
      }, (attachment: RemoteTimelineAttachment) => attachment.fileId)
      if (entry.blocks.length > 0) {
        AgentMarkdownView({
          blocks: entry.blocks,
          textColor: '#1F2937',
          linkColor: '#2563EB',
          inlineCodeColor: '#C2410C',
          codePanelColor: '#1F2937',
          codePanelTextColor: '#E5E7EB',
          fontSize: 15
        })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .constraintSize({ maxWidth: '85%' })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .borderRadius(12)
    .backgroundColor('#F2F3F5')
  }

  @Builder
  entryView(entry: TimelineEntry) {
    if (entry.item.type === 'message') {
      if (entry.item.role === 'user') {
        Row() {
          this.userContentView(entry)
        }
        .width('100%')
        .justifyContent(FlexAlign.End)
        .padding({ left: 32, right: 12, top: 2, bottom: 2 })
      } else if (entry.item.role === 'assistant') {
        Row() {
          this.assistantContentView(entry)
        }
        .width('100%')
        .justifyContent(FlexAlign.Start)
        .padding({ left: 12, right: 32, top: 2, bottom: 2 })
      } else {
        Text(entry.item.text)
          .fontSize(12)
          .fontColor('#9CA3AF')
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
      }
    } else {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(entry.item.type)
              .fontSize(10)
              .fontColor(this.itemLabelColor(entry.item.status))
              .padding({ left: 6, right: 6, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor('#F3F4F6')
            if (this.itemRunning(entry.item.status)) {
              LoadingProgress()
                .width(12)
                .height(12)
            }
          }
          Text(entry.item.text)
            .fontSize(13)
            .fontColor('#4B5563')
            .maxLines(8)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .padding(10)
      .borderRadius(10)
      .backgroundColor('#FAFAFA')
      .border({ width: 1, color: '#F0F0F0' })
    }
  }

  @Builder
  noticeView(notice: RemoteRuntimeNotice) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Circle()
          .width(8)
          .height(8)
          .fill(this.noticeSeverityColor(notice.severity))
        Text(notice.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
        Text(this.noticeTypeLabel(notice))
          .fontSize(11)
          .fontColor(this.noticeSeverityColor(notice.severity))
      }
      .width('100%')
      if (notice.message !== null && notice.message.length > 0) {
        Text(notice.message)
          .fontSize(13)
          .fontColor('#4B5563')
          .width('100%')
      }
      Row({ space: 8 }) {
        ForEach(notice.actions, (action: RemoteNoticeAction) => {
          Button(action.label)
            .fontSize(13)
            .height(34)
            .padding({ left: 14, right: 14 })
            .fontColor(this.actionStyleColor(action.style))
            .backgroundColor(this.actionStyleBackground(action.style))
            .enabled(this.respondingNoticeId !== notice.noticeId)
            .onClick(() => {
              this.respondNotice(notice, action.actionId);
            })
        }, (action: RemoteNoticeAction) => action.actionId)
        if (this.respondingNoticeId === notice.noticeId) {
          LoadingProgress()
            .width(18)
            .height(18)
        }
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .borderRadius(12)
    .backgroundColor('#FFFBEB')
    .border({ width: 1, color: '#FDE68A' })
  }

  build() {
    NavDestination() {
      Column() {
        Row({ space: 8 }) {
          Text(`${this.runtimeLabel} · ${this.statusLabel}`)
            .fontSize(12)
            .fontColor(this.statusColor())
            .layoutWeight(1)
          Circle()
            .width(8)
            .height(8)
            .fill(this.realtimeDotColor())
          Text(this.realtimeStatusLabel())
            .fontSize(11)
            .fontColor('#9CA3AF')
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
        } else {
          List({ space: 4, scroller: this.scroller }) {
            if (this.hasMoreHistory) {
              ListItem() {
                Button(this.historyButtonLabel())
                  .fontSize(12)
                  .height(30)
                  .backgroundColor('#F3F4F6')
                  .fontColor('#374151')
                  .enabled(!this.loadingHistory)
                  .onClick(() => {
                    this.loadHistory();
                  })
              }
              .width('100%')
            }
            if (this.entries.length === 0) {
              ListItem() {
                Text('No messages yet. Say hello to start.')
                  .fontSize(14)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 24, bottom: 24 })
              }
            }
            ForEach(this.entries, (entry: TimelineEntry) => {
              ListItem() {
                this.entryView(entry)
              }
            }, (entry: TimelineEntry) => `${entry.item.id}_${entry.item.revision}_${entry.item.updatedSeq}`)
            ForEach(this.notices, (notice: RemoteRuntimeNotice) => {
              ListItem() {
                this.noticeView(notice)
              }
            }, (notice: RemoteRuntimeNotice) => notice.noticeId)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 8, right: 8, top: 4 })
        }
        if (this.commandSuggestions.length > 0) {
          Column() {
            ForEach(this.commandSuggestions, (command: RemoteRuntimeCommand) => {
              Row({ space: 8 }) {
                Text(`/${command.id}`)
                  .fontSize(13)
                  .fontColor('#1F2937')
                  .fontFamily('monospace')
                Text(command.title)
                  .fontSize(12)
                  .fontColor('#6B7280')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 12, right: 12, top: 8, bottom: 8 })
              .onClick(() => {
                this.applySuggestion(command);
              })
            }, (command: RemoteRuntimeCommand) => command.id)
          }
          .width('100%')
          .padding({ left: 12, right: 12 })
          .borderRadius(10)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E5E7EB' })
        }
        if (this.pendingAttachments.length > 0) {
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.pendingAttachments, (attachment: RemoteUploadedAttachment) => {
              Row({ space: 4 }) {
                Text(attachment.name)
                  .fontSize(11)
                  .fontColor('#1F2937')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .constraintSize({ maxWidth: 140 })
                Text('✕')
                  .fontSize(11)
                  .fontColor('#6B7280')
                  .padding({ left: 2, right: 2 })
                  .onClick(() => {
                    this.removePendingAttachment(attachment.fileId);
                  })
              }
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(12)
              .backgroundColor('#E5E7EB')
              .margin({ right: 6, bottom: 4 })
            }, (attachment: RemoteUploadedAttachment) => attachment.fileId)
          }
          .width('100%')
          .padding({ left: 12, right: 12, top: 4 })
        }
        if (this.attachmentPanelOpen) {
          Column({ space: 8 }) {
            Text('Add an attachment from a direct file URL (max 25 MB).')
              .fontSize(11)
              .fontColor('#6B7280')
              .width('100%')
            Row({ space: 8 }) {
              TextInput({ text: this.attachmentUrlInput, placeholder: 'https://example.com/image.png' })
                .fontSize(13)
                .height(36)
                .layoutWeight(1)
                .backgroundColor('#F8FAFC')
                .borderRadius(18)
                .padding({ left: 12, right: 12 })
                .onChange((value: string) => {
                  this.attachmentUrlInput = value;
                })
              Button(this.attachmentUploadLabel())
                .fontSize(13)
                .height(36)
                .padding({ left: 14, right: 14 })
                .backgroundColor('#2563EB')
                .fontColor('#FFFFFF')
                .enabled(!this.uploadingAttachment)
                .onClick(() => {
                  this.addAttachmentFromUrl();
                })
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
            Text('Uploading files from this device is not available yet.')
              .fontSize(11)
              .fontColor('#9CA3AF')
              .width('100%')
          }
          .width('100%')
          .padding(12)
          .borderRadius(10)
          .backgroundColor('#FFFFFF')
          .border({ width: 1, color: '#E5E7EB' })
        }
        Row({ space: 8 }) {
          Button(this.attachmentButtonLabel())
            .fontSize(16)
            .width(36)
            .height(36)
            .borderRadius(18)
            .backgroundColor(this.attachmentButtonBackground())
            .fontColor('#374151')
            .onClick(() => {
              this.attachmentPanelOpen = !this.attachmentPanelOpen;
            })
          TextArea({ text: this.composerInput, placeholder: 'Message the agent…' })
            .fontSize(14)
            .height(40)
            .layoutWeight(1)
            .backgroundColor('#F8FAFC')
            .borderRadius(20)
            .padding({ left: 12, right: 12, top: 8 })
            .onChange((value: string) => {
              this.composerInput = value;
              this.updateCommandSuggestions();
            })
          if (this.canInterrupt) {
            Button(this.interruptButtonLabel())
              .fontSize(16)
              .width(40)
              .height(40)
              .borderRadius(20)
              .backgroundColor('#FEE2E2')
              .fontColor('#DC2626')
              .enabled(!this.interrupting)
              .onClick(() => {
                this.interruptRuntime();
              })
          } else {
            Button(this.sendButtonLabel())
              .fontSize(16)
              .width(40)
              .height(40)
              .borderRadius(20)
              .backgroundColor('#2563EB')
              .fontColor('#FFFFFF')
              .enabled(!this.sending && !this.executingCommand)
              .onClick(() => {
                this.sendMessage();
              })
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 12, top: 8, bottom: 12 })
      }
      .width('100%')
      .height('100%')
    }
    .title(this.title)
    .onReady((ctx: NavDestinationContext) => {
      this.navPathStack = ctx.pathStack;
      const raw = ctx.pathInfo.param as string;
      if (typeof raw === 'string' && raw.length > 0) {
        this.sessionId = raw;
      }
      if (this.sessionId.length > 0) {
        this.pageActive = true;
        this.loadSnapshot();
        this.loadRuntimeState();
        this.loadRuntimeCommands();
        this.connectRealtime();
      } else {
        this.errorMessage = 'Missing session.';
        this.loading = false;
      }
    })
  }

  private applySuggestion(command: RemoteRuntimeCommand): void {
    const separator = command.acceptsArgs ? ' ' : '';
    this.composerInput = `/${command.id}${separator}`;
    this.commandSuggestions = [];
  }
}

@Builder
export function SessionDetailPageBuilder() {
  SessionDetailPage()
}
