import { ApiClient } from './ApiClient';
import { objGetArray, objGetBool, objGetOptString, objGetString, recordsFromArray } from '../common/Json';

export interface RemoteDevice {
  id: string;
  name: string;
  deviceOs: string | null;
  status: string;
  lastSeenAt: string | null;
  createdAt: string | null;
  updatedAt: string | null;
}

export interface RemoteDeviceCredential {
  device: RemoteDevice;
  deviceToken: string;
  tokenPrefix: string | null;
}

export interface RemoteDeviceRuntime {
  connectorId: string;
  runtimeId: string;
  runtimeType: string;
  displayName: string;
  present: boolean;
  configured: boolean;
  active: boolean;
  status: string;
  lastDiscoveredAt: string | null;
  updatedAt: string | null;
}

export interface RemoteDeviceRuntimeList {
  connectorId: string;
  runtimes: RemoteDeviceRuntime[];
  serverTime: string | null;
}

const RUNTIME_TYPE_PATTERN = /^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)*$/;
const RUNTIME_INSTANCE_PATTERN = /^rti_[A-Za-z0-9_-]{1,124}$/;

export function isValidRuntimeType(value: string): boolean {
  return value.length >= 1 && value.length <= 64 && !value.startsWith('rti_') &&
    RUNTIME_TYPE_PATTERN.test(value);
}

export function isValidRuntimeInstanceId(value: string, runtimeType: string): boolean {
  return value === runtimeType || (value.length <= 128 && RUNTIME_INSTANCE_PATTERN.test(value));
}

export function parseRemoteDevice(value: Record<string, Object>): RemoteDevice {
  const name = objGetOptString(value, 'name');
  const device: RemoteDevice = {
    id: objGetString(value, 'id', ''),
    name: name === null ? 'Device' : name,
    deviceOs: objGetOptString(value, 'deviceOs'),
    status: objGetString(value, 'status', 'offline'),
    lastSeenAt: objGetOptString(value, 'lastSeenAt'),
    createdAt: objGetOptString(value, 'createdAt'),
    updatedAt: objGetOptString(value, 'updatedAt')
  };
  return device;
}

export function parseRemoteDeviceRuntime(value: Record<string, Object>, fallbackConnectorId: string): RemoteDeviceRuntime {
  const legacyRuntime = objGetOptString(value, 'runtime');
  const runtimeId = objGetOptString(value, 'runtimeId') ?? legacyRuntime ?? '';
  const reportedRuntimeType = objGetOptString(value, 'runtimeType');
  const runtimeType = legacyRuntime ?? (isValidRuntimeType(runtimeId) ? runtimeId : (reportedRuntimeType ?? ''));
  const connectorIdRaw = objGetString(value, 'connectorId', fallbackConnectorId);
  const runtime: RemoteDeviceRuntime = {
    connectorId: connectorIdRaw.length > 0 ? connectorIdRaw : fallbackConnectorId,
    runtimeId: runtimeId,
    runtimeType: runtimeType,
    displayName: objGetOptString(value, 'displayName') ?? objGetOptString(value, 'name') ?? runtimeType,
    present: objGetBool(value, 'present', false),
    configured: objGetBool(value, 'configured', false),
    active: objGetBool(value, 'active', false),
    status: objGetString(value, 'status', 'unknown'),
    lastDiscoveredAt: objGetOptString(value, 'lastDiscoveredAt'),
    updatedAt: objGetOptString(value, 'updatedAt')
  };
  return runtime;
}

export function parseRemoteDeviceRuntimeList(value: Record<string, Object>, deviceId: string): RemoteDeviceRuntimeList {
  const connectorIdRaw = objGetString(value, 'connectorId', deviceId);
  const connectorId = connectorIdRaw.length > 0 ? connectorIdRaw : deviceId;
  const runtimes: RemoteDeviceRuntime[] = [];
  for (const item of recordsFromArray(objGetArray(value, 'runtimes'))) {
    const runtime = parseRemoteDeviceRuntime(item, connectorId);
    if (isValidRuntimeType(runtime.runtimeType) &&
      isValidRuntimeInstanceId(runtime.runtimeId, runtime.runtimeType)) {
      runtimes.push(runtime);
    }
  }
  const list: RemoteDeviceRuntimeList = {
    connectorId: connectorId,
    runtimes: runtimes,
    serverTime: objGetOptString(value, 'serverTime')
  };
  return list;
}

export class DevicesApi {
  private readonly client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  async listDevices(serverUrl: string, authorizationToken: string): Promise<RemoteDevice[]> {
    const response = await this.client.getJson(serverUrl, '/connectors', authorizationToken);
    const devices: RemoteDevice[] = [];
    for (const item of recordsFromArray(objGetArray(response, 'connectors'))) {
      devices.push(parseRemoteDevice(item));
    }
    return devices;
  }

  async getDevice(serverUrl: string, authorizationToken: string, deviceId: string): Promise<RemoteDevice> {
    const response = await this.client.getJson(serverUrl,
      `/connectors/${encodeURIComponent(deviceId)}`, authorizationToken);
    return parseRemoteDevice(requireConnector(response));
  }

  async createDevice(serverUrl: string, authorizationToken: string,
    name: string): Promise<RemoteDeviceCredential> {
    const body: Record<string, Object> = { 'name': name };
    const response = await this.client.postJson(serverUrl, '/connectors', body, authorizationToken);
    return parseRemoteDeviceCredential(response);
  }

  async updateDevice(serverUrl: string, authorizationToken: string, deviceId: string,
    name: string): Promise<RemoteDevice> {
    const body: Record<string, Object> = { 'name': name };
    const response = await this.client.patchJson(serverUrl,
      `/connectors/${encodeURIComponent(deviceId)}`, body, authorizationToken);
    return parseRemoteDevice(requireConnector(response));
  }

  async deleteDevice(serverUrl: string, authorizationToken: string, deviceId: string): Promise<void> {
    await this.client.deleteJson(serverUrl, `/connectors/${encodeURIComponent(deviceId)}`,
      authorizationToken);
  }

  async revokeDevice(serverUrl: string, authorizationToken: string,
    deviceId: string): Promise<RemoteDeviceCredential> {
    const response = await this.client.postJson(serverUrl,
      `/connectors/${encodeURIComponent(deviceId)}/revoke`, null, authorizationToken);
    return parseRemoteDeviceCredential(response);
  }

  async listDeviceRuntimes(serverUrl: string, authorizationToken: string,
    deviceId: string): Promise<RemoteDeviceRuntimeList> {
    const response = await this.client.getJson(serverUrl,
      `/connectors/${encodeURIComponent(deviceId)}/runtimes`, authorizationToken);
    return parseRemoteDeviceRuntimeList(response, deviceId);
  }
}

function requireConnector(response: Record<string, Object>): Record<string, Object> {
  const connector = response['connector'];
  if (typeof connector === 'object' && connector !== null && !Array.isArray(connector)) {
    return connector as Record<string, Object>;
  }
  throw new Error('The server returned an invalid response.');
}

function parseRemoteDeviceCredential(response: Record<string, Object>): RemoteDeviceCredential {
  const credential: RemoteDeviceCredential = {
    device: parseRemoteDevice(requireConnector(response)),
    deviceToken: objGetString(response, 'connectorToken', ''),
    tokenPrefix: objGetOptString(response, 'tokenPrefix')
  };
  return credential;
}
