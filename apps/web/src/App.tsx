import { useEffect, useState } from 'react'
import './App.css'
import { demoRuntime, fetchDevices, loadInitialState, requestDeviceReset, requestPlan } from './apiClient'
import type { DeviceState, NetworkMode, PlanResponse, PrecheckResult, Routine, TraceStep } from './types'

const initialPrompt =
  'I just got home and feel tired. Make the room comfortable, suggest something simple for dinner, and set up a relaxing movie mode.'

function App() {
  const [prompt, setPrompt] = useState(initialPrompt)
  const [networkMode, setNetworkMode] = useState<NetworkMode>('online')
  const [agentMode, setAgentMode] = useState(false)
  const [proposeOnly, setProposeOnly] = useState(false)
  const [context, setContext] = useState<PlanResponse['context'] | null>(null)
  const [routine, setRoutine] = useState<Routine | null>(null)
  const [execution, setExecution] = useState<PlanResponse['execution']>([])
  const [precheck, setPrecheck] = useState<PrecheckResult[]>([])
  const [executed, setExecuted] = useState(true)
  const [devices, setDevices] = useState<DeviceState>({})
  const [trace, setTrace] = useState<TraceStep[]>([])
  const [showTrace, setShowTrace] = useState(true)
  const [isPlanning, setIsPlanning] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    loadInitialState()
      .then((state) => {
        setContext(state.context)
        setDevices(state.devices)
      })
      .catch(() => {
        setError(`Could not load ${demoRuntime.detail}. Start the FastAPI edge gateway or open with ?demo=static.`)
      })
  }, [])

  useEffect(() => {
    if (demoRuntime.isStatic) return

    const pollDevices = () => {
      fetchDevices()
        .then(setDevices)
        .catch(() => {
          /* keep last known state; initial load already surfaces connection errors */
        })
    }

    const intervalId = window.setInterval(pollDevices, 3000)
    return () => window.clearInterval(intervalId)
  }, [])

  async function runPlan() {
    setIsPlanning(true)
    setError('')

    try {
      const data = await requestPlan(prompt, networkMode, devices, agentMode, !proposeOnly)
      setContext(data.context)
      setRoutine(data.routine)
      setExecution(data.execution)
      setPrecheck(data.precheck ?? [])
      setExecuted(data.executed ?? true)
      setDevices(data.devices)
      setTrace(data.trace ?? [])
    } catch {
      setError('Could not reach the selected planning runtime. Check the API server or use static demo mode.')
    } finally {
      setIsPlanning(false)
    }
  }

  async function resetDevices() {
    try {
      setError('')
      setDevices(await requestDeviceReset())
      setRoutine(null)
      setExecution([])
      setPrecheck([])
      setExecuted(true)
      setTrace([])
    } catch {
      setError('Could not reset the selected device runtime.')
    }
  }

  return (
    <main className="app-shell">
      <section className="topbar">
        <div>
          <p className="eyebrow">Qwen EdgeAgent prototype</p>
          <h1>HomeCue Edge</h1>
        </div>
        <div className="status-cluster">
          <div className={`runtime-pill ${demoRuntime.isStatic ? 'static' : 'api'}`}>{demoRuntime.label}</div>
          <div className={`network-pill ${networkMode}`}>{networkMode}</div>
        </div>
      </section>

      <section className="workspace">
        <div className="panel prompt-panel">
          <div className="panel-header">
            <p className="eyebrow">Home request</p>
            <h2>Evening routine</h2>
          </div>
          <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} />
          <div className="segmented-control" aria-label="Network mode">
            {(['online', 'weak', 'offline'] as NetworkMode[]).map((mode) => (
              <button
                key={mode}
                type="button"
                className={networkMode === mode ? 'active' : ''}
                onClick={() => setNetworkMode(mode)}
              >
                {mode}
              </button>
            ))}
          </div>
          <label className="agent-toggle">
            <input
              type="checkbox"
              checked={agentMode}
              onChange={(event) => setAgentMode(event.target.checked)}
            />
            <span>Agent mode</span>
            <small>multi-step tool calls + trace</small>
          </label>
          <label className="agent-toggle">
            <input
              type="checkbox"
              checked={proposeOnly}
              onChange={(event) => setProposeOnly(event.target.checked)}
            />
            <span>Propose only</span>
            <small>await hardware key confirmation (execute=false)</small>
          </label>
          <div className="actions">
            <button type="button" className="primary" onClick={runPlan} disabled={isPlanning}>
              {isPlanning ? 'Planning...' : 'Run agent'}
            </button>
            <button type="button" onClick={resetDevices}>
              Reset home
            </button>
          </div>
          {error && <p className="error">{error}</p>}
        </div>

        <div className="panel context-panel">
          <div className="panel-header">
            <p className="eyebrow">Local context</p>
            <h2>Kept at edge</h2>
          </div>
          {context ? (
            <div className="context-grid">
              <InfoBlock title="Room" value={context.home.room} />
              <InfoBlock title="Time" value={context.home.time} />
              <InfoBlock title="Weather" value={context.home.weather} />
              <InfoBlock title="State" value={context.user.mood} />
              <InfoBlock title="Preference" value={context.user.preference} />
              <InfoBlock title="Privacy" value={context.user.privacy_policy} />
            </div>
          ) : (
            <p className="muted">Waiting for edge context.</p>
          )}
        </div>

        <div className="panel plan-panel">
          <div className="panel-header">
            <p className="eyebrow">Qwen-compatible plan</p>
            <h2>{routine ? routine.mode.replaceAll('_', ' ') : 'Ready'}</h2>
          </div>
          {routine && (
            <div className={`status-badge ${executed ? 'executed' : 'pending'}`}>
              {executed ? 'executed locally' : 'awaiting hardware confirmation'}
            </div>
          )}
          {routine ? (
            <>
              <div className="source-row">
                <span>planner</span>
                <strong>{routine.provider}</strong>
              </div>
              <p className="summary">{routine.summary}</p>
              <p className="privacy">{routine.privacy_summary}</p>
              <ol className="reasoning">
                {routine.reasoning.map((item) => (
                  <li key={item}>{item}</li>
                ))}
              </ol>
            </>
          ) : (
            <p className="muted">Run the agent to generate a structured home routine.</p>
          )}
        </div>
      </section>

      <section className="lower-grid">
        <div className="panel">
          <div className="panel-header">
            <p className="eyebrow">Local actions</p>
            <h2>Device simulator</h2>
          </div>
          <div className="device-grid">
            {Object.entries(devices).map(([key, device]) => (
              <div className="device-card" key={key}>
                <span>{device.label}</span>
                <strong>{device.state}</strong>
                <small>{formatDeviceDetail(device)}</small>
              </div>
            ))}
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <p className="eyebrow">Execution guard</p>
            <h2>{executed ? 'Policy checked' : 'Pending confirmation'}</h2>
          </div>
          <div className="execution-list">
            {execution.length ? (
              execution.map((item) => (
                <div className={`execution-row ${item.accepted ? 'accepted' : 'rejected'}`} key={`${item.device}-${item.command}`}>
                  <span>{item.accepted ? 'accepted' : 'rejected'}</span>
                  <strong>
                    {item.device}.{item.command}
                  </strong>
                  <small>{String(item.value)} - {item.reason}</small>
                </div>
              ))
            ) : precheck.length ? (
              precheck.map((item) => (
                <div className={`execution-row pending ${item.accepted ? 'accepted' : 'rejected'}`} key={`${item.device}-${item.command}`}>
                  <span>{item.accepted ? 'pending' : 'rejected'}</span>
                  <strong>
                    {item.device}.{item.command}
                  </strong>
                  <small>{String(item.value)} - {item.reason}</small>
                </div>
              ))
            ) : (
              <p className="muted">Structured actions will be checked before local execution.</p>
            )}
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <p className="eyebrow">Suggestions</p>
            <h2>Home cues</h2>
          </div>
          <div className="suggestion-list">
            {routine?.suggestions.length ? (
              routine.suggestions.map((suggestion) => (
                <article key={`${suggestion.type}-${suggestion.title}`} className="suggestion-card">
                  <span>{suggestion.type}</span>
                  <strong>{suggestion.title}</strong>
                  <p>{suggestion.detail}</p>
                </article>
              ))
            ) : (
              <p className="muted">Meal, media, comfort, and reminder cues will appear here.</p>
            )}
          </div>
        </div>
      </section>

      {trace.length > 0 && (
        <section className="trace-section">
          <div className="panel trace-panel">
            <div className="panel-header trace-header">
              <div>
                <p className="eyebrow">Agent trace</p>
                <h2>Decision steps</h2>
              </div>
              <button type="button" className="trace-toggle" onClick={() => setShowTrace((value) => !value)}>
                {showTrace ? 'Hide' : 'Show'}
              </button>
            </div>
            {showTrace && (
              <ol className="trace-list">
                {trace.map((step, index) => (
                  <TraceRow key={`${step.step}-${step.type}-${index}`} step={step} />
                ))}
              </ol>
            )}
          </div>
        </section>
      )}
    </main>
  )
}

function TraceRow({ step }: { step: TraceStep }) {
  if (step.type === 'tool_call') {
    const accepted = countAccepted(step.result)
    return (
      <li className="trace-row tool">
        <div className="trace-meta">
          <span className="trace-step">step {step.step}</span>
          <strong>{step.name}</strong>
          <span className="trace-kind">tool call</span>
        </div>
        <small className="trace-args">{summarizeArgs(step.args)}</small>
        {accepted && <small className={`trace-guard ${accepted.rejected ? 'rejected' : 'accepted'}`}>{accepted.label}</small>}
      </li>
    )
  }

  if (step.type === 'final') {
    return (
      <li className="trace-row final">
        <div className="trace-meta">
          <span className="trace-step">step {step.step}</span>
          <strong>final plan</strong>
        </div>
        <small className="trace-args">{(step.content ?? '').slice(0, 160) || 'Routine emitted.'}</small>
      </li>
    )
  }

  return (
    <li className="trace-row warn">
      <div className="trace-meta">
        <span className="trace-step">step {step.step}</span>
        <strong>{step.type.replaceAll('_', ' ')}</strong>
      </div>
      <small className="trace-args">{step.content}</small>
    </li>
  )
}

function countAccepted(result: unknown): { label: string; rejected: boolean } | null {
  if (!result || typeof result !== 'object') return null
  const record = result as Record<string, unknown>
  if (typeof record.accepted_count === 'number' && typeof record.rejected_count === 'number') {
    return {
      label: `guard: ${record.accepted_count} accepted, ${record.rejected_count} rejected`,
      rejected: record.rejected_count > 0,
    }
  }
  return null
}

function summarizeArgs(args: Record<string, unknown> | undefined): string {
  if (!args || Object.keys(args).length === 0) return 'no arguments'
  if (Array.isArray((args as { actions?: unknown }).actions)) {
    const actions = (args as { actions: Array<{ device?: string; command?: string }> }).actions
    return `proposes ${actions.length} action(s): ${actions.map((a) => `${a.device}.${a.command}`).join(', ')}`
  }
  return JSON.stringify(args).slice(0, 160)
}

function InfoBlock({ title, value }: { title: string; value: string }) {
  return (
    <div className="info-block">
      <span>{title}</span>
      <strong>{value}</strong>
    </div>
  )
}

function formatDeviceDetail(device: DeviceState[string]) {
  if (device.scene) return `scene: ${device.scene}`
  if (device.temperature) return `${device.temperature}C`
  if (device.mode) return `mode: ${device.mode}`
  if (device.playlist) return `playlist: ${device.playlist}`
  if (device.message) return device.message
  return 'ready'
}

export default App
