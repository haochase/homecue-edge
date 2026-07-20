import { buildStaticPlan, executeStaticActions, getDefaultDevices, getStaticContext } from './staticDemo'
import type {
  DeviceState,
  Esp32DiagHealth,
  Esp32SpeakerTestResult,
  ExecuteResponse,
  InitialState,
  NetworkMode,
  PlanResponse,
  Routine,
  VoiceMemory,
  VoiceMood,
  VoiceRuntimeStatus,
  VoiceTask,
} from './types'

const searchParams = new URLSearchParams(window.location.search)
const urlApiBase = searchParams.get('apiBase')
const urlApiToken = searchParams.get('apiToken')
const urlDemoMode = searchParams.get('demo')

const staticDemoRequested = urlDemoMode === 'static' || urlApiBase === 'static' || import.meta.env.VITE_STATIC_DEMO === 'true'
const apiBase = urlApiBase && urlApiBase !== 'static' ? urlApiBase : import.meta.env.VITE_API_BASE ?? 'http://localhost:8723'
const apiToken = urlApiToken ?? import.meta.env.VITE_API_TOKEN ?? ''
const authHeaders: HeadersInit = apiToken ? { Authorization: `Bearer ${apiToken}` } : {}

export const demoRuntime = {
  isStatic: staticDemoRequested,
  label: staticDemoRequested ? 'static demo' : 'edge api',
  detail: staticDemoRequested ? 'public no-backend demo' : apiBase,
}

export function buildVoiceChatWsUrl(): string {
  if (demoRuntime.isStatic) return ''

  const resolved = new URL(apiBase.replace(/\/$/, ''), window.location.href)
  resolved.protocol = resolved.protocol === 'https:' ? 'wss:' : 'ws:'
  resolved.pathname = `${resolved.pathname.replace(/\/$/, '')}/voice-chat/ws`
  resolved.search = ''
  if (apiToken) {
    resolved.searchParams.set('access_token', apiToken)
  }
  resolved.hash = ''
  return resolved.toString()
}

export async function loadInitialState(): Promise<InitialState> {
  if (demoRuntime.isStatic) {
    return {
      context: getStaticContext(),
      devices: getDefaultDevices(),
    }
  }

  const [contextResponse, devicesResponse] = await Promise.all([fetch(`${apiBase}/context`), fetch(`${apiBase}/devices`)])

  return {
    context: await contextResponse.json(),
    devices: await devicesResponse.json(),
  }
}

export async function requestPlan(
  prompt: string,
  networkMode: NetworkMode,
  devices: DeviceState,
  agentMode = false,
  execute = true,
): Promise<PlanResponse> {
  if (demoRuntime.isStatic) {
    const currentDevices = Object.keys(devices).length ? devices : getDefaultDevices()
    return buildStaticPlan(prompt, networkMode, currentDevices, agentMode, execute)
  }

  const response = await fetch(`${apiBase}/plan`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt, network_mode: networkMode, agent_mode: agentMode, execute }),
  })

  if (!response.ok) {
    throw new Error('Planning request failed')
  }

  return response.json()
}

export async function executeActions(
  actions: Routine['actions'],
  currentDevices: DeviceState,
): Promise<ExecuteResponse> {
  if (demoRuntime.isStatic) {
    return executeStaticActions(currentDevices, actions)
  }

  const response = await fetch(`${apiBase}/execute`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ actions }),
  })

  if (!response.ok) {
    throw new Error('Execution request failed')
  }

  return response.json()
}

export async function fetchDevices(): Promise<DeviceState> {
  if (demoRuntime.isStatic) {
    return getDefaultDevices()
  }

  const response = await fetch(`${apiBase}/devices`)
  if (!response.ok) {
    throw new Error('Device fetch failed')
  }

  return response.json()
}

export async function fetchVoiceRuntimeStatus(): Promise<VoiceRuntimeStatus> {
  if (demoRuntime.isStatic) {
    return {
      provider: 'static',
      model: 'demo',
      tts: {
        provider: 'static',
        model: 'demo',
        voice: 'browser',
        configured: false,
      },
      memory: {
        sqlite_enabled: false,
      },
      asr: {
        provider: 'disabled',
        model: '',
        language: '',
        effective_provider: 'unavailable',
      },
      realtime: {
        websocket: false,
        pcm_s16le: false,
        stt_partial_events: false,
        audio_partial_asr: false,
        mimo_streaming_tts: false,
        opus_stream: false,
        full_duplex: false,
      },
    }
  }

  const response = await fetch(`${apiBase}/voice-chat/status`, { headers: authHeaders })
  if (!response.ok) {
    throw new Error('Voice runtime status fetch failed')
  }

  return response.json()
}

export async function requestDeviceReset(): Promise<DeviceState> {
  if (demoRuntime.isStatic) {
    return getDefaultDevices()
  }

  const response = await fetch(`${apiBase}/devices/reset`, { method: 'POST' })

  if (!response.ok) {
    throw new Error('Device reset failed')
  }

  return response.json()
}

export async function fetchVoiceMemoryState(userId = 'default'): Promise<{
  memories: VoiceMemory[]
  tasks: VoiceTask[]
  dueTasks: VoiceTask[]
  moods: VoiceMood[]
}> {
  if (demoRuntime.isStatic) {
    return { memories: [], tasks: [], dueTasks: [], moods: [] }
  }

  const encodedUser = encodeURIComponent(userId)
  const [memoriesResponse, tasksResponse, dueResponse, moodsResponse] = await Promise.all([
    fetch(`${apiBase}/voice-chat/memories?user_id=${encodedUser}`, { headers: authHeaders }),
    fetch(`${apiBase}/voice-chat/tasks?user_id=${encodedUser}&status=open`, { headers: authHeaders }),
    fetch(`${apiBase}/voice-chat/tasks/due?user_id=${encodedUser}`, { headers: authHeaders }),
    fetch(`${apiBase}/voice-chat/moods?user_id=${encodedUser}`, { headers: authHeaders }),
  ])

  if (!memoriesResponse.ok || !tasksResponse.ok || !dueResponse.ok || !moodsResponse.ok) {
    throw new Error('Voice memory fetch failed')
  }

  const [memories, tasks, dueTasks, moods] = await Promise.all([
    memoriesResponse.json() as Promise<{ memories: VoiceMemory[] }>,
    tasksResponse.json() as Promise<{ tasks: VoiceTask[] }>,
    dueResponse.json() as Promise<{ tasks: VoiceTask[] }>,
    moodsResponse.json() as Promise<{ moods: VoiceMood[] }>,
  ])

  return {
    memories: memories.memories,
    tasks: tasks.tasks,
    dueTasks: dueTasks.tasks,
    moods: moods.moods,
  }
}

export async function createVoiceTask(title: string, dueText: string, userId = 'default'): Promise<VoiceTask> {
  const response = await fetch(`${apiBase}/voice-chat/tasks`, {
    method: 'POST',
    headers: { ...authHeaders, 'Content-Type': 'application/json' },
    body: JSON.stringify({ title, due_text: dueText, user_id: userId, device_id: 'web-console' }),
  })

  if (!response.ok) {
    throw new Error('Voice task create failed')
  }

  const payload = (await response.json()) as { task: VoiceTask }
  return payload.task
}

export async function updateVoiceTaskStatus(taskId: string, status: VoiceTask['status']): Promise<VoiceTask> {
  const response = await fetch(`${apiBase}/voice-chat/tasks/${encodeURIComponent(taskId)}`, {
    method: 'PATCH',
    headers: { ...authHeaders, 'Content-Type': 'application/json' },
    body: JSON.stringify({ status }),
  })

  if (!response.ok) {
    throw new Error('Voice task update failed')
  }

  const payload = (await response.json()) as { task: VoiceTask }
  return payload.task
}

export async function fetchEsp32DiagHealth(boardBaseUrl: string): Promise<Esp32DiagHealth> {
  if (demoRuntime.isStatic) {
    throw new Error('Static demo mode has no ESP32 diagnostic proxy')
  }

  const response = await fetch(`${apiBase}/esp32/diag/health?base_url=${encodeURIComponent(boardBaseUrl)}`, {
    headers: authHeaders,
  })
  if (!response.ok) {
    throw new Error('ESP32 diagnostic health check failed')
  }

  return response.json()
}

export async function runEsp32SpeakerTest(
  boardBaseUrl: string,
  seconds = 8,
  mode: 'all' | 'both' | 'left' | 'right' | 'sweep' = 'all',
): Promise<Esp32SpeakerTestResult> {
  if (demoRuntime.isStatic) {
    throw new Error('Static demo mode has no ESP32 diagnostic proxy')
  }

  const response = await fetch(`${apiBase}/esp32/diag/speaker-test`, {
    method: 'POST',
    headers: { ...authHeaders, 'Content-Type': 'application/json' },
    body: JSON.stringify({ base_url: boardBaseUrl, seconds, mode }),
  })
  if (!response.ok) {
    throw new Error('ESP32 speaker test failed')
  }

  return response.json()
}
