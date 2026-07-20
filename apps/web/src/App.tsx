import { type ReactNode, useEffect, useRef, useState } from 'react'
import './App.css'
import {
  buildVoiceChatWsUrl,
  createVoiceTask,
  demoRuntime,
  executeActions,
  fetchDevices,
  fetchEsp32DiagHealth,
  fetchVoiceMemoryState,
  fetchVoiceRuntimeStatus,
  loadInitialState,
  requestDeviceReset,
  requestPlan,
  runEsp32SpeakerTest,
  updateVoiceTaskStatus,
} from './apiClient'
import type {
  DeviceState,
  NetworkMode,
  PlanResponse,
  PrecheckResult,
  Routine,
  TraceStep,
  VoiceMemory,
  VoiceMood,
  VoiceRuntimeStatus,
  VoiceTask,
  VoiceWsEvent,
} from './types'

const initialPrompt =
  'I just got home and feel tired. Make the room comfortable, suggest something simple for dinner, and set up a relaxing movie mode.'
const initialVoiceText = 'Hello XiaoQian, confirm live voice session.'
const voiceUserId = 'home-user'
const initialEsp32BaseUrl = 'http://192.0.2.100'

type VoiceStatus = 'idle' | 'connecting' | 'connected' | 'listening' | 'error'
type VoiceLogEntry = {
  id: number
  time: string
  event: VoiceWsEvent
}
type AudioContextConstructor = typeof AudioContext

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
  const [isExecuting, setIsExecuting] = useState(false)
  const [error, setError] = useState('')
  const [voiceText, setVoiceText] = useState(initialVoiceText)
  const [voiceStatus, setVoiceStatus] = useState<VoiceStatus>('idle')
  const [voiceEvents, setVoiceEvents] = useState<VoiceLogEntry[]>([])
  const [voiceSessionId, setVoiceSessionId] = useState('')
  const [voiceReply, setVoiceReply] = useState('')
  const [voiceError, setVoiceError] = useState('')
  const [voiceAudioStatus, setVoiceAudioStatus] = useState('')
  const [isMicStreaming, setIsMicStreaming] = useState(false)
  const [micSampleRate, setMicSampleRate] = useState(0)
  const [voiceMemories, setVoiceMemories] = useState<VoiceMemory[]>([])
  const [voiceTasks, setVoiceTasks] = useState<VoiceTask[]>([])
  const [dueVoiceTasks, setDueVoiceTasks] = useState<VoiceTask[]>([])
  const [voiceMoods, setVoiceMoods] = useState<VoiceMood[]>([])
  const [voiceRuntime, setVoiceRuntime] = useState<VoiceRuntimeStatus | null>(null)
  const [runtimeError, setRuntimeError] = useState('')
  const [esp32BaseUrl, setEsp32BaseUrl] = useState(initialEsp32BaseUrl)
  const [esp32DiagStatus, setEsp32DiagStatus] = useState('idle')
  const [isEsp32DiagLoading, setIsEsp32DiagLoading] = useState(false)
  const [newTaskTitle, setNewTaskTitle] = useState('Check the doors')
  const [newTaskDueText, setNewTaskDueText] = useState('tonight')
  const [memoryError, setMemoryError] = useState('')
  const [isMemoryLoading, setIsMemoryLoading] = useState(false)
  const voiceSocketRef = useRef<WebSocket | null>(null)
  const voiceEventIdRef = useRef(0)
  const micStreamRef = useRef<MediaStream | null>(null)
  const micAudioContextRef = useRef<AudioContext | null>(null)
  const micSourceRef = useRef<MediaStreamAudioSourceNode | null>(null)
  const micProcessorRef = useRef<ScriptProcessorNode | null>(null)
  const micMuteRef = useRef<GainNode | null>(null)
  const playbackAudioContextRef = useRef<AudioContext | null>(null)
  const playbackCursorRef = useRef(0)
  const playbackSourcesRef = useRef<AudioBufferSourceNode[]>([])

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

  useEffect(() => {
    return () => {
      voiceSocketRef.current?.close()
      micProcessorRef.current?.disconnect()
      micSourceRef.current?.disconnect()
      micMuteRef.current?.disconnect()
      micStreamRef.current?.getTracks().forEach((track) => track.stop())
      playbackSourcesRef.current.forEach((source) => {
        try {
          source.stop()
        } catch {
          /* already stopped */
        }
        source.disconnect()
      })
      void micAudioContextRef.current?.close()
      void playbackAudioContextRef.current?.close()
    }
  }, [])

  useEffect(() => {
    refreshVoiceMemory()
    refreshVoiceRuntime()
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

  async function confirmActions() {
    if (!routine || executed) return

    setIsExecuting(true)
    setError('')
    try {
      const data = await executeActions(routine.actions, devices)
      setExecution(data.execution)
      setDevices(data.devices)
      setExecuted(true)
    } catch {
      setError('Could not execute the confirmed actions.')
    } finally {
      setIsExecuting(false)
    }
  }

  function recordVoiceEvent(event: VoiceWsEvent) {
    const id = voiceEventIdRef.current + 1
    voiceEventIdRef.current = id
    setVoiceEvents((current) => [...current, { id, time: new Date().toLocaleTimeString(), event }].slice(-10))

    if (typeof event.session_id === 'string' && event.session_id) {
      setVoiceSessionId(event.session_id)
    }
    if (event.type === 'llm' && event.state === 'stop') {
      setVoiceReply(asText(event.text))
    }
    if (event.type === 'llm' && event.state === 'start') {
      setVoiceStatus('listening')
    }
    if (event.type === 'tts' && (event.state === 'start' || event.state === 'audio')) {
      setVoiceAudioStatus(formatVoiceEventDetail(event))
    }
    if (event.type === 'tts' && event.state === 'stop') {
      setVoiceAudioStatus('reply audio complete')
    }
    if (event.type === 'stt' && event.state === 'partial') {
      setVoiceStatus('listening')
    }
    if (event.type === 'listen' && event.state === 'ready') {
      setVoiceStatus('connected')
      refreshVoiceMemory()
    }
    if (event.type === 'error') {
      setVoiceStatus('error')
      setVoiceError(asText(event.detail) || 'Voice session error.')
    }
  }

  function connectVoiceSession() {
    if (demoRuntime.isStatic) {
      setVoiceError('Static demo mode has no voice socket.')
      setVoiceStatus('error')
      return
    }

    const current = voiceSocketRef.current
    if (current?.readyState === WebSocket.OPEN) {
      setVoiceStatus('connected')
      return
    }

    setVoiceError('')
    setVoiceReply('')
    setVoiceAudioStatus('')
    setVoiceEvents([])
    setVoiceStatus('connecting')
    stopQueuedPlayback()

    const socket = new WebSocket(buildVoiceChatWsUrl())
    socket.binaryType = 'arraybuffer'
    voiceSocketRef.current = socket

    socket.addEventListener('open', () => {
      setVoiceStatus('connected')
      socket.send(
        JSON.stringify({
          type: 'hello',
          version: 1,
          transport: 'websocket',
          session_id: voiceSessionId || undefined,
          user_id: voiceUserId,
          device_id: 'web-console',
          reply_audio: true,
          reply_audio_transport: 'websocket_binary_stream',
          audio_params: {
            format: 'pcm_s16le',
            sample_rate: 16000,
            channels: 1,
            frame_duration: 60,
          },
        }),
      )
    })

    socket.addEventListener('message', (event) => {
      if (typeof event.data !== 'string') {
        void handleVoiceBinary(event.data)
        return
      }

      try {
        recordVoiceEvent(JSON.parse(event.data) as VoiceWsEvent)
      } catch {
        recordVoiceEvent({ type: 'error', detail: 'Bad JSON event from voice socket.' })
      }
    })

    socket.addEventListener('error', () => {
      setVoiceStatus('error')
      setVoiceError('Voice socket connection failed.')
    })

    socket.addEventListener('close', () => {
      if (voiceSocketRef.current === socket) {
        voiceSocketRef.current = null
      }
      setVoiceStatus((currentStatus) => (currentStatus === 'error' ? currentStatus : 'idle'))
    })
  }

  function closeVoiceSession() {
    stopMicCapture()
    stopQueuedPlayback()
    voiceSocketRef.current?.close()
    voiceSocketRef.current = null
    setVoiceStatus('idle')
  }

  function sendVoiceTurn() {
    const socket = voiceSocketRef.current
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setVoiceStatus('error')
      setVoiceError('Connect the voice socket first.')
      return
    }

    const text = voiceText.trim()
    if (!text) {
      setVoiceError('Voice text is empty.')
      return
    }

    setVoiceError('')
    setVoiceReply('')
    setVoiceAudioStatus('')
    setVoiceStatus('listening')
    stopQueuedPlayback()
    socket.send(
      JSON.stringify({
        type: 'listen',
        state: 'start',
        session_id: voiceSessionId || undefined,
        user_id: voiceUserId,
        device_id: 'web-console',
      }),
    )
    const partialText = text.slice(0, Math.max(1, Math.floor(text.length / 2)))
    socket.send(JSON.stringify({ type: 'listen', state: 'partial', text: partialText }))
    socket.send(JSON.stringify({ type: 'listen', state: 'final', text }))
    socket.send(JSON.stringify({ type: 'listen', state: 'stop' }))
  }

  async function startMicTurn() {
    const socket = voiceSocketRef.current
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setVoiceStatus('error')
      setVoiceError('Connect the voice socket first.')
      return
    }
    if (!navigator.mediaDevices?.getUserMedia) {
      setVoiceStatus('error')
      setVoiceError('Microphone capture is unavailable in this browser.')
      return
    }
    if (isMicStreaming) return

    try {
      setVoiceError('')
      setVoiceReply('')
      setVoiceAudioStatus('')
      stopQueuedPlayback()

      const AudioContextClass = getAudioContextClass()
      if (!AudioContextClass) {
        setVoiceStatus('error')
        setVoiceError('Web Audio is unavailable in this browser.')
        return
      }

      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          autoGainControl: true,
          echoCancellation: true,
          noiseSuppression: true,
        },
      })
      const audioContext = new AudioContextClass({ sampleRate: 16000 })
      const source = audioContext.createMediaStreamSource(stream)
      const processor = audioContext.createScriptProcessor(4096, 1, 1)
      const mute = audioContext.createGain()
      mute.gain.value = 0

      processor.onaudioprocess = (event) => {
        if (socket.readyState !== WebSocket.OPEN) return
        const channel = event.inputBuffer.getChannelData(0)
        socket.send(float32ToPcmS16le(channel))
      }

      source.connect(processor)
      processor.connect(mute)
      mute.connect(audioContext.destination)

      micStreamRef.current = stream
      micAudioContextRef.current = audioContext
      micSourceRef.current = source
      micProcessorRef.current = processor
      micMuteRef.current = mute
      setMicSampleRate(audioContext.sampleRate)
      setIsMicStreaming(true)
      setVoiceStatus('listening')

      socket.send(
        JSON.stringify({
          type: 'listen',
          state: 'start',
          session_id: voiceSessionId || undefined,
          user_id: voiceUserId,
          device_id: 'web-mic',
          reply_audio: true,
          reply_audio_transport: 'websocket_binary_stream',
          audio_params: {
            format: 'pcm_s16le',
            sample_rate: audioContext.sampleRate,
            channels: 1,
            frame_duration: Math.round((processor.bufferSize / audioContext.sampleRate) * 1000),
          },
        }),
      )
    } catch (error) {
      stopMicCapture()
      setVoiceStatus('error')
      setVoiceError(error instanceof Error ? error.message : 'Could not start microphone capture.')
    }
  }

  function stopMicTurn() {
    const socket = voiceSocketRef.current
    if (!isMicStreaming) return
    stopMicCapture()
    setVoiceStatus('listening')
    if (socket?.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ type: 'listen', state: 'stop' }))
    }
  }

  async function refreshVoiceMemory() {
    setMemoryError('')
    setIsMemoryLoading(true)
    try {
      const state = await fetchVoiceMemoryState(voiceUserId)
      setVoiceMemories(state.memories)
      setVoiceTasks(state.tasks)
      setDueVoiceTasks(state.dueTasks)
      setVoiceMoods(state.moods)
    } catch {
      setMemoryError('Could not load voice memory state.')
    } finally {
      setIsMemoryLoading(false)
    }
  }

  async function refreshVoiceRuntime() {
    setRuntimeError('')
    try {
      setVoiceRuntime(await fetchVoiceRuntimeStatus())
    } catch {
      setRuntimeError('runtime unavailable')
    }
  }

  async function checkEsp32SpeakerHealth() {
    setIsEsp32DiagLoading(true)
    setEsp32DiagStatus('checking')
    try {
      const result = await fetchEsp32DiagHealth(esp32BaseUrl)
      const health = result.health
      setEsp32DiagStatus(
        `health ${health.status ?? 'ok'} / es8311 ${health.es8311_ready ? 'ready' : 'unknown'} / pa ${
          health.speaker_pa_enabled ? 'on' : 'unknown'
        }`,
      )
    } catch {
      setEsp32DiagStatus('health unavailable')
    } finally {
      setIsEsp32DiagLoading(false)
    }
  }

  async function triggerEsp32SpeakerTone() {
    setIsEsp32DiagLoading(true)
    setEsp32DiagStatus('playing')
    try {
      const result = await runEsp32SpeakerTest(esp32BaseUrl, 8, 'all')
      const tone = result.speaker_test
      setEsp32DiagStatus(`tone ${tone.ok ? 'ok' : 'failed'} / ${tone.mode ?? 'all'} / pa ${tone.speaker_pa_enabled ? 'on' : 'unknown'}`)
    } catch {
      setEsp32DiagStatus('tone unavailable')
    } finally {
      setIsEsp32DiagLoading(false)
    }
  }

  async function submitVoiceTask() {
    const title = newTaskTitle.trim()
    if (!title) return

    try {
      setMemoryError('')
      await createVoiceTask(title, newTaskDueText.trim(), voiceUserId)
      await refreshVoiceMemory()
    } catch {
      setMemoryError('Could not create voice task.')
    }
  }

  async function completeVoiceTask(taskId: string) {
    try {
      setMemoryError('')
      await updateVoiceTaskStatus(taskId, 'done')
      await refreshVoiceMemory()
    } catch {
      setMemoryError('Could not update voice task.')
    }
  }

  function stopMicCapture() {
    micProcessorRef.current?.disconnect()
    micSourceRef.current?.disconnect()
    micMuteRef.current?.disconnect()
    micProcessorRef.current = null
    micSourceRef.current = null
    micMuteRef.current = null
    micStreamRef.current?.getTracks().forEach((track) => track.stop())
    micStreamRef.current = null
    if (micAudioContextRef.current?.state !== 'closed') {
      void micAudioContextRef.current?.close()
    }
    micAudioContextRef.current = null
    setIsMicStreaming(false)
    setMicSampleRate(0)
  }

  function stopQueuedPlayback() {
    playbackSourcesRef.current.forEach((source) => {
      try {
        source.stop()
      } catch {
        /* already stopped */
      }
      source.disconnect()
    })
    playbackSourcesRef.current = []
    playbackCursorRef.current = 0
  }

  async function handleVoiceBinary(data: unknown) {
    const audioBytes = await binaryMessageToArrayBuffer(data)
    if (!audioBytes) {
      recordVoiceEvent({ type: 'binary', bytes: 0 })
      return
    }

    recordVoiceEvent({ type: 'binary', bytes: audioBytes.byteLength })
    try {
      await enqueueReplyAudio(audioBytes)
    } catch (error) {
      recordVoiceEvent({
        type: 'error',
        detail: error instanceof Error ? error.message : 'Could not play reply audio.',
      })
    }
  }

  async function enqueueReplyAudio(audioBytes: ArrayBuffer) {
    const AudioContextClass = getAudioContextClass()
    if (!AudioContextClass) throw new Error('Web Audio is unavailable in this browser.')

    const audioContext = playbackAudioContextRef.current ?? new AudioContextClass()
    playbackAudioContextRef.current = audioContext
    if (audioContext.state === 'suspended') {
      await audioContext.resume()
    }

    const buffer = await audioContext.decodeAudioData(audioBytes.slice(0))
    const source = audioContext.createBufferSource()
    source.buffer = buffer
    source.connect(audioContext.destination)

    const startAt = Math.max(audioContext.currentTime + 0.02, playbackCursorRef.current)
    playbackCursorRef.current = startAt + buffer.duration
    playbackSourcesRef.current.push(source)
    source.addEventListener('ended', () => {
      playbackSourcesRef.current = playbackSourcesRef.current.filter((item) => item !== source)
      source.disconnect()
    })
    source.start(startAt)
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
            <small>confirm in web or on edge device (execute=false)</small>
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
              {executed ? 'executed locally' : 'awaiting human confirmation'}
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

      <section className="voice-section">
        <div className="panel voice-panel">
          <div className="voice-compose">
            <div className="panel-header">
              <p className="eyebrow">Realtime voice</p>
              <h2>WebSocket session</h2>
            </div>
            <textarea
              className="voice-textarea"
              value={voiceText}
              onChange={(event) => setVoiceText(event.target.value)}
            />
            <div className="voice-actions">
              <button type="button" className="primary" onClick={connectVoiceSession} disabled={voiceStatus === 'connecting'}>
                {voiceStatus === 'connecting' ? 'Connecting...' : 'Connect'}
              </button>
              <button type="button" onClick={sendVoiceTurn} disabled={voiceStatus !== 'connected'}>
                Send turn
              </button>
              <button type="button" onClick={() => void startMicTurn()} disabled={voiceStatus !== 'connected' || isMicStreaming}>
                Start mic
              </button>
              <button type="button" onClick={stopMicTurn} disabled={!isMicStreaming}>
                Stop
              </button>
              <button type="button" onClick={closeVoiceSession}>
                Close
              </button>
            </div>
            {voiceError && <p className="error">{voiceError}</p>}
          </div>

          <div className="voice-monitor">
            <div className="voice-monitor-header">
              <div className={`status-badge voice-status ${voiceStatus}`}>{voiceStatus}</div>
              <span>{voiceSessionId || 'no session'}</span>
            </div>
            <div className="voice-reply">
              <span>reply</span>
              <strong>{voiceReply || 'Waiting for assistant audio turn.'}</strong>
            </div>
            <div className="voice-audio-state">
              <span>{isMicStreaming ? `mic ${micSampleRate || ''}hz` : 'mic idle'}</span>
              <strong>{voiceAudioStatus || 'audio queue idle'}</strong>
            </div>
            <div className="voice-events">
              {voiceEvents.length ? (
                voiceEvents.map((entry) => (
                  <div className="voice-event" key={entry.id}>
                    <span>{entry.time}</span>
                    <strong>{formatVoiceEventTitle(entry.event)}</strong>
                    <small>{formatVoiceEventDetail(entry.event)}</small>
                  </div>
                ))
              ) : (
                <p className="muted">Waiting for WebSocket events.</p>
              )}
            </div>
            <div className="runtime-stack">
              <div className="runtime-stack-header">
                <span>runtime stack</span>
                <button type="button" onClick={refreshVoiceRuntime}>
                  Refresh
                </button>
              </div>
              {voiceRuntime ? (
                <div className="runtime-grid">
                  <RuntimeItem title="dialogue" value={voiceRuntime.provider} detail={voiceRuntime.model} />
                  <RuntimeItem
                    title="tts"
                    value={voiceRuntime.tts.provider}
                    detail={`${voiceRuntime.tts.model} / ${voiceRuntime.tts.voice}`}
                  />
                  <RuntimeItem
                    title="asr"
                    value={voiceRuntime.asr.effective_provider}
                    detail={`${voiceRuntime.asr.provider} / ${voiceRuntime.asr.language || 'auto'}`}
                  />
                  <RuntimeItem
                    title="memory"
                    value={voiceRuntime.memory.sqlite_enabled ? 'sqlite' : 'volatile'}
                    detail={voiceRuntime.memory.sqlite_enabled ? 'enabled' : 'disabled'}
                  />
                  <RuntimeItem
                    title="transport"
                    value={voiceRuntime.realtime.websocket ? 'websocket' : 'http'}
                    detail={voiceRuntime.realtime.pcm_s16le ? 'pcm_s16le' : 'text'}
                  />
                  <RuntimeItem
                    title="stream"
                    value={voiceRuntime.realtime.mimo_streaming_tts ? 'tts stream' : 'tts file'}
                    detail={formatRealtimeFlags(voiceRuntime)}
                  />
                </div>
              ) : (
                <p className="muted">{runtimeError || 'Waiting for runtime status.'}</p>
              )}
            </div>
            <div className="esp32-diag">
              <div className="runtime-stack-header">
                <span>esp32 speaker</span>
                <button type="button" onClick={checkEsp32SpeakerHealth} disabled={isEsp32DiagLoading || demoRuntime.isStatic}>
                  Health
                </button>
              </div>
              <div className="esp32-diag-row">
                <input
                  value={esp32BaseUrl}
                  onChange={(event) => setEsp32BaseUrl(event.target.value)}
                  aria-label="ESP32 base URL"
                />
                <button type="button" className="primary" onClick={triggerEsp32SpeakerTone} disabled={isEsp32DiagLoading || demoRuntime.isStatic}>
                  Tone
                </button>
              </div>
              <p className="muted">{esp32DiagStatus}</p>
            </div>
          </div>
        </div>
      </section>

      <section className="memory-section">
        <div className="panel memory-panel">
          <div className="panel-header memory-header">
            <div>
              <p className="eyebrow">Voice memory</p>
              <h2>Shared state</h2>
            </div>
            <button type="button" onClick={refreshVoiceMemory} disabled={isMemoryLoading}>
              {isMemoryLoading ? 'Refreshing...' : 'Refresh'}
            </button>
          </div>
          <div className="memory-create">
            <input value={newTaskTitle} onChange={(event) => setNewTaskTitle(event.target.value)} aria-label="Task title" />
            <input value={newTaskDueText} onChange={(event) => setNewTaskDueText(event.target.value)} aria-label="Task due text" />
            <button type="button" className="primary" onClick={submitVoiceTask}>
              Add task
            </button>
          </div>
          {memoryError && <p className="error">{memoryError}</p>}
          <div className="memory-grid">
            <MemoryColumn title="Memories" empty="No saved memories yet.">
              {voiceMemories.map((memory) => (
                <article className="memory-card" key={memory.memory_id}>
                  <span>{memory.memory_type}</span>
                  <strong>{memory.content}</strong>
                  <small>{memory.source_text}</small>
                </article>
              ))}
            </MemoryColumn>
            <MemoryColumn title="Tasks" empty="No open tasks.">
              {voiceTasks.map((task) => (
                <article className={`memory-card task-card ${isDueTask(task, dueVoiceTasks) ? 'due' : ''}`} key={task.task_id}>
                  <span>{task.status}</span>
                  <strong>{task.title}</strong>
                  <small>{formatTaskDue(task)}</small>
                  <button type="button" onClick={() => completeVoiceTask(task.task_id)}>
                    Done
                  </button>
                </article>
              ))}
            </MemoryColumn>
            <MemoryColumn title="Mood" empty="No mood events yet.">
              {voiceMoods.map((mood) => (
                <article className={`memory-card mood-card ${mood.valence < 0 ? 'negative' : 'positive'}`} key={mood.mood_id}>
                  <span>{mood.valence < 0 ? 'support' : 'positive'}</span>
                  <strong>{mood.mood}</strong>
                  <small>{mood.source_text}</small>
                </article>
              ))}
            </MemoryColumn>
          </div>
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
          {!executed && routine && (
            <div className="execution-actions">
              <button type="button" className="primary" onClick={confirmActions} disabled={isExecuting}>
                {isExecuting ? 'Executing...' : 'Confirm actions'}
              </button>
            </div>
          )}
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

function RuntimeItem({ title, value, detail }: { title: string; value: string; detail: string }) {
  return (
    <div className="runtime-card">
      <span>{title}</span>
      <strong>{value}</strong>
      <small>{detail}</small>
    </div>
  )
}

function MemoryColumn({ title, empty, children }: { title: string; empty: string; children: ReactNode }) {
  const hasContent = Array.isArray(children) ? children.length > 0 : Boolean(children)
  return (
    <div className="memory-column">
      <h3>{title}</h3>
      <div className="memory-list">{hasContent ? children : <p className="muted">{empty}</p>}</div>
    </div>
  )
}

function formatRealtimeFlags(runtime: VoiceRuntimeStatus): string {
  const flags = [
    runtime.realtime.stt_partial_events ? 'partial stt' : '',
    runtime.realtime.audio_partial_asr ? 'audio partial' : '',
    runtime.realtime.opus_stream ? 'opus' : '',
    runtime.realtime.full_duplex ? 'duplex' : 'half duplex',
  ].filter(Boolean)
  return flags.join(', ')
}

function isDueTask(task: VoiceTask, dueTasks: VoiceTask[]): boolean {
  return dueTasks.some((dueTask) => dueTask.task_id === task.task_id)
}

function formatTaskDue(task: VoiceTask): string {
  const recurrence = task.recurrence ? `${task.recurrence} ` : ''
  if (task.due_at) {
    return `${recurrence}${task.due_text || 'due'} - ${new Date(task.due_at * 1000).toLocaleString()}`
  }
  return `${recurrence}${task.due_text || 'no due time'}`.trim()
}

function formatDeviceDetail(device: DeviceState[string]) {
  if (device.scene) return `scene: ${device.scene}`
  if (device.temperature) return `${device.temperature}C`
  if (device.mode) return `mode: ${device.mode}`
  if (device.playlist) return `playlist: ${device.playlist}`
  if (device.message) return device.message
  return 'ready'
}

function asText(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

function getAudioContextClass(): AudioContextConstructor | null {
  const candidate = window.AudioContext
  return candidate ?? null
}

function float32ToPcmS16le(input: Float32Array): ArrayBuffer {
  const output = new ArrayBuffer(input.length * 2)
  const view = new DataView(output)
  for (let index = 0; index < input.length; index += 1) {
    const sample = Math.max(-1, Math.min(1, input[index] ?? 0))
    view.setInt16(index * 2, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true)
  }
  return output
}

async function binaryMessageToArrayBuffer(data: unknown): Promise<ArrayBuffer | null> {
  if (data instanceof ArrayBuffer) return data
  if (data instanceof Blob) return data.arrayBuffer()
  return null
}

function formatVoiceEventTitle(event: VoiceWsEvent): string {
  const type = asText(event.type) || 'event'
  const state = asText(event.state)
  return state ? `${type}/${state}` : type
}

function formatVoiceEventDetail(event: VoiceWsEvent): string {
  if (event.type === 'hello') return `session ${asText(event.session_id)}`
  if (event.type === 'stt') {
    const state = asText(event.state)
    return state ? `${state}: ${asText(event.text)}` : asText(event.text)
  }
  if (event.type === 'llm' && event.state === 'stop') {
    return `${asText(event.provider)} turn ${String(event.turn_index ?? '')}: ${asText(event.text)}`
  }
  if (event.type === 'listen' && event.state === 'ready') return `turn ${String(event.turn_index ?? '')} ready`
  if (event.type === 'error') return asText(event.detail)
  return JSON.stringify(event).slice(0, 160)
}

export default App
