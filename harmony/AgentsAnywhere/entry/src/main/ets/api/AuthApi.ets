import { ApiClient } from './ApiClient';
import { AuthConfigResponse, AuthMeResponse, OAuthTokenResponse } from './AuthDtos';
import { ApiException } from '../common/ApiException';
import { objGetBool, objGetNumber, objGetOptString, objGetString } from '../common/Json';

export function parseAuthMeResponse(value: Record<string, Object>): AuthMeResponse {
  return {
    userId: objGetString(value, 'userId', ''),
    email: objGetOptString(value, 'email'),
    displayName: objGetString(value, 'displayName', ''),
    emailVerified: objGetBool(value, 'emailVerified', false),
    role: objGetString(value, 'role', ''),
    disabled: objGetBool(value, 'disabled', false),
    serverTime: objGetString(value, 'serverTime', '')
  };
}

export class AuthApi {
  private readonly client: ApiClient;

  constructor(client: ApiClient) {
    this.client = client;
  }

  async me(serverUrl: string, token: string): Promise<AuthMeResponse> {
    const body = await this.client.getJson(serverUrl, '/auth/me', token);
    return parseAuthMeResponse(body);
  }

  async updateDisplayName(serverUrl: string, token: string, displayName: string): Promise<AuthMeResponse> {
    const body: Record<string, Object> = { 'displayName': displayName.trim() };
    const response = await this.client.putJson(serverUrl, '/auth/me/profile', body, token);
    return parseAuthMeResponse(response);
  }

  async changePassword(serverUrl: string, token: string, newPassword: string): Promise<void> {
    const body: Record<string, Object> = { 'newPassword': newPassword };
    await this.client.postJson(serverUrl, '/auth/change-password', body, token);
  }

  async authConfig(serverUrl: string): Promise<AuthConfigResponse> {
    const body = await this.client.getJson(serverUrl, '/auth/config');
    return {
      needsBootstrap: objGetBool(body, 'needsBootstrap', false),
      registrationOpen: objGetBool(body, 'registrationOpen', false),
      oauthRegistrationOpen: objGetBool(body, 'oauthRegistrationOpen', false),
      oauthEnabled: objGetBool(body, 'oauthEnabled', false),
      oauthProviderLabel: objGetOptString(body, 'oauthProviderLabel'),
      setupTokenExpiresAt: objGetOptString(body, 'setupTokenExpiresAt'),
      serverTime: objGetString(body, 'serverTime', ''),
      emailVerificationRequired: objGetBool(body, 'emailVerificationRequired', false)
    };
  }

  async requireHealthyServer(serverUrl: string): Promise<void> {
    const health = await this.client.getJson(serverUrl, '/health');
    if (objGetString(health, 'status', '') !== 'ok') {
      throw new ApiException('The address did not return a healthy Agents Anywhere server.');
    }
  }

  async requireWebLoginHost(webOrigin: string): Promise<void> {
    await this.client.requireHtmlDocument(webOrigin, '/');
  }

  async oauthToken(serverUrl: string, code: string, codeVerifier: string): Promise<OAuthTokenResponse> {
    const fields: Record<string, string> = {
      'grant_type': 'authorization_code',
      'code': code,
      'client_id': 'agents-anywhere-mobile',
      'redirect_uri': 'agents-anywhere://oauth/callback',
      'code_verifier': codeVerifier
    };
    const body = await this.client.postForm(serverUrl, '/oauth/token', fields);
    return {
      accessToken: objGetString(body, 'access_token', ''),
      tokenType: objGetString(body, 'token_type', 'Bearer'),
      expiresIn: objGetNumber(body, 'expires_in', 0),
      scope: objGetString(body, 'scope', ''),
      refreshToken: objGetOptString(body, 'refresh_token')
    };
  }
}
