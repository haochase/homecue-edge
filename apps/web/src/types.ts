export type NetworkMode = 'online' | 'weak' | 'offline'

export type DeviceState = Record<
  string,
  {
    label: string
    state: string
    scene?: string
    temperature?: number
    mode?: string
    playlist?: string
    message?: string
  }
>

export type Routine = {
  mode: string
  summary: string
  privacy_summary: string
  reasoning: string[]
  actions: DeviceAction[]
  suggestions: Array<{ type: string; title: string; detail: string }>
  source_prompt: string
  provider: string
}

export type DeviceAction = {
  device: string
  command: string
  value: string | number | boolean
}

export type HomeContext = {
  home: Record<string, string>
  user: Record<string, string>
  schedule: Array<{ time: string; title: string }>
}

export type ExecutionResult = {
  device: string
  command: string
  accepted: boolean
  reason: string
  value: string | number | boolean
}

export type TraceStep = {
  step: number
  type: 'tool_call' | 'final' | 'max_steps_reached' | 'error'
  name?: string
  args?: Record<string, unknown>
  result?: unknown
  content?: string
}

export type PrecheckResult = {
  device: string
  command: string
  value: string | number | boolean
  accepted: boolean
  reason: string
}

export type VisionSceneResponse = {
  provider: string
  scene: string
  confidence: number
  observations: string[]
  privacy_summary: Record<string, string | number | boolean>
  suggested_prompt: string
  model_route: string
}

export type PlanResponse = {
  context: HomeContext
  routine: Routine
  execution: ExecutionResult[]
  precheck?: PrecheckResult[]
  executed?: boolean
  devices: DeviceState
  trace?: TraceStep[]
}

export type ExecuteResponse = {
  execution: ExecutionResult[]
  devices: DeviceState
  source?: string
  sequence?: number
  executed?: boolean
}

export type ExecutionSyncState = {
  execution: ExecutionResult[]
  devices: DeviceState
  source: string
  sequence: number
  executed: boolean
}

export type InitialState = {
  context: HomeContext
  devices: DeviceState
}
