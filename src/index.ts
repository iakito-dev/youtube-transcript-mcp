import { getTranscript, getTranscriptToolSpec } from './tools/transcript';

export interface Env {
  TRANSCRIPT_CACHE: KVNamespace;
}

const SERVER_INFO = {
  name: 'youtube-transcript-remote',
  version: '1.1.0',
};

/** Protocol revisions this server can speak, newest first. */
const SUPPORTED_PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05'];
const DEFAULT_PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0];

const CORS_HEADERS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers':
    'Content-Type, Accept, Authorization, Cache-Control, Last-Event-ID, MCP-Protocol-Version, Mcp-Session-Id',
  'Access-Control-Expose-Headers': 'Mcp-Session-Id, MCP-Protocol-Version',
  'Access-Control-Max-Age': '86400',
};

type JsonRpcId = string | number | null;

interface JsonRpcMessage {
  jsonrpc?: string;
  id?: JsonRpcId;
  method?: string;
  params?: any;
}

function jsonRpcError(id: JsonRpcId, code: number, message: string) {
  return { jsonrpc: '2.0' as const, id, error: { code, message } };
}

function jsonRpcResult(id: JsonRpcId, result: unknown) {
  return { jsonrpc: '2.0' as const, id, result };
}

/**
 * Handles a single JSON-RPC request. Returns `null` for notifications, which
 * the MCP spec requires the server to acknowledge without a response body.
 */
async function handleMessage(message: JsonRpcMessage, env: Env) {
  const { method, params } = message;
  const id: JsonRpcId = message.id ?? null;
  const isNotification = message.id === undefined || message.id === null;

  // Notifications (initialized, cancelled, progress, ...) get no response.
  if (isNotification) {
    return null;
  }

  switch (method) {
    case 'initialize': {
      // Echo the client's protocol version when we support it, otherwise
      // offer our newest and let the client decide whether to continue.
      const requested = params?.protocolVersion;
      const protocolVersion = SUPPORTED_PROTOCOL_VERSIONS.includes(requested)
        ? requested
        : DEFAULT_PROTOCOL_VERSION;

      return jsonRpcResult(id, {
        protocolVersion,
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
      });
    }

    case 'ping':
      return jsonRpcResult(id, {});

    case 'tools/list':
      return jsonRpcResult(id, { tools: [getTranscriptToolSpec] });

    case 'tools/call': {
      const name = params?.name;
      const args = params?.arguments ?? {};

      if (name !== getTranscriptToolSpec.name) {
        return jsonRpcError(id, -32602, `Unknown tool: ${name}`);
      }

      try {
        const transcript = await getTranscript(args.url, env, args.language ?? 'auto');
        return jsonRpcResult(id, {
          content: [{ type: 'text', text: transcript }],
          isError: false,
        });
      } catch (error) {
        // Tool failures are reported inside the result so the model can see
        // and recover from them, per the MCP tool-error convention.
        const text = error instanceof Error ? error.message : 'Unknown error occurred';
        return jsonRpcResult(id, {
          content: [{ type: 'text', text }],
          isError: true,
        });
      }
    }

    default:
      return jsonRpcError(id, -32601, `Method not found: ${method}`);
  }
}

/** Streamable HTTP endpoint: POST a JSON-RPC message (or batch) to /mcp. */
async function handleStreamableHttp(request: Request, env: Env): Promise<Response> {
  let payload: unknown;

  try {
    payload = await request.json();
  } catch {
    return Response.json(jsonRpcError(null, -32700, 'Parse error'), {
      status: 400,
      headers: CORS_HEADERS,
    });
  }

  const messages = Array.isArray(payload) ? payload : [payload];
  const responses = (
    await Promise.all(messages.map((message) => handleMessage(message as JsonRpcMessage, env)))
  ).filter((response) => response !== null);

  // Every message was a notification or response: acknowledge with no body.
  if (responses.length === 0) {
    return new Response(null, { status: 202, headers: CORS_HEADERS });
  }

  const body = Array.isArray(payload) ? responses : responses[0];

  return Response.json(body, {
    headers: { ...CORS_HEADERS, 'MCP-Protocol-Version': DEFAULT_PROTOCOL_VERSION },
  });
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS_HEADERS });
    }

    if (url.pathname === '/mcp') {
      if (request.method === 'POST') {
        return handleStreamableHttp(request, env);
      }

      // This server is stateless, so it has no server-initiated stream to
      // open (GET) and no session to terminate (DELETE).
      return Response.json(jsonRpcError(null, -32000, 'Method not allowed'), {
        status: 405,
        headers: { ...CORS_HEADERS, Allow: 'POST, OPTIONS' },
      });
    }

    // Deprecated HTTP+SSE transport, kept for older clients such as mcp-remote.
    if (url.pathname === '/sse') {
      if (request.method === 'POST') {
        const response = await handleStreamableHttp(request, env);

        if (response.status === 202) {
          return response;
        }

        const body = await response.text();

        return new Response(`data: ${body}\n\n`, {
          status: response.status,
          headers: {
            ...CORS_HEADERS,
            'Content-Type': 'text/event-stream',
            'Cache-Control': 'no-cache',
          },
        });
      }

      const { readable, writable } = new TransformStream();
      const writer = writable.getWriter();
      const encoder = new TextEncoder();

      ctx.waitUntil(
        (async () => {
          try {
            // The legacy transport expects the POST target up front.
            await writer.write(encoder.encode(`event: endpoint\ndata: ${url.origin}/sse\n\n`));

            const keepAlive = setInterval(() => {
              writer.write(encoder.encode(': keepalive\n\n')).catch(() => {
                clearInterval(keepAlive);
              });
            }, 30000);
          } catch (error) {
            console.error('SSE stream error:', error);
          }
        })()
      );

      return new Response(readable, {
        headers: {
          ...CORS_HEADERS,
          'Content-Type': 'text/event-stream',
          'Cache-Control': 'no-cache',
        },
      });
    }

    if (url.pathname === '/') {
      return Response.json(
        {
          name: 'YouTube Transcript Remote MCP Server',
          version: SERVER_INFO.version,
          description: 'Remote MCP server for extracting YouTube video transcripts',
          endpoints: { mcp: '/mcp', sse: '/sse (deprecated)' },
          protocolVersions: SUPPORTED_PROTOCOL_VERSIONS,
          tools: [getTranscriptToolSpec.name],
          status: 'ready',
        },
        { headers: CORS_HEADERS }
      );
    }

    return new Response('Not Found', { status: 404, headers: CORS_HEADERS });
  },
};
