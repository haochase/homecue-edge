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
  actions: Array<{ device: string; command: string; value: string | number | boolean }>
  suggestions: Array<{ type: string; title: string; detail: string }>
  source_prompt: string
  provider: string
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
}

export type InitialState = {
  context: HomeContext
  devices: DeviceState
}

export type VoiceMemory = {
  memory_id: string
  memory_type: string
  content: string
  source_text: string
  user_id: string
  device_id: string
  updated_at: number
}

export type VoiceTask = {
  task_id: string
  title: string
  detail: string
  due_text: string
  recurrence: string
  due_at: number | null
  reminded_at: number | null
  status: 'open' | 'done' | 'cancelled'
  user_id: string
  device_id: string
}

export type VoiceMood = {
  mood_id: string
  mood: string
  valence: number
  confidence: number
  source_text: string
  user_id: string
  device_id: string
  created_at: number
}

export type VoiceRuntimeStatus = {
  provider: string
  model: string
  tts: {
    provider: string
    model: string
    voice: string
    configured: boolean
  }
  memory: {
    sqlite_enabled: boolean
  }
  asr: {
    provider: string
    model: string
    language: string
    effective_provider: string
    faster_whisper_available?: boolean
    windows_available?: boolean
    windows_speech_available?: boolean
  }
  realtime: {
    websocket: boolean
    pcm_s16le: boolean
    stt_partial_events: boolean
    audio_partial_asr: boolean
    mimo_streaming_tts: boolean
    opus_stream: boolean
    full_duplex: boolean
  }
}

export type Esp32DiagHealth = {
  base_url: string
  health: {
    status?: string
    wifi_ip?: string
    i2s_ready?: boolean
    es8311_ready?: boolean
    speaker_pa_enabled?: boolean
    esp_sr_started?: boolean
    [key: string]: unknown
  }
}

export type Esp32SpeakerTestResult = {
  base_url: string
  speaker_test: {
    ok?: boolean
    seconds?: number
    mode?: string
    speaker_pa_enabled?: boolean
    [key: string]: unknown
  }
  human_audible_confirmation_required: boolean
}

export type VoiceWsEvent = Record<string, unknown> & {
  type?: string
  state?: string
  text?: string
  detail?: string
  session_id?: string
  turn_index?: number
  provider?: string
}
