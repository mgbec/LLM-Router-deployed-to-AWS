import React from 'react'

const MODEL_DISPLAY_NAMES = {
  'us.amazon.nova-lite-v1:0': 'Nova Lite',
  'us.amazon.nova-pro-v1:0': 'Nova Pro',
  'us.anthropic.claude-sonnet-4-6': 'Sonnet 4.6',
  'us.anthropic.claude-opus-4-6-v1': 'Opus 4.6',
  'us.meta.llama4-maverick-17b-instruct-v1:0': 'Llama 4',
}

const COMPLEXITY_COLORS = {
  simple: '#10b981',
  moderate: '#f59e0b',
  complex: '#ef4444',
  specialized: '#8b5cf6',
}

export function RoutingBadge({ routing }) {
  if (!routing) return null

  const modelId = routing.model_selected || routing.model_id
  const displayName = MODEL_DISPLAY_NAMES[modelId] || modelId || 'Unknown'
  const complexity = routing.complexity
  const latency = routing.latency_ms

  return (
    <div className="routing-badge">
      {complexity && (
        <span
          className="badge complexity"
          style={{ backgroundColor: COMPLEXITY_COLORS[complexity] || '#6b7280' }}
        >
          {complexity}
        </span>
      )}
      <span className="badge model">
        {displayName}
      </span>
      {latency && (
        <span className="badge latency">
          {Math.round(latency)}ms
        </span>
      )}
      {routing.escalated && (
        <span className="badge escalated">escalated</span>
      )}
    </div>
  )
}
