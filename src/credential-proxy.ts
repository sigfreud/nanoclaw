/**
 * Credential proxy for container isolation.
 * Containers connect here instead of directly to the Anthropic API.
 * The proxy injects real credentials so containers never see them.
 *
 * Two auth modes:
 *   API key:  Proxy injects x-api-key on every request.
 *   OAuth:    Container CLI exchanges its placeholder token for a temp
 *             API key via /api/oauth/claude_cli/create_api_key.
 *             Proxy injects real OAuth token on that exchange request;
 *             subsequent requests carry the temp key which is valid as-is.
 */
import { execFile } from 'child_process';
import fs from 'fs';
import { createServer, Server } from 'http';
import { request as httpsRequest } from 'https';
import { request as httpRequest, RequestOptions } from 'http';
import os from 'os';
import path from 'path';

import { readEnvFile } from './env.js';
import { logger } from './logger.js';

const CREDENTIALS_PATH = path.join(
  process.env.HOME || os.homedir(),
  '.claude',
  '.credentials.json',
);

const REFRESH_SCRIPT = path.join(
  import.meta.dirname,
  '..',
  'scripts',
  'refresh-oauth-token.sh',
);

let refreshInFlight = false;

/**
 * Read the OAuth access token from ~/.claude/.credentials.json.
 * Falls back to .env if the file doesn't exist.
 * This is re-read on every request so token refreshes by `claude` CLI are picked up automatically.
 * If the token is near expiry (<1 hour), triggers an async refresh.
 */
function readOAuthToken(envFallback?: string): string | undefined {
  try {
    if (fs.existsSync(CREDENTIALS_PATH)) {
      const creds = JSON.parse(fs.readFileSync(CREDENTIALS_PATH, 'utf-8'));
      const token = creds?.claudeAiOauth?.accessToken;
      const expiresAt = creds?.claudeAiOauth?.expiresAt;

      // Proactively trigger refresh if token expires within 1 hour
      if (expiresAt && Date.now() > expiresAt - 3_600_000) {
        triggerRefresh();
      }

      if (token) return token;
    }
  } catch (err) {
    logger.debug({ err }, 'Failed to read credentials.json, using .env fallback');
  }
  return envFallback;
}

/** Spawn the refresh script asynchronously (at most one at a time). */
function triggerRefresh(): void {
  if (refreshInFlight) return;
  if (!fs.existsSync(REFRESH_SCRIPT)) return;

  refreshInFlight = true;
  logger.info('OAuth token near expiry, triggering proactive refresh');

  execFile('bash', [REFRESH_SCRIPT], { timeout: 120_000 }, (err, stdout, stderr) => {
    refreshInFlight = false;
    if (err) {
      logger.warn({ err, stderr }, 'Proactive token refresh failed');
    } else {
      logger.info({ stdout: stdout.trim() }, 'Proactive token refresh completed');
    }
  });
}

export type AuthMode = 'api-key' | 'oauth';

export interface ProxyConfig {
  authMode: AuthMode;
}

export function startCredentialProxy(
  port: number,
  host = '127.0.0.1',
): Promise<Server> {
  const secrets = readEnvFile([
    'ANTHROPIC_API_KEY',
    'CLAUDE_CODE_OAUTH_TOKEN',
    'ANTHROPIC_AUTH_TOKEN',
    'ANTHROPIC_BASE_URL',
  ]);

  const authMode: AuthMode = secrets.ANTHROPIC_API_KEY ? 'api-key' : 'oauth';
  const oauthTokenFallback =
    secrets.CLAUDE_CODE_OAUTH_TOKEN || secrets.ANTHROPIC_AUTH_TOKEN;

  const upstreamUrl = new URL(
    secrets.ANTHROPIC_BASE_URL || 'https://api.anthropic.com',
  );
  const isHttps = upstreamUrl.protocol === 'https:';
  const makeRequest = isHttps ? httpsRequest : httpRequest;

  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks);
        const headers: Record<string, string | number | string[] | undefined> =
          {
            ...(req.headers as Record<string, string>),
            host: upstreamUrl.host,
            'content-length': body.length,
          };

        // Strip hop-by-hop headers that must not be forwarded by proxies
        delete headers['connection'];
        delete headers['keep-alive'];
        delete headers['transfer-encoding'];

        if (authMode === 'api-key') {
          // API key mode: inject x-api-key on every request
          delete headers['x-api-key'];
          headers['x-api-key'] = secrets.ANTHROPIC_API_KEY;
        } else {
          // OAuth mode: replace placeholder Bearer token with the real one
          // only when the container actually sends an Authorization header
          // (exchange request + auth probes). Post-exchange requests use
          // x-api-key only, so they pass through without token injection.
          if (headers['authorization']) {
            delete headers['authorization'];
            const token = readOAuthToken(oauthTokenFallback);
            if (token) {
              headers['authorization'] = `Bearer ${token}`;
            }
          }
        }

        const upstream = makeRequest(
          {
            hostname: upstreamUrl.hostname,
            port: upstreamUrl.port || (isHttps ? 443 : 80),
            path: req.url,
            method: req.method,
            headers,
          } as RequestOptions,
          (upRes) => {
            res.writeHead(upRes.statusCode!, upRes.headers);
            upRes.pipe(res);
          },
        );

        upstream.on('error', (err) => {
          logger.error(
            { err, url: req.url },
            'Credential proxy upstream error',
          );
          if (!res.headersSent) {
            res.writeHead(502);
            res.end('Bad Gateway');
          }
        });

        upstream.write(body);
        upstream.end();
      });
    });

    server.listen(port, host, () => {
      logger.info({ port, host, authMode }, 'Credential proxy started');
      resolve(server);
    });

    server.on('error', reject);
  });
}

/** Detect which auth mode the host is configured for. */
export function detectAuthMode(): AuthMode {
  const secrets = readEnvFile(['ANTHROPIC_API_KEY']);
  return secrets.ANTHROPIC_API_KEY ? 'api-key' : 'oauth';
}
