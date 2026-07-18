import React, { useState } from 'react'
import { authenticate, completeNewPassword } from '../api'

export function LoginForm({ onLogin }) {
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [newPassword, setNewPassword] = useState('')
  const [needsNewPassword, setNeedsNewPassword] = useState(false)
  const [session, setSession] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')
    setLoading(true)

    try {
      if (needsNewPassword) {
        const result = await completeNewPassword(username, newPassword, session)
        onLogin(result.token, username)
      } else {
        const result = await authenticate(username, password)
        if (result.needsNewPassword) {
          setNeedsNewPassword(true)
          setSession(result.session)
        } else {
          onLogin(result.token, username)
        }
      }
    } catch (err) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="login-container">
      <div className="login-card">
        <div className="login-header">
          <h1>LLM Router</h1>
          <p>Dynamic Model Selection</p>
        </div>

        <form onSubmit={handleSubmit}>
          {!needsNewPassword ? (
            <>
              <div className="input-group">
                <label htmlFor="username">Username</label>
                <input
                  id="username"
                  type="text"
                  value={username}
                  onChange={(e) => setUsername(e.target.value)}
                  placeholder="Enter username"
                  required
                  autoFocus
                />
              </div>
              <div className="input-group">
                <label htmlFor="password">Password</label>
                <input
                  id="password"
                  type="password"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="Enter password"
                  required
                />
              </div>
            </>
          ) : (
            <div className="input-group">
              <label htmlFor="newPassword">New Password Required</label>
              <input
                id="newPassword"
                type="password"
                value={newPassword}
                onChange={(e) => setNewPassword(e.target.value)}
                placeholder="Enter new password"
                required
                autoFocus
              />
              <small>Your temporary password has expired. Please set a new one.</small>
            </div>
          )}

          {error && <div className="error-message">{error}</div>}

          <button type="submit" disabled={loading} className="login-button">
            {loading ? 'Authenticating...' : needsNewPassword ? 'Set Password' : 'Sign In'}
          </button>
        </form>

        <div className="login-footer">
          <span className="disclosure">
            AI-powered routing system. Model selection is dynamic.
          </span>
        </div>
      </div>
    </div>
  )
}
