import React from 'react'
import { RoutingBadge } from './RoutingBadge'

export function MessageBubble({ message }) {
  const { role, content, routing, isError, isAsync } = message

  return (
    <div className={`message ${role} ${isError ? 'error' : ''}`}>
      <div className="message-content">
        {isAsync && !content && (
          <div className="async-indicator">
            <div className="spinner"></div>
            <span>Processing with advanced model...</span>
          </div>
        )}

        {content && (
          <div className="message-text">
            {content.split('\n').map((line, i) => (
              <React.Fragment key={i}>
                {line}
                {i < content.split('\n').length - 1 && <br />}
              </React.Fragment>
            ))}
          </div>
        )}
      </div>

      {role === 'assistant' && routing && !isError && content && (
        <RoutingBadge routing={routing} />
      )}
    </div>
  )
}
