import React, { useState, useEffect } from 'react'
import { LoginForm } from './components/LoginForm'
import { ChatWindow } from './components/ChatWindow'

export default function App() {
  const [token, setToken] = useState(localStorage.getItem('llm_router_token') || '')
  const [username, setUsername] = useState(localStorage.getItem('llm_router_user') || '')

  const handleLogin = (newToken, user) => {
    setToken(newToken)
    setUsername(user)
    localStorage.setItem('llm_router_token', newToken)
    localStorage.setItem('llm_router_user', user)
  }

  const handleLogout = () => {
    setToken('')
    setUsername('')
    localStorage.removeItem('llm_router_token')
    localStorage.removeItem('llm_router_user')
  }

  if (!token) {
    return <LoginForm onLogin={handleLogin} />
  }

  return <ChatWindow token={token} username={username} onLogout={handleLogout} />
}
