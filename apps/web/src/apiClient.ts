import { buildStaticPlan, executeStaticActions, getDefaultDevices, getStaticContext } from './staticDemo'
import type {
  DeviceAction,
  DeviceState,
  ExecuteResponse,
  ExecutionSyncState,
  InitialState,
  NetworkMode,
  PlanResponse,
  VisionSceneResponse,
} from './types'

const searchParams = new URLSearchParams(window.location.search)
const urlApiBase = searchParams.get('apiBase')
const urlDemoMode = searchParams.get('demo')

const staticDemoRequested = urlDemoMode === 'static' || urlApiBase === 'static' || import.meta.env.VITE_STATIC_DEMO === 'true'
const apiBase = urlApiBase && urlApiBase !== 'static' ? urlApiBase : import.meta.env.VITE_API_BASE ?? 'http://localhost:8723'

export const demoRuntime = {
  isStatic: staticDemoRequested,
  label: staticDemoRequested ? '静态演示' : '边缘接口',
  detail: staticDemoRequested ? '公开静态演示' : apiBase,
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

export async function requestExecuteActions(
  actions: DeviceAction[],
  devices: DeviceState,
  source = 'web',
): Promise<ExecuteResponse> {
  if (demoRuntime.isStatic) {
    return executeStaticActions(actions, Object.keys(devices).length ? devices : getDefaultDevices())
  }

  const response = await fetch(`${apiBase}/execute`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ actions, source }),
  })

  if (!response.ok) {
    throw new Error('Execute request failed')
  }

  return response.json()
}

export async function requestLatestExecution(): Promise<ExecutionSyncState> {
  if (demoRuntime.isStatic) {
    return {
      sequence: 0,
      source: 'static',
      executed: false,
      execution: [],
      devices: getDefaultDevices(),
    }
  }

  const response = await fetch(`${apiBase}/execution/latest`)
  if (!response.ok) {
    throw new Error('Latest execution fetch failed')
  }

  return response.json()
}

export async function requestVisionScene(
  textHint: string,
  room = 'living room',
  imageBase64 = '',
): Promise<VisionSceneResponse> {
  const fallback: VisionSceneResponse = {
    provider: 'static_home_vlm_adapter',
    scene: textHint.toLowerCase().includes('tired') ? 'low-energy evening arrival' : 'ordinary home context',
    confidence: 0.6,
    observations: [
      'input_camera=phone',
      `room=${room}`,
      imageBase64 ? 'image frame provided' : 'static demo scene summary',
    ],
    privacy_summary: {
      room,
      raw_image_retained: false,
      faces_identified: false,
    },
    suggested_prompt: textHint.trim()
      ? `根据当前场景摘要生成一个可逆的家庭流程：${textHint.trim()}`
      : '使用当前房间上下文和用户偏好摘要，提出一个可逆的舒适流程。',
    model_route: '静态家庭场景视觉适配器',
  }

  if (demoRuntime.isStatic) {
    return fallback
  }

  const response = await fetch(`${apiBase}/vision/scene`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ room, camera: 'phone', text_hint: textHint, image_base64: imageBase64 }),
  })

  if (!response.ok) {
    throw new Error('Vision scene request failed')
  }

  return response.json()
}
