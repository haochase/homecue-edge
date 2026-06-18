import { buildStaticPlan, getDefaultDevices, getStaticContext } from './staticDemo'
import type { DeviceState, InitialState, NetworkMode, PlanResponse, VisionSceneResponse } from './types'

const searchParams = new URLSearchParams(window.location.search)
const urlApiBase = searchParams.get('apiBase')
const urlDemoMode = searchParams.get('demo')

const staticDemoRequested = urlDemoMode === 'static' || urlApiBase === 'static' || import.meta.env.VITE_STATIC_DEMO === 'true'
const apiBase = urlApiBase && urlApiBase !== 'static' ? urlApiBase : import.meta.env.VITE_API_BASE ?? 'http://localhost:8723'

export const demoRuntime = {
  isStatic: staticDemoRequested,
  label: staticDemoRequested ? 'static demo' : 'edge api',
  detail: staticDemoRequested ? 'public no-backend demo' : apiBase,
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

export async function requestVisionScene(textHint: string, room = 'living room'): Promise<VisionSceneResponse> {
  const fallback: VisionSceneResponse = {
    provider: 'static_home_vlm_adapter',
    scene: textHint.toLowerCase().includes('tired') ? 'low-energy evening arrival' : 'ordinary home context',
    confidence: 0.6,
    observations: ['input_camera=mock', `room=${room}`, 'static demo scene summary'],
    privacy_summary: {
      room,
      raw_image_retained: false,
      faces_identified: false,
    },
    suggested_prompt: textHint.trim()
      ? `Use this scene summary for a reversible home routine: ${textHint.trim()}`
      : 'Use the current room context and user preference summary to propose a reversible comfort routine.',
    model_route: 'static home-scene VLM adapter',
  }

  if (demoRuntime.isStatic) {
    return fallback
  }

  const response = await fetch(`${apiBase}/vision/scene`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ room, camera: 'phone', text_hint: textHint }),
  })

  if (!response.ok) {
    throw new Error('Vision scene request failed')
  }

  return response.json()
}
