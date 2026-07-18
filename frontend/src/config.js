// Configuration — update these after deployment
export const CONFIG = {
  // API endpoint from: terraform output -raw api_endpoint
  API_ENDPOINT: import.meta.env.VITE_API_ENDPOINT || 'https://eza564xd1i.execute-api.us-east-1.amazonaws.com',

  // Cognito settings from: terraform output
  COGNITO_REGION: import.meta.env.VITE_COGNITO_REGION || 'us-east-1',
  COGNITO_CLIENT_ID: import.meta.env.VITE_COGNITO_CLIENT_ID || '',

  // Polling interval for async requests (ms)
  POLL_INTERVAL: 5000,
}
