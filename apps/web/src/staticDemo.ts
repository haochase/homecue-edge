import type {
  DeviceAction,
  DeviceState,
  ExecuteResponse,
  ExecutionResult,
  HomeContext,
  NetworkMode,
  PlanResponse,
  Routine,
  TraceStep,
} from './types'

const staticContext: HomeContext = {
  home: {
    room: 'living room',
    time: '19:35',
    weather: 'light rain, 18C',
    occupancy: 'user just arrived home',
  },
  user: {
    mood: 'tired',
    preference: 'warm lighting, quiet movie nights, simple meals',
    privacy_policy: 'raw calendar and sensor data stay local; only summaries are sent to cloud reasoning',
  },
  schedule: [
    { time: '21:30', title: '项目复盘' },
    { time: '23:30', title: '准备休息' },
  ],
}

const defaultDevices: DeviceState = {
  light: { label: 'Living room light', state: 'off', scene: 'default' },
  ac: { label: 'Air conditioner', state: 'off', temperature: 24 },
  projector: { label: 'Projector', state: 'off', mode: 'standby' },
  speaker: { label: 'Speaker', state: 'off', playlist: 'none' },
  reminder: { label: 'Reminder', state: 'empty', message: '' },
}

const allowedActions = {
  light: { set_scene: new Set(['warm', 'bright', 'night']) },
  ac: { set_temperature: { min: 18, max: 30 } },
  projector: { set_mode: new Set(['cinema', 'standby']) },
  speaker: { play: new Set(['soft ambient', 'focus', 'none']) },
  reminder: { set: 'text' },
} as const

function clone<T>(value: T): T {
  return structuredClone(value)
}

export function getStaticContext(): HomeContext {
  return clone(staticContext)
}

export function getDefaultDevices(): DeviceState {
  return clone(defaultDevices)
}

export function buildStaticPlan(
  prompt: string,
  networkMode: NetworkMode,
  currentDevices: DeviceState,
  agentMode = false,
  execute = true,
): PlanResponse {
  const useAgent = agentMode && networkMode !== 'offline'
  const routine = networkMode === 'offline' ? buildFallbackPlan(prompt) : buildMockPlan(prompt, networkMode, useAgent)
  const devices = clone(currentDevices)
  // Read-only pre-check mirrors the edge guard without mutating device state.
  const precheck = routine.actions.map((action) => applyAction(clone(devices), action))
  // Propose-only: leave devices untouched, awaiting hardware confirmation.
  const execution = execute ? routine.actions.map((action) => applyAction(devices, action)) : []

  return {
    context: getStaticContext(),
    routine,
    execution,
    precheck,
    executed: execute,
    devices,
    trace: useAgent ? buildStaticTrace(prompt) : [],
  }
}

export function executeStaticActions(actions: DeviceAction[], currentDevices: DeviceState): ExecuteResponse {
  const devices = clone(currentDevices)
  const execution = actions.map((action) => applyAction(devices, action))

  return { execution, devices }
}

function buildStaticTrace(prompt: string): TraceStep[] {
  return [
    {
      step: 1,
      type: 'tool_call',
      name: 'get_home_context',
      args: {},
      result: {
        home: { room: 'living room', time: '19:35', weather: 'light rain, 18C', occupancy: 'user just arrived home' },
        user: { mood: 'tired', preference: 'warm lighting, quiet movie nights, simple meals' },
        schedule_summary: '今晚还有 2 个事项；下一项是 21:30 项目复盘',
        privacy_note: '原始本地数据不会上传，这里只传递边缘侧摘要。',
      },
    },
    {
      step: 1,
      type: 'tool_call',
      name: 'get_device_states',
      args: {},
      result: {
        light: { state: 'off', scene: 'default' },
        ac: { state: 'off', temperature: 24 },
        projector: { state: 'off', mode: 'standby' },
        speaker: { state: 'off', playlist: 'none' },
        reminder: { state: 'empty', message: '' },
      },
    },
    {
      step: 2,
      type: 'tool_call',
      name: 'propose_actions',
      args: {
        actions: [
          { device: 'light', command: 'set_scene', value: 'warm' },
          { device: 'ac', command: 'set_temperature', value: 26 },
          { device: 'projector', command: 'set_mode', value: 'cinema' },
          { device: 'speaker', command: 'play', value: 'soft ambient' },
          { device: 'reminder', command: 'set', value: '21:10 回顾项目笔记' },
        ],
      },
      result: {
        results: [
          { device: 'light', command: 'set_scene', value: 'warm', accepted: true, reason: 'passes edge policy (not yet executed)' },
          { device: 'ac', command: 'set_temperature', value: 26, accepted: true, reason: 'passes edge policy (not yet executed)' },
          { device: 'projector', command: 'set_mode', value: 'cinema', accepted: true, reason: 'passes edge policy (not yet executed)' },
          { device: 'speaker', command: 'play', value: 'soft ambient', accepted: true, reason: 'passes edge policy (not yet executed)' },
          { device: 'reminder', command: 'set', value: '21:10 回顾项目笔记', accepted: true, reason: 'passes edge policy (not yet executed)' },
        ],
        accepted_count: 5,
        rejected_count: 0,
        note: '只做预校验，暂不改变设备状态。',
      },
    },
    {
      step: 3,
      type: 'final',
      content: `已校验 5 个动作，输出舒适回家流程：${prompt.slice(0, 80)}`,
    },
  ]
}

function buildMockPlan(prompt: string, networkMode: NetworkMode, useAgent = false): Routine {
  const reasoning = [
    'User sounds tired, so the routine should reduce decisions and keep the room calm.',
    'Rainy weather and evening time suggest warm light, mild temperature, and quiet media.',
    'A later project review means reminders should be gentle and not interrupt rest.',
  ]

  if (useAgent) {
    reasoning.unshift('Agent inspected context and device states, then pre-validated actions via the edge guard.')
  }

  if (networkMode === 'weak') {
    reasoning.unshift('Weak-network mode uses cached local context and compact cloud reasoning.')
  }

  const mode = networkMode === 'weak'
    ? 'weak_network_cached_context'
    : useAgent
      ? 'static_agent_reasoning'
      : 'static_mock_reasoning'

  return {
    mode,
    summary: 'Prepare a low-effort evening routine that helps the user settle in at home.',
    privacy_summary: 'Only home state, mood label, weather, and schedule summaries are used for planning.',
    reasoning,
    actions: [
      { device: 'light', command: 'set_scene', value: 'warm' },
      { device: 'ac', command: 'set_temperature', value: 26 },
      { device: 'projector', command: 'set_mode', value: 'cinema' },
      { device: 'speaker', command: 'play', value: 'soft ambient' },
      { device: 'reminder', command: 'set', value: '21:10 回顾项目笔记' },
    ],
    suggestions: [
      { type: 'meal', title: 'Tomato egg noodles', detail: 'Fast, warm, and low effort.' },
      { type: 'movie', title: 'Quiet sci-fi night', detail: 'Pick a familiar film to avoid decision fatigue.' },
    ],
    source_prompt: prompt,
    provider: useAgent ? 'static_agent' : 'static_mock',
  }
}

function buildFallbackPlan(prompt: string): Routine {
  return {
    mode: 'offline_fallback',
    summary: 'Cloud is unavailable, so HomeCue Edge runs a local comfort routine.',
    privacy_summary: 'No cloud request is made in offline mode.',
    reasoning: ['Offline mode uses a safe local rule set.', 'The routine keeps comfort actions simple and reversible.'],
    actions: [
      { device: 'light', command: 'set_scene', value: 'warm' },
      { device: 'ac', command: 'set_temperature', value: 26 },
      { device: 'reminder', command: 'set', value: 'Cloud planning unavailable; basic home routine active.' },
    ],
    suggestions: [{ type: 'meal', title: 'Simple warm dinner', detail: 'Use a low-effort pantry option.' }],
    source_prompt: prompt,
    provider: 'static_fallback',
  }
}

function applyAction(devices: DeviceState, action: DeviceAction): ExecutionResult {
  const { device, command, value } = action

  if (!(device in devices)) {
    return { device, command, value, accepted: false, reason: 'unknown device' }
  }

  if (!isAllowed(device, command, value)) {
    return { device, command, value, accepted: false, reason: 'action not allowed by edge policy' }
  }

  if (device === 'light' && command === 'set_scene' && typeof value === 'string') {
    devices[device].state = 'on'
    devices[device].scene = value
  } else if (device === 'ac' && command === 'set_temperature' && typeof value === 'number') {
    devices[device].state = 'on'
    devices[device].temperature = value
  } else if (device === 'projector' && command === 'set_mode' && typeof value === 'string') {
    devices[device].state = 'on'
    devices[device].mode = value
  } else if (device === 'speaker' && command === 'play' && typeof value === 'string') {
    devices[device].state = 'on'
    devices[device].playlist = value
  } else if (device === 'reminder' && command === 'set' && typeof value === 'string') {
    devices[device].state = 'scheduled'
    devices[device].message = value
  }

  return { device, command, value, accepted: true, reason: 'executed locally' }
}

function isAllowed(device: string, command: string, value: string | number | boolean): boolean {
  if (device === 'light' && command === 'set_scene') {
    return typeof value === 'string' && allowedActions.light.set_scene.has(value)
  }

  if (device === 'ac' && command === 'set_temperature') {
    return typeof value === 'number' && value >= allowedActions.ac.set_temperature.min && value <= allowedActions.ac.set_temperature.max
  }

  if (device === 'projector' && command === 'set_mode') {
    return typeof value === 'string' && allowedActions.projector.set_mode.has(value)
  }

  if (device === 'speaker' && command === 'play') {
    return typeof value === 'string' && allowedActions.speaker.play.has(value)
  }

  if (device === 'reminder' && command === 'set') {
    return typeof value === 'string' && value.length > 0 && value.length <= 160
  }

  return false
}
