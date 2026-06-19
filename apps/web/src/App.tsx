import { useEffect, useRef, useState } from 'react'
import './App.css'
import {
  demoRuntime,
  fetchDevices,
  loadInitialState,
  requestDeviceReset,
  requestExecuteActions,
  requestLatestExecution,
  requestPlan,
  requestVisionScene,
} from './apiClient'
import type {
  DeviceAction,
  DeviceState,
  NetworkMode,
  PlanResponse,
  PrecheckResult,
  Routine,
  TraceStep,
  VisionSceneResponse,
} from './types'

const initialPrompt =
  '我刚回到家，有点累。把客厅调舒服，推荐一个简单晚餐，并准备一个放松的观影模式。'

const networkLabels: Record<NetworkMode, string> = {
  online: '在线',
  weak: '弱网',
  offline: '离线',
}

const preferredCameraConstraints: MediaStreamConstraints[] = [
  {
    audio: false,
    video: {
      facingMode: { exact: 'user' },
      height: { ideal: 720 },
      width: { ideal: 1280 },
    },
  },
  {
    audio: false,
    video: {
      facingMode: 'user',
      height: { ideal: 720 },
      width: { ideal: 1280 },
    },
  },
  {
    audio: false,
    video: {
      facingMode: { ideal: 'user' },
      height: { ideal: 720 },
      width: { ideal: 1280 },
    },
  },
  {
    audio: false,
    video: {
      height: { ideal: 720 },
      width: { ideal: 1280 },
    },
  },
]

const frontCameraLabelPattern = /front|user|selfie|face|camera.*front|前置|前摄|前面|前方|自拍/i
const backCameraLabelPattern = /back|rear|environment|world|camera.*back|后置|后摄|后面|后方/i

type CameraOpenResult = {
  stream: MediaStream
  preference: 'front-facing-mode' | 'front-device-label' | 'browser-preferred'
  facingMode?: string
  trackLabel?: string
}

type BrowserSpeechAlternative = {
  transcript?: string
}

type BrowserSpeechResult = {
  0?: BrowserSpeechAlternative
}

type BrowserSpeechResults = {
  length: number
  [index: number]: BrowserSpeechResult
}

type BrowserSpeechEvent = Event & {
  results: BrowserSpeechResults
}

type BrowserSpeechErrorEvent = Event & {
  error?: string
}

type BrowserSpeechRecognition = {
  continuous: boolean
  interimResults: boolean
  lang: string
  abort: () => void
  start: () => void
  stop: () => void
  onend: (() => void) | null
  onerror: ((event: BrowserSpeechErrorEvent) => void) | null
  onresult: ((event: BrowserSpeechEvent) => void) | null
}

type BrowserSpeechRecognitionConstructor = new () => BrowserSpeechRecognition

declare global {
  interface Window {
    SpeechRecognition?: BrowserSpeechRecognitionConstructor
    webkitSpeechRecognition?: BrowserSpeechRecognitionConstructor
  }
}

function App() {
  const cameraPreviewRef = useRef<HTMLVideoElement | null>(null)
  const cameraStreamRef = useRef<MediaStream | null>(null)
  const executionSequenceRef = useRef(0)
  const speechRecognitionRef = useRef<BrowserSpeechRecognition | null>(null)
  const [prompt, setPrompt] = useState(initialPrompt)
  const [networkMode, setNetworkMode] = useState<NetworkMode>('online')
  const [agentMode, setAgentMode] = useState(false)
  const [proposeOnly, setProposeOnly] = useState(false)
  const [context, setContext] = useState<PlanResponse['context'] | null>(null)
  const [routine, setRoutine] = useState<Routine | null>(null)
  const [execution, setExecution] = useState<PlanResponse['execution']>([])
  const [executionSource, setExecutionSource] = useState('none')
  const [precheck, setPrecheck] = useState<PrecheckResult[]>([])
  const [executed, setExecuted] = useState(true)
  const [devices, setDevices] = useState<DeviceState>({})
  const [trace, setTrace] = useState<TraceStep[]>([])
  const [sceneHint, setSceneHint] = useState('晚上有点累，坐在客厅沙发上，室内光线偏暗')
  const [sceneImageBase64, setSceneImageBase64] = useState('')
  const [scene, setScene] = useState<VisionSceneResponse | null>(null)
  const [showTrace, setShowTrace] = useState(true)
  const [isPlanning, setIsPlanning] = useState(false)
  const [isReadingScene, setIsReadingScene] = useState(false)
  const [isExecuting, setIsExecuting] = useState(false)
  const [cameraActive, setCameraActive] = useState(false)
  const [cameraStatus, setCameraStatus] = useState('摄像头待机')
  const [cameraError, setCameraError] = useState('')
  const [cameraPreference, setCameraPreference] = useState<CameraOpenResult['preference'] | null>(null)
  const [isListening, setIsListening] = useState(false)
  const [voiceStatus, setVoiceStatus] = useState('语音待机')
  const [voiceError, setVoiceError] = useState('')
  const [error, setError] = useState('')

  useEffect(() => {
    loadInitialState()
      .then((state) => {
        setContext(state.context)
        setDevices(state.devices)
        if (!demoRuntime.isStatic) {
          requestLatestExecution()
            .then((executionState) => {
              executionSequenceRef.current = executionState.sequence
              setDevices(executionState.devices)
            })
            .catch(() => undefined)
        }
      })
      .catch(() => {
        setError(`无法连接 ${demoRuntime.detail}。请启动本地网关服务，或在地址后追加 ?demo=static 打开静态演示。`)
      })
  }, [])

  useEffect(() => {
    if (demoRuntime.isStatic) return

    const pollRuntime = () => {
      requestLatestExecution()
        .then((executionState) => {
          setDevices(executionState.devices)
          if (
            executionState.sequence > executionSequenceRef.current &&
            executionState.executed &&
            routine &&
            !executed
          ) {
            setExecution(executionState.execution)
            setExecutionSource(executionState.source)
            setExecuted(true)
          }
          executionSequenceRef.current = Math.max(executionSequenceRef.current, executionState.sequence)
        })
        .catch(() => {
          fetchDevices()
            .then(setDevices)
            .catch(() => undefined)
        })
        .catch(() => {
          /* keep last known state; initial load already surfaces connection errors */
        })
    }

    pollRuntime()
    const intervalId = window.setInterval(pollRuntime, 2500)
    return () => window.clearInterval(intervalId)
  }, [executed, routine])

  useEffect(() => {
    return () => {
      cameraStreamRef.current?.getTracks().forEach((track) => track.stop())
      speechRecognitionRef.current?.abort()
    }
  }, [])

  async function runPlan() {
    setIsPlanning(true)
    setError('')

    try {
      const data = await requestPlan(prompt, networkMode, devices, agentMode, !proposeOnly)
      setContext(data.context)
      setRoutine(data.routine)
      setExecution(data.execution)
      setExecutionSource(data.executed ? 'plan' : 'none')
      setPrecheck(data.precheck ?? [])
      setExecuted(data.executed ?? true)
      setDevices(data.devices)
      setTrace(data.trace ?? [])
      if (data.executed) {
        requestLatestExecution()
          .then((executionState) => {
            executionSequenceRef.current = executionState.sequence
          })
          .catch(() => undefined)
      }
    } catch {
      setError('无法连接当前规划运行时。请检查 API 服务，或切换到静态演示模式。')
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
      setExecutionSource('none')
      setPrecheck([])
      setExecuted(true)
      setTrace([])
      requestLatestExecution()
        .then((executionState) => {
          executionSequenceRef.current = executionState.sequence
        })
        .catch(() => undefined)
    } catch {
      setError('无法重置当前设备运行时。')
    }
  }

  async function confirmActions() {
    if (!routine) return

    setIsExecuting(true)
    setError('')

    try {
      const data = await requestExecuteActions(getConfirmableActions(routine.actions, precheck), devices)
      setExecution(data.execution)
      setExecutionSource(data.source ?? 'web')
      setDevices(data.devices)
      setExecuted(data.execution.some((item) => item.accepted))
      if (typeof data.sequence === 'number') {
        executionSequenceRef.current = data.sequence
      }
    } catch {
      setError('无法执行已确认的家庭动作。')
    } finally {
      setIsExecuting(false)
    }
  }

  async function readScene() {
    setIsReadingScene(true)
    setError('')

    try {
      const data = await requestVisionScene(sceneHint, 'living room', sceneImageBase64)
      setScene(data)
    } catch {
      setError('无法分析当前家庭场景。请检查 API 服务，或切换到静态演示模式。')
    } finally {
      setIsReadingScene(false)
    }
  }

  function useScenePrompt() {
    if (!scene) return
    setPrompt(scene.suggested_prompt || buildScenePrompt(scene, sceneHint))
    setProposeOnly(true)
  }

  function startVoiceInput() {
    const SpeechRecognition = window.SpeechRecognition ?? window.webkitSpeechRecognition

    if (!SpeechRecognition) {
      setVoiceStatus('语音不可用')
      setVoiceError('当前浏览器不支持语音识别接口，请使用安卓 Chrome 或继续文字输入。')
      return
    }

    speechRecognitionRef.current?.abort()
    const recognition = new SpeechRecognition()
    speechRecognitionRef.current = recognition
    recognition.lang = 'zh-CN'
    recognition.continuous = false
    recognition.interimResults = false

    recognition.onresult = (event) => {
      const transcript = extractTranscript(event.results)

      if (transcript) {
        setPrompt((value) => `${value.trim()}${value.trim() ? '\n' : ''}语音输入：${transcript}`)
        setVoiceStatus('语音已写入请求')
      } else {
        setVoiceStatus('未识别到内容')
      }
    }

    recognition.onerror = (event) => {
      setVoiceStatus('语音输入失败')
      setVoiceError(`语音识别失败：${translateSpeechError(event.error)}`)
      setIsListening(false)
    }

    recognition.onend = () => {
      speechRecognitionRef.current = null
      setIsListening(false)
    }

    setVoiceError('')
    setVoiceStatus('正在听...')
    setIsListening(true)
    recognition.start()
  }

  function stopVoiceInput() {
    speechRecognitionRef.current?.stop()
    speechRecognitionRef.current = null
    setIsListening(false)
    setVoiceStatus('语音已停止')
  }

  async function startCamera() {
    if (!navigator.mediaDevices?.getUserMedia) {
      setCameraError('当前浏览器不支持摄像头 API。')
      setCameraStatus('摄像头不可用')
      return
    }

    setCameraError('')
    setCameraStatus('正在优先请求前置摄像头...')

    try {
      const camera = await openPreferredCamera()
      const { stream } = camera

      cameraStreamRef.current?.getTracks().forEach((track) => track.stop())
      cameraStreamRef.current = stream
      setCameraPreference(camera.preference)

      if (cameraPreviewRef.current) {
        cameraPreviewRef.current.srcObject = stream
        await cameraPreviewRef.current.play().catch(() => undefined)
      }

      setCameraActive(true)
      setCameraStatus(formatCameraReadyStatus(camera))
    } catch {
      setCameraActive(false)
      setCameraPreference(null)
      setCameraStatus('摄像头受阻')
      setCameraError('摄像头权限或设备访问失败。')
    }
  }

  function captureSceneFrame() {
    const video = cameraPreviewRef.current

    if (!video || video.readyState < HTMLMediaElement.HAVE_CURRENT_DATA || !video.videoWidth || !video.videoHeight) {
      setCameraError('摄像头画面还没有准备好。')
      return
    }

    const maxWidth = 640
    const scale = Math.min(1, maxWidth / video.videoWidth)
    const canvas = document.createElement('canvas')
    canvas.width = Math.round(video.videoWidth * scale)
    canvas.height = Math.round(video.videoHeight * scale)

    const context2d = canvas.getContext('2d')
    if (!context2d) {
      setCameraError('无法截取当前摄像头画面。')
      return
    }

    context2d.drawImage(video, 0, 0, canvas.width, canvas.height)
    const [, base64 = ''] = canvas.toDataURL('image/jpeg', 0.72).split(',')
    setSceneImageBase64(base64)
    setCameraStatus('画面已截取')
    setCameraError('')
  }

  function stopCamera() {
    cameraStreamRef.current?.getTracks().forEach((track) => track.stop())
    cameraStreamRef.current = null

    if (cameraPreviewRef.current) {
      cameraPreviewRef.current.srcObject = null
    }

    setCameraActive(false)
    setCameraPreference(null)
    setCameraStatus(sceneImageBase64 ? '画面已截取' : '摄像头已停止')
  }

  return (
    <main className="app-shell">
      <section className="topbar">
        <div>
          <p className="eyebrow">家庭场景智能管家原型</p>
          <h1>家庭智能管家</h1>
        </div>
        <div className="status-cluster">
          <div className={`runtime-pill ${demoRuntime.isStatic ? 'static' : 'api'}`}>{formatRuntimeLabel()}</div>
          <div className={`network-pill ${networkMode}`}>{networkLabels[networkMode]}</div>
        </div>
      </section>

      <section className="workspace">
        <div className="panel prompt-panel">
          <div className="panel-header">
            <p className="eyebrow">用户请求</p>
            <h2>晚间回家流程</h2>
          </div>
          <textarea value={prompt} onChange={(event) => setPrompt(event.target.value)} />
          <div className="voice-input-row">
            <button
              type="button"
              className={isListening ? 'voice-listening' : ''}
              onClick={isListening ? stopVoiceInput : startVoiceInput}
            >
              {isListening ? '停止语音' : '语音输入'}
            </button>
            <span>{voiceStatus}</span>
          </div>
          {voiceError && <p className="voice-error">{voiceError}</p>}
          <div className="segmented-control" aria-label="网络模式">
            {(['online', 'weak', 'offline'] as NetworkMode[]).map((mode) => (
              <button
                key={mode}
                type="button"
                className={networkMode === mode ? 'active' : ''}
                onClick={() => setNetworkMode(mode)}
              >
                {networkLabels[mode]}
              </button>
            ))}
          </div>
          <label className="agent-toggle">
            <input
              type="checkbox"
              checked={agentMode}
              onChange={(event) => setAgentMode(event.target.checked)}
            />
            <span>智能体模式</span>
            <small>多步工具调用 + 轨迹</small>
          </label>
          <label className="agent-toggle">
            <input
              type="checkbox"
              checked={proposeOnly}
              onChange={(event) => setProposeOnly(event.target.checked)}
            />
            <span>只生成建议</span>
            <small>等待硬件键确认，仅建议不执行</small>
          </label>
          <div className="actions">
            <button type="button" className="primary" onClick={runPlan} disabled={isPlanning}>
              {isPlanning ? '规划中...' : '生成计划'}
            </button>
            <button type="button" onClick={resetDevices}>
              重置家庭
            </button>
          </div>
          {error && <p className="error">{error}</p>}
        </div>

        <div className="panel context-panel">
          <div className="panel-header">
            <p className="eyebrow">本地上下文</p>
            <h2>边缘侧保留</h2>
          </div>
          {context ? (
            <div className="context-grid">
              <InfoBlock title="房间" value={translateValue(context.home.room)} />
              <InfoBlock title="时间" value={context.home.time} />
              <InfoBlock title="天气" value={translateValue(context.home.weather)} />
              <InfoBlock title="状态" value={translateValue(context.user.mood)} />
              <InfoBlock title="偏好" value={translateValue(context.user.preference)} />
              <InfoBlock title="隐私" value={translateValue(context.user.privacy_policy)} />
            </div>
          ) : (
            <p className="muted">等待边缘上下文。</p>
          )}
        </div>

        <div className="panel scene-panel">
          <div className="panel-header">
            <p className="eyebrow">家庭场景</p>
            <h2>手机视觉摘要</h2>
          </div>
          <textarea
            className="scene-input"
            value={sceneHint}
            onChange={(event) => setSceneHint(event.target.value)}
            aria-label="场景提示"
          />
          <div className={`camera-surface ${cameraActive ? 'active' : ''}`}>
            <video
              ref={cameraPreviewRef}
              className={`camera-preview ${shouldMirrorPreview(cameraPreference) ? 'mirror' : ''}`}
              aria-label="手机前置摄像头预览"
              autoPlay
              muted
              playsInline
            />
            {!cameraActive && (
              <div className="camera-placeholder">{sceneImageBase64 ? '画面已截取' : '优先前置摄像头待机'}</div>
            )}
          </div>
          <div className="camera-controls">
            <button type="button" onClick={startCamera}>
              优先打开前置摄像头
            </button>
            <button type="button" onClick={captureSceneFrame} disabled={!cameraActive}>
              截取画面
            </button>
            <button type="button" onClick={stopCamera} disabled={!cameraActive}>
              停止
            </button>
          </div>
          <div className="camera-status-row">
            <span>{cameraStatus}</span>
            {sceneImageBase64 && <strong>{formatImageSize(sceneImageBase64)}</strong>}
          </div>
          {cameraError && <p className="camera-error">{cameraError}</p>}
          <div className="actions scene-actions">
            <button type="button" className="primary" onClick={readScene} disabled={isReadingScene}>
              {isReadingScene ? '分析中...' : '分析场景'}
            </button>
            <button type="button" onClick={useScenePrompt} disabled={!scene}>
              写入请求
            </button>
          </div>
          {scene ? (
            <div className="scene-result">
              <div className="source-row">
                <span>场景</span>
                <strong>{translateValue(scene.scene)}</strong>
              </div>
              <div className="source-row">
                <span>置信度</span>
                <strong>{Math.round(scene.confidence * 100)}%</strong>
              </div>
              <p className="privacy">{formatPrivacySummary(scene.privacy_summary)}</p>
              <ul className="scene-observations">
                {scene.observations.map((item) => (
                  <li key={item}>{translateValue(item)}</li>
                ))}
              </ul>
            </div>
          ) : (
            <p className="muted">先分析房间场景，再写入计划请求。</p>
          )}
        </div>

        <div className="panel plan-panel">
          <div className="panel-header">
            <p className="eyebrow">受控家庭计划</p>
            <h2>{routine ? translateMode(routine.mode) : '待命'}</h2>
          </div>
          {routine && (
            <>
              <div className={`status-badge ${executed ? 'executed' : 'pending'}`}>
                {executed ? '已本地执行' : '等待硬件确认'}
              </div>
              {executed && executionSource !== 'none' && (
                <p className="sync-source">确认来源：{translateSource(executionSource)}</p>
              )}
            </>
          )}
          {routine ? (
            <>
              <div className="source-row">
                <span>规划器</span>
                <strong>{translateSource(routine.provider)}</strong>
              </div>
              <p className="summary">{translateValue(routine.summary)}</p>
              <p className="privacy">{translateValue(routine.privacy_summary)}</p>
              <ol className="reasoning">
                {routine.reasoning.map((item) => (
                  <li key={item}>{translateValue(item)}</li>
                ))}
              </ol>
              {!executed && (
                <div className="actions plan-actions">
                  <button
                    type="button"
                    className="primary"
                    onClick={confirmActions}
                    disabled={isExecuting || getConfirmableActions(routine.actions, precheck).length === 0}
                  >
                    {isExecuting ? '执行中...' : '确认执行'}
                  </button>
                  <button type="button" onClick={resetDevices} disabled={isExecuting}>
                    重置家庭
                  </button>
                </div>
              )}
            </>
          ) : (
            <p className="muted">生成计划后会显示结构化家庭流程。</p>
          )}
        </div>
      </section>

      <section className="lower-grid">
        <div className="panel">
          <div className="panel-header">
            <p className="eyebrow">本地动作</p>
            <h2>设备模拟器</h2>
          </div>
          <div className="device-grid">
            {Object.entries(devices).map(([key, device]) => (
              <div className="device-card" key={key}>
                <span>{translateValue(device.label)}</span>
                <strong>{translateValue(device.state)}</strong>
                <small>{formatDeviceDetail(device)}</small>
              </div>
            ))}
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <p className="eyebrow">执行守卫</p>
            <h2>{executed ? '策略已校验' : '等待确认'}</h2>
          </div>
          <div className="execution-list">
            {execution.length ? (
              execution.map((item) => (
                <div className={`execution-row ${item.accepted ? 'accepted' : 'rejected'}`} key={`${item.device}-${item.command}`}>
                  <span>{item.accepted ? '已接受' : '已拒绝'}</span>
                  <strong>
                    {formatActionName(item.device, item.command)}
                  </strong>
                  <small>{formatActionValue(item.value)} - {translateValue(item.reason)}</small>
                </div>
              ))
            ) : precheck.length ? (
              precheck.map((item) => (
                <div className={`execution-row pending ${item.accepted ? 'accepted' : 'rejected'}`} key={`${item.device}-${item.command}`}>
                  <span>{item.accepted ? '待确认' : '已拒绝'}</span>
                  <strong>
                    {formatActionName(item.device, item.command)}
                  </strong>
                  <small>{formatActionValue(item.value)} - {translateValue(item.reason)}</small>
                </div>
              ))
            ) : (
              <p className="muted">结构化动作会先通过本地策略校验。</p>
            )}
          </div>
        </div>

        <div className="panel">
          <div className="panel-header">
            <p className="eyebrow">建议</p>
            <h2>家庭提示</h2>
          </div>
          <div className="suggestion-list">
            {routine?.suggestions.length ? (
              routine.suggestions.map((suggestion) => (
                <article key={`${suggestion.type}-${suggestion.title}`} className="suggestion-card">
                  <span>{translateValue(suggestion.type)}</span>
                  <strong>{translateValue(suggestion.title)}</strong>
                  <p>{translateValue(suggestion.detail)}</p>
                </article>
              ))
            ) : (
              <p className="muted">餐食、媒体、舒适度和提醒建议会显示在这里。</p>
            )}
          </div>
        </div>
      </section>

      {trace.length > 0 && (
        <section className="trace-section">
          <div className="panel trace-panel">
            <div className="panel-header trace-header">
              <div>
                <p className="eyebrow">智能体轨迹</p>
                <h2>决策步骤</h2>
              </div>
              <button type="button" className="trace-toggle" onClick={() => setShowTrace((value) => !value)}>
                {showTrace ? '收起' : '展开'}
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
          <span className="trace-step">步骤 {step.step}</span>
          <strong>{translateToolName(step.name)}</strong>
          <span className="trace-kind">工具调用</span>
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
          <span className="trace-step">步骤 {step.step}</span>
          <strong>最终计划</strong>
        </div>
        <small className="trace-args">{translateValue((step.content ?? '').slice(0, 160)) || '已输出流程。'}</small>
      </li>
    )
  }

  return (
    <li className="trace-row warn">
      <div className="trace-meta">
        <span className="trace-step">步骤 {step.step}</span>
        <strong>{translateTraceType(step.type)}</strong>
      </div>
      <small className="trace-args">{translateValue(step.content ?? '')}</small>
    </li>
  )
}

function countAccepted(result: unknown): { label: string; rejected: boolean } | null {
  if (!result || typeof result !== 'object') return null
  const record = result as Record<string, unknown>
  if (typeof record.accepted_count === 'number' && typeof record.rejected_count === 'number') {
    return {
      label: `守卫：${record.accepted_count} 个通过，${record.rejected_count} 个拒绝`,
      rejected: record.rejected_count > 0,
    }
  }
  return null
}

function summarizeArgs(args: Record<string, unknown> | undefined): string {
  if (!args || Object.keys(args).length === 0) return '无参数'
  if (Array.isArray((args as { actions?: unknown }).actions)) {
    const actions = (args as { actions: Array<{ device?: string; command?: string }> }).actions
    return `建议 ${actions.length} 个动作：${actions.map((a) => formatActionName(a.device ?? '', a.command ?? '')).join('、')}`
  }
  return Object.entries(args)
    .slice(0, 4)
    .map(([key, value]) => `${translateKey(key)}：${formatTraceArgValue(value)}`)
    .join('，')
}

function getConfirmableActions(actions: DeviceAction[], precheck: PrecheckResult[]) {
  if (!precheck.length) return actions

  return actions.filter((action) =>
    precheck.some(
      (item) =>
        item.accepted &&
        item.device === action.device &&
        item.command === action.command &&
        item.value === action.value,
    ),
  )
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
  if (device.scene) return `场景：${translateValue(device.scene)}`
  if (device.temperature) return `${device.temperature}°C`
  if (device.mode) return `模式：${translateValue(device.mode)}`
  if (device.playlist) return `播放：${translateValue(device.playlist)}`
  if (device.message) return translateValue(device.message)
  return '就绪'
}

function formatPrivacySummary(summary: VisionSceneResponse['privacy_summary']) {
  return Object.entries(summary)
    .map(([key, value]) => `${translateKey(key)}：${translateValue(String(value))}`)
    .join(' / ')
}

function formatImageSize(base64: string) {
  return `约 ${Math.max(1, Math.round((base64.length * 3) / 4 / 1024))} KB`
}

function formatTraceArgValue(value: unknown): string {
  if (typeof value === 'string') return translateValue(value)
  if (typeof value === 'number') return String(value)
  if (typeof value === 'boolean') return translateValue(String(value))
  if (Array.isArray(value)) return `${value.length} 项`
  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).slice(0, 3)
    return entries.map(([key, item]) => `${translateKey(key)} ${formatTraceArgValue(item)}`).join('、')
  }
  return '无'
}

function extractTranscript(results: BrowserSpeechResults) {
  const transcripts: string[] = []

  for (let index = 0; index < results.length; index += 1) {
    const transcript = results[index]?.[0]?.transcript?.trim()
    if (transcript) transcripts.push(transcript)
  }

  return transcripts.join('，')
}

async function openPreferredCamera(): Promise<CameraOpenResult> {
  let firstError: unknown

  const labeledFrontCamera = await openLabeledFrontCamera()
  if (labeledFrontCamera) return labeledFrontCamera

  for (const constraints of preferredCameraConstraints) {
    try {
      const stream = await navigator.mediaDevices.getUserMedia(constraints)
      return await preferFrontCamera(stream)
    } catch (error) {
      firstError ??= error
    }
  }

  throw firstError ?? new Error('摄像头不可用')
}

async function preferFrontCamera(stream: MediaStream): Promise<CameraOpenResult> {
  const current = describeCameraStream(stream)

  if (current.facingMode === 'user') {
    return { stream, preference: 'front-facing-mode', ...current }
  }

  if (isFrontCameraLabel(current.trackLabel)) {
    return { stream, preference: 'front-device-label', ...current }
  }

  const labeledFrontCamera = await openLabeledFrontCamera(stream)
  if (labeledFrontCamera) return labeledFrontCamera

  return { stream, preference: 'browser-preferred', ...current }
}

async function openLabeledFrontCamera(currentStream?: MediaStream): Promise<CameraOpenResult | null> {
  if (!navigator.mediaDevices.enumerateDevices) return null

  const currentDeviceId = currentStream?.getVideoTracks()[0]?.getSettings().deviceId
  let devices: MediaDeviceInfo[]
  try {
    devices = await navigator.mediaDevices.enumerateDevices()
  } catch {
    return null
  }

  const frontDevice = devices.find(
    (device) =>
      device.kind === 'videoinput' &&
      device.deviceId &&
      device.deviceId !== currentDeviceId &&
      isFrontCameraLabel(device.label),
  )

  if (!frontDevice) return null

  try {
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: {
        deviceId: { exact: frontDevice.deviceId },
        height: { ideal: 720 },
        width: { ideal: 1280 },
      },
    })

    currentStream?.getTracks().forEach((track) => track.stop())
    return { stream, preference: 'front-device-label', ...describeCameraStream(stream) }
  } catch {
    return null
  }
}

function describeCameraStream(stream: MediaStream) {
  const track = stream.getVideoTracks()[0]

  return {
    facingMode: track?.getSettings().facingMode,
    trackLabel: track?.label,
  }
}

function isFrontCameraLabel(label: string | undefined) {
  return Boolean(label && frontCameraLabelPattern.test(label))
}

function isBackCameraLabel(label: string | undefined) {
  return Boolean(label && backCameraLabelPattern.test(label))
}

function shouldMirrorPreview(preference: CameraOpenResult['preference'] | null) {
  return preference === 'front-facing-mode' || preference === 'front-device-label'
}

function formatCameraReadyStatus(camera: CameraOpenResult) {
  if (camera.preference === 'front-facing-mode' || camera.preference === 'front-device-label') {
    return '前置摄像头已就绪'
  }

  if (isBackCameraLabel(camera.trackLabel) || camera.facingMode === 'environment') {
    return '摄像头已就绪（浏览器返回后置镜头，已尝试按前置优先请求；可在手机权限弹窗中切换前置镜头）'
  }

  if (camera.facingMode) {
    return `摄像头已就绪（设备返回：${translateCameraFacingMode(camera.facingMode)}，已按前置优先请求）`
  }

  return '摄像头已就绪（已按前置优先请求，浏览器未返回镜头标识）'
}

function translateCameraFacingMode(facingMode: string) {
  const labels: Record<string, string> = {
    environment: '后置',
    left: '左侧',
    right: '右侧',
    user: '前置',
  }

  return labels[facingMode] ?? facingMode
}

function translateSpeechError(error: string | undefined) {
  const labels: Record<string, string> = {
    aborted: '已中断',
    'audio-capture': '无法获取麦克风',
    'bad-grammar': '语法配置错误',
    language_not_supported: '语言不支持',
    network: '网络异常',
    'no-speech': '没有检测到语音',
    'not-allowed': '麦克风权限被拒绝',
    'service-not-allowed': '语音服务不可用',
  }
  return labels[error ?? ''] ?? error ?? '未知错误'
}

function formatRuntimeLabel() {
  return demoRuntime.isStatic ? '静态演示' : '边缘接口'
}

function formatActionName(device: string, command: string) {
  return `${translateDevice(device)} · ${translateCommand(command)}`
}

function formatActionValue(value: string | number | boolean) {
  return translateValue(String(value))
}

function buildScenePrompt(scene: VisionSceneResponse, hint: string) {
  return `根据手机前置摄像头和场景摘要，生成一个可逆、需确认的家庭流程。场景：${translateValue(scene.scene)}。用户补充：${hint.trim()}。`
}

function translateDevice(device: string) {
  const labels: Record<string, string> = {
    light: '客厅灯',
    ac: '空调',
    projector: '投影仪',
    speaker: '音箱',
    reminder: '提醒',
  }
  return labels[device] ?? device
}

function translateCommand(command: string) {
  const labels: Record<string, string> = {
    set_scene: '设置灯光场景',
    set_temperature: '设置温度',
    set_mode: '设置模式',
    play: '播放',
    set: '设置提醒',
  }
  return labels[command] ?? command
}

function translateKey(key: string) {
  const labels: Record<string, string> = {
    accepted_count: '通过数量',
    actions: '动作',
    agent_mode: '智能体模式',
    camera: '摄像头',
    command: '命令',
    device: '设备',
    execute: '执行',
    faces_identified: '识别人脸',
    image_base64: '图像帧',
    name: '名称',
    network_mode: '网络模式',
    note: '说明',
    privacy_note: '隐私说明',
    provider: '提供方',
    raw_image_retained: '保留原始图像',
    reason: '原因',
    rejected_count: '拒绝数量',
    room: '房间',
    scene: '场景',
    schedule_summary: '日程摘要',
    source_prompt: '来源请求',
    text_hint: '文字提示',
    type: '类型',
    value: '值',
  }
  return labels[key] ?? key
}

function translateSource(source: string) {
  const labels: Record<string, string> = {
    mock: '本地模拟',
    mock_after_agent_error: '智能体异常后本地兜底',
    mock_after_qwen_error: '云端异常后本地兜底',
    mock_home_vlm_adapter: '本地视觉摘要适配器',
    static_mock: '静态模拟',
    static_agent: '静态智能体',
    static_fallback: '静态兜底',
    static_home_vlm_adapter: '静态视觉摘要适配器',
    local_fallback: '本地兜底',
    qwen: '云端模型',
    qwen_agent: '云端智能体',
    plan: '计划接口',
    static: '静态状态',
    web: '手机网页',
    'esp32-serial': 'ESP32 串口',
    external: '外部设备',
    reset: '重置',
    none: '无',
  }
  return labels[source] ?? source
}

function translateToolName(name: string | undefined) {
  const labels: Record<string, string> = {
    get_home_context: '读取家庭上下文',
    get_device_states: '读取设备状态',
    propose_actions: '预校验动作',
  }
  return labels[name ?? ''] ?? name ?? '工具'
}

function translateTraceType(type: string) {
  const labels: Record<string, string> = {
    tool_call: '工具调用',
    final: '最终计划',
    max_steps_reached: '达到最大步数',
    error: '错误',
  }
  return labels[type] ?? `未知轨迹：${type.replaceAll('_', ' ')}`
}

function translateMode(mode: string) {
  const labels: Record<string, string> = {
    mock_cloud_reasoning: '本地模拟推理',
    mock_after_agent_error: '智能体异常后本地兜底',
    mock_after_qwen_error: '云端异常后本地兜底',
    weak_network_cached_context: '弱网缓存上下文',
    offline_fallback: '离线兜底',
    static_agent_reasoning: '静态智能体推理',
    static_mock_reasoning: '静态模拟推理',
    qwen_cloud_reasoning: '云端模型推理',
    qwen_agent_reasoning: '云端智能体推理',
    agent_max_steps_fallback: '智能体兜底',
  }
  return labels[mode] ?? `未知模式：${mode.replaceAll('_', ' ')}`
}

function translateValue(value: string): string {
  const normalizedValue = value.trim()
  const labels: Record<string, string> = {
    'living room': '客厅',
    'user just arrived home': '用户刚回到家',
    'Living room light': '客厅灯',
    'Air conditioner': '空调',
    Projector: '投影仪',
    Speaker: '音箱',
    Reminder: '提醒',
    'light rain, 18C': '小雨，18C',
    tired: '疲惫',
    'warm lighting, quiet movie nights, simple meals': '暖色灯光、安静观影、简单餐食',
    'raw calendar and sensor data stay local; only summaries are sent to cloud reasoning':
      '原始日程和传感器数据留在本地，只把摘要发送给模型推理',
    'low-energy evening arrival': '低能量晚间回家',
    'shared family activity': '家庭共同活动',
    'ordinary home context': '普通家庭场景',
    phone: '手机',
    desktop: '桌面端',
    'esp32-cam': 'ESP32 摄像头',
    mock: '本地模拟',
    'mock_home_vlm_adapter': '本地视觉摘要适配器',
    'static_home_vlm_adapter': '静态视觉摘要适配器',
    'home-scene VLM adapter placeholder': '家庭场景视觉适配器占位',
    true: '是',
    false: '否',
    'Only a compact scene label and observations are passed to planning.': '只把紧凑场景标签和观察摘要传给规划器。',
    'input_camera=phone': '输入摄像头：手机',
    'room=living room': '房间：客厅',
    'image frame provided': '已提供图像帧',
    'static demo scene summary': '静态演示场景摘要',
    'no raw image retained': '不保留原始图像',
    warm: '暖光',
    bright: '明亮',
    night: '夜间',
    cinema: '影院',
    standby: '待机',
    'soft ambient': '柔和氛围',
    focus: '专注',
    none: '无',
    off: '关闭',
    on: '开启',
    scheduled: '已安排',
    empty: '空',
    default: '默认',
    meal: '餐食',
    movie: '观影',
    comfort: '舒适',
    'Tomato egg noodles': '番茄鸡蛋面',
    'Fast, warm, and low effort.': '快速、温热、低负担。',
    'Quiet sci-fi night': '安静科幻夜',
    'Pick a familiar film to avoid decision fatigue.': '选择熟悉的电影，减少决策负担。',
    'Prepare a low-effort evening routine that helps the user settle in at home.':
      '准备一个低负担的晚间流程，帮助用户在家放松下来。',
    'Only home state, mood label, weather, and schedule summaries are used for planning.':
      '规划只使用家庭状态、情绪标签、天气和日程摘要。',
    'User sounds tired, so the routine should reduce decisions and keep the room calm.':
      '用户看起来疲惫，流程应减少决策并保持房间安静。',
    'Rainy weather and evening time suggest warm light, mild temperature, and quiet media.':
      '雨天和晚间更适合暖光、舒适温度和安静媒体。',
    'A later project review means reminders should be gentle and not interrupt rest.':
      '稍晚还有项目回顾，提醒应轻量且不打断休息。',
    'Weak-network mode uses cached local context and compact cloud reasoning.':
      '弱网模式使用本地缓存上下文和紧凑云端推理。',
    'Agent inspected context and device states, then pre-validated actions via the edge guard.':
      '智能体已检查上下文和设备状态，并通过边缘守卫预校验动作。',
    'Cloud is unavailable, so HomeCue Edge runs a local comfort routine.':
      '云端不可用，边缘侧运行本地舒适流程。',
    'No cloud request is made in offline mode.': '离线模式不会发起云端请求。',
    'Offline mode uses a safe local rule set.': '离线模式使用安全的本地规则集。',
    'The routine keeps comfort actions simple and reversible.': '流程保持动作简单且可逆。',
    'Agent planning failed; falling back to local mock plan.': '智能体规划失败，已回退到本地模拟计划。',
    'Agent did not converge within MAX_STEPS; falling back to local mock plan.':
      '智能体在最大步数内未收敛，已回退到本地模拟计划。',
    'Qwen planned a routine.': '云端模型已生成家庭流程。',
    'Only local summary was used.': '仅使用本地摘要。',
    'Use comfort preferences.': '使用舒适偏好。',
    'Keep actions reversible.': '保持动作可逆。',
    'Dim lights': '调暗灯光',
    'Use a warm scene.': '使用暖光场景。',
    'Agent settled the room.': '智能体已安排房间状态。',
    'Only edge summaries were used.': '仅使用边缘侧摘要。',
    'Checked context': '已检查上下文',
    'Validated actions': '已校验动作',
    'Warm scene.': '暖光场景。',
    'Simple warm dinner': '简单热晚餐',
    'Use a low-effort pantry option.': '选择低负担的储备食材。',
    'passes edge policy (not yet executed)': '通过边缘策略（尚未执行）',
    'executed locally': '已本地执行',
    'action not allowed by edge policy': '动作被边缘策略拒绝',
    'unknown device': '未知设备',
    'Review project notes at 21:10': '21:10 回顾项目笔记',
    '21:10 回顾项目笔记': '21:10 回顾项目笔记',
    'Cloud planning unavailable; basic home routine active.': '云端规划不可用，已启用基础家庭流程。',
    'short project review': '短项目复盘',
    'sleep target': '准备休息',
    'Raw local data is not sent. This payload is a compact edge-side summary.':
      '原始本地数据不会上传，这里只传递边缘侧摘要。',
    '2 evening items; next reminder is a short project review at 21:30': '今晚有 2 个事项；下一项是 21:30 短项目复盘',
    'User appears to be settling in after a tiring day. Prepare a calm, low-effort home routine with warm light and minimal interruptions.':
      '用户像是在疲惫一天后回到家。准备一个安静、低负担、暖光且尽量少打扰的家庭流程。',
    'The room appears to be used by multiple people. Keep suggestions family-safe, explain device changes, and avoid disruptive actions.':
      '房间可能有多人使用。建议保持适合家庭，说明设备变化，并避免打扰性动作。',
    'Use the current room context and user preference summary to propose a reversible comfort routine.':
      '使用当前房间上下文和用户偏好摘要，提出一个可逆的舒适流程。',
  }

  if (normalizedValue.startsWith('text_hint=')) {
    return `文字提示：${normalizedValue.slice('text_hint='.length)}`
  }
  if (normalizedValue.startsWith('room=')) {
    return `房间：${translateValue(normalizedValue.slice('room='.length))}`
  }
  if (normalizedValue.startsWith('camera=')) {
    return `摄像头：${translateValue(normalizedValue.slice('camera='.length))}`
  }
  if (normalizedValue.startsWith('input_camera=')) {
    return `输入摄像头：${translateValue(normalizedValue.slice('input_camera='.length))}`
  }

  return labels[normalizedValue] ?? normalizedValue
}

export default App
