import http from 'k6/http';
import { check, sleep } from 'k6';

export const options = {
  vus: 1,
  duration: '5m',
  insecureSkipTLSVerify: true,
};

const BASE_URL = __ENV.BASE_URL || 'https://shopping.local:8443';
const TOKEN_URL =
  __ENV.TOKEN_URL ||
  'https://auth.local:8443/auth/realms/devops-lvlup/protocol/openid-connect/token';

const USERNAME = __ENV.USERNAME;
const PASSWORD = __ENV.PASSWORD;
const RUN_ID = __ENV.RUN_ID || `run-${Date.now()}`;

let vuToken = null;

function getAccessToken() {
  const payload = {
    client_id: 'k6-cli',
    username: USERNAME,
    password: PASSWORD,
    grant_type: 'password',
  };

  const headers = {
    'Content-Type': 'application/x-www-form-urlencoded',
  };

  const response = http.post(TOKEN_URL, payload, { headers });

  check(response, {
    'token endpoint returned 200': (r) => r && r.status === 200,
    'token exists': (r) => {
      if (!r || r.status !== 200 || !r.body) {
        return false;
      }

      try {
        const body = r.json();
        return !!body.access_token;
      } catch (e) {
        return false;
      }
    },
  });

  if (!response || response.status !== 200) {
    throw new Error(
      `Failed to get token. Status=${response ? response.status : 'no-response'} Body=${response && response.body ? response.body : 'empty'}`
    );
  }

  return response.json('access_token');
}

export function setup() {
  return {
    runId: RUN_ID,
  };
}

function ensureToken() {
  if (!vuToken) {
    vuToken = getAccessToken();
  }
}

function buildHeaders(runId, correlationId, extraHeaders = {}) {
  return {
    Authorization: `Bearer ${vuToken}`,
    'X-Run-Id': runId,
    'X-Correlation-Id': correlationId,
    ...extraHeaders,
  };
}

function getWithRetry(url, runId) {
  ensureToken();

  let correlationId = crypto.randomUUID();
  let response = http.get(url, {
    headers: buildHeaders(runId, correlationId),
  });

  if (response.status === 401) {
    vuToken = getAccessToken();
    correlationId = crypto.randomUUID();

    response = http.get(url, {
      headers: buildHeaders(runId, correlationId),
    });
  }

  return response;
}

function postWithRetry(url, body, runId) {
  ensureToken();

  let correlationId = crypto.randomUUID();
  let response = http.post(url, body, {
    headers: buildHeaders(runId, correlationId, {
      'Content-Type': 'application/json',
    }),
  });

  if (response.status === 401) {
    vuToken = getAccessToken();
    correlationId = crypto.randomUUID();

    response = http.post(url, body, {
      headers: buildHeaders(runId, correlationId, {
        'Content-Type': 'application/json',
      }),
    });
  }

  return response;
}

function doGetItems(runId) {
  const response = getWithRetry(`${BASE_URL}/api/items`, runId);

  check(response, {
    'GET /api/items returned 200': (r) => r.status === 200,
  });
}

function doCreateItem(runId) {
  const itemName = `k6-item-${Date.now()}`;
  const payload = JSON.stringify({ name: itemName });

  const response = postWithRetry(`${BASE_URL}/api/items`, payload, runId);

  check(response, {
    'POST /api/items returned 201': (r) => r.status === 201,
  });
}

export default function (data) {
  const randomChoice = Math.random();

  if (randomChoice < 0.8) {
    doGetItems(data.runId);
  } else {
    doCreateItem(data.runId);
  }

  sleep(1);
}