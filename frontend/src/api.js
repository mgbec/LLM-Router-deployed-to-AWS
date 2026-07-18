import { CONFIG } from './config'

/**
 * Send a chat completion request to the LLM Router.
 * Returns either a sync response (200) or async handle (202).
 */
export async function sendMessage(messages, token, routingOptions = {}) {
  const response = await fetch(`${CONFIG.API_ENDPOINT}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      messages,
      routing: routingOptions,
    }),
  })

  const data = await response.json()

  // Extract routing headers
  const headers = {
    model: response.headers.get('x-ai-model'),
    provider: response.headers.get('x-ai-provider'),
    complexity: response.headers.get('x-ai-complexity'),
  }

  return {
    status: response.status,
    data,
    headers,
    isAsync: response.status === 202,
  }
}

/**
 * Poll for an async request result.
 */
export async function pollRequest(requestId, token) {
  const response = await fetch(`${CONFIG.API_ENDPOINT}/v1/requests/${requestId}`, {
    headers: {
      'Authorization': `Bearer ${token}`,
    },
  })

  const data = await response.json()
  return {
    status: response.status,
    data,
    isComplete: data.status === 'completed',
    isFailed: data.status === 'failed',
    isProcessing: data.status === 'processing' || data.status === 'pending',
  }
}

/**
 * Get model information.
 */
export async function getModelInfo(token) {
  const response = await fetch(`${CONFIG.API_ENDPOINT}/v1/models/info`, {
    headers: { 'Authorization': `Bearer ${token}` },
  })
  return response.json()
}

/**
 * Authenticate with Cognito (username/password).
 */
export async function authenticate(username, password) {
  const response = await fetch(
    `https://cognito-idp.${CONFIG.COGNITO_REGION}.amazonaws.com/`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.InitiateAuth',
      },
      body: JSON.stringify({
        AuthFlow: 'USER_PASSWORD_AUTH',
        ClientId: CONFIG.COGNITO_CLIENT_ID,
        AuthParameters: {
          USERNAME: username,
          PASSWORD: password,
        },
      }),
    }
  )

  const data = await response.json()

  if (data.ChallengeName === 'NEW_PASSWORD_REQUIRED') {
    return { needsNewPassword: true, session: data.Session }
  }

  if (data.AuthenticationResult) {
    return {
      token: data.AuthenticationResult.AccessToken,
      refreshToken: data.AuthenticationResult.RefreshToken,
      expiresIn: data.AuthenticationResult.ExpiresIn,
    }
  }

  throw new Error(data.message || 'Authentication failed')
}

/**
 * Complete new password challenge.
 */
export async function completeNewPassword(username, newPassword, session) {
  const response = await fetch(
    `https://cognito-idp.${CONFIG.COGNITO_REGION}.amazonaws.com/`,
    {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-amz-json-1.1',
        'X-Amz-Target': 'AWSCognitoIdentityProviderService.RespondToAuthChallenge',
      },
      body: JSON.stringify({
        ChallengeName: 'NEW_PASSWORD_REQUIRED',
        ClientId: CONFIG.COGNITO_CLIENT_ID,
        Session: session,
        ChallengeResponses: {
          USERNAME: username,
          NEW_PASSWORD: newPassword,
        },
      }),
    }
  )

  const data = await response.json()
  if (data.AuthenticationResult) {
    return {
      token: data.AuthenticationResult.AccessToken,
      refreshToken: data.AuthenticationResult.RefreshToken,
    }
  }

  throw new Error(data.message || 'Password change failed')
}
