import React, { useState, useRef, useEffect } from 'react'
import { sendMessage, pollRequest } from '../api'
import { CONFIG } from '../config'
import { MessageBubble } from './MessageBubble'
import { RoutingBadge } from './RoutingBadge'

export function ChatWindow({ token, username, onLogout }) {
  const [messages, setMessages] = useState([])
  const [input, setInput] = useState('')
  const [loading, setLoading] = useState(false)
  const [policy, setPolicy] = useState('default')
  const [asyncMode, setAsyncMode] = useState(false)
  const messagesEndRef = useRef(null)

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: 'smooth' })
  }

  useEffect(() => {
    scrollToBottom()
  }, [messages])

  const handleSend = async () => {
    if (!input.trim() || loading) return

    const userMessage = { role: 'user', content: input.trim() }
    const updatedMessages = [...messages, { ...userMessage, id: Date.now() }]
    setMessages(updatedMessages)
    setInput('')
    setLoading(true)

    try {
      // Build conversation history for the API (without our UI metadata)
      const apiMessages = updatedMessages
        .filter(m => m.role === 'user' || m.role === 'assistant')
        .map(({ role, content }) => ({ role, content }))

      const response = await sendMessage(apiMessages, token, {
        policy,
        async: asyncMode,
      })

      if (response.isAsync) {
        // Add a placeholder and start polling
        const asyncMessage = {
          id: Date.now() + 1,
          role: 'assistant',
          content: '',
          routing: { status: 'processing' },
          requestId: response.data.request_id,
          isAsync: true,
        }
        setMessages(prev => [...prev, asyncMessage])
        pollForResult(response.data.request_id, asyncMessage.id)
      } else if (response.status === 200) {
        const choice = response.data.choices?.[0]
        const assistantMessage = {
          id: Date.now() + 1,
          role: 'assistant',
          content: choice?.message?.content || response.data.content || '',
          routing: response.data.routing || {
            model_selected: response.headers.model || response.data.model,
            complexity: response.headers.complexity || response.data.complexity,
            provider: response.headers.provider || response.data.provider,
            latency_ms: response.data.latency_ms,
          },
        }
        setMessages(prev => [...prev, assistantMessage])
      } else {
        const errorMessage = {
          id: Date.now() + 1,
          role: 'assistant',
          content: `Error: ${response.data.error?.message || response.data.message || 'Request failed'}`,
          isError: true,
        }
        setMessages(prev => [...prev, errorMessage])
      }
    } catch (err) {
      setMessages(prev => [...prev, {
        id: Date.now() + 1,
        role: 'assistant',
        content: `Connection error: ${err.message}`,
        isError: true,
      }])
    } finally {
      setLoading(false)
    }
  }

  const pollForResult = async (requestId, messageId) => {
    const poll = async () => {
      try {
        const result = await pollRequest(requestId, token)

        if (result.isComplete) {
          const choice = result.data.choices?.[0]
          setMessages(prev => prev.map(m =>
            m.id === messageId
              ? {
                  ...m,
                  content: choice?.message?.content || '',
                  routing: result.data.routing || {},
                  isAsync: false,
                }
              : m
          ))
        } else if (result.isFailed) {
          setMessages(prev => prev.map(m =>
            m.id === messageId
              ? { ...m, content: `Async request failed: ${result.data.error}`, isError: true, isAsync: false }
              : m
          ))
        } else {
          // Still processing, poll again
          setTimeout(poll, CONFIG.POLL_INTERVAL)
        }
      } catch (err) {
        setMessages(prev => prev.map(m =>
          m.id === messageId
            ? { ...m, content: `Polling error: ${err.message}`, isError: true, isAsync: false }
            : m
        ))
      }
    }

    setTimeout(poll, CONFIG.POLL_INTERVAL)
  }

  const handleKeyDown = (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault()
      handleSend()
    }
  }

  return (
    <div className="chat-container">
      {/* Header */}
      <header className="chat-header">
        <div className="header-left">
          <h1>LLM Router</h1>
          <span className="header-subtitle">Dynamic Model Selection</span>
        </div>
        <div className="header-right">
          <select
            value={policy}
            onChange={(e) => setPolicy(e.target.value)}
            className="policy-select"
            title="Routing Policy"
          >
            <option value="default">Default</option>
            <option value="budget_conscious">Budget</option>
            <option value="enterprise">Enterprise</option>
          </select>
          <label className="async-toggle" title="Force async processing">
            <input
              type="checkbox"
              checked={asyncMode}
              onChange={(e) => setAsyncMode(e.target.checked)}
            />
            <span>Async</span>
          </label>
          <div className="user-info">
            <span>{username}</span>
            <button onClick={onLogout} className="logout-button">Sign Out</button>
          </div>
        </div>
      </header>

      {/* Messages */}
      <div className="messages-container">
        {messages.length === 0 && (
          <div className="empty-state">
            <h2>Ask anything</h2>
            <p>Messages are routed to the optimal AI model based on complexity.</p>
            <div className="empty-hints">
              <span>Simple → Nova Lite</span>
              <span>Moderate → Nova Pro / Sonnet</span>
              <span>Complex → Opus (async)</span>
            </div>
          </div>
        )}

        {messages.map((msg) => (
          <MessageBubble key={msg.id} message={msg} />
        ))}

        {loading && !messages.some(m => m.isAsync) && (
          <div className="typing-indicator">
            <span></span><span></span><span></span>
          </div>
        )}

        <div ref={messagesEndRef} />
      </div>

      {/* Input */}
      <div className="input-container">
        <textarea
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={handleKeyDown}
          placeholder="Type a message... (Enter to send, Shift+Enter for newline)"
          disabled={loading}
          rows={1}
        />
        <button
          onClick={handleSend}
          disabled={loading || !input.trim()}
          className="send-button"
        >
          Send
        </button>
      </div>

      {/* Disclosure */}
      <div className="ai-disclosure">
        AI model selection is dynamic. Responses are generated by different models based on complexity.
        <a href="#" onClick={(e) => { e.preventDefault(); /* could open model info */ }}>Learn more</a>
      </div>
    </div>
  )
}
