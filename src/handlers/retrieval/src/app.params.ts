export type HttpResponse = {
  statusCode: number;
  headers: Record<string, string>;
  body: string;
};

const baseHeaders = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
};

export function ok(body: unknown): HttpResponse {
  return { statusCode: 200, headers: baseHeaders, body: JSON.stringify(body) };
}

export function notFound(message: string): HttpResponse {
  return { statusCode: 404, headers: baseHeaders, body: JSON.stringify({ error: 'not_found', message }) };
}

export function badRequest(message: string, details?: unknown): HttpResponse {
  return {
    statusCode: 400,
    headers: baseHeaders,
    body: JSON.stringify({ error: 'bad_request', message, details }),
  };
}

export function internalError(message: string): HttpResponse {
  return {
    statusCode: 500,
    headers: baseHeaders,
    body: JSON.stringify({ error: 'internal_error', message }),
  };
}
