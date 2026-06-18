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
    room: '客厅',
    time: '19:35',
    weather: '小雨，18C',
    occupancy: '用户刚回到家',
  },
  user: {
    mood: '疲惫',
    preference: '暖色灯光、安静观影、简单餐食',
    privacy_policy: '原始日程和传感器数据留在本地，只把摘要发送给模型推理',
  },
  schedule: [
    { time: '21:30', title: '项目复盘' },
    { time: '23:30', title: '准备休息' },
  ],
}

const defaultDevices: DeviceState = {
  light: { label: '客厅灯', state: 'off', scene: 'default' },
  ac: { label: '空调', state: 'off', temperature: 24 },
  projector: { label: '投影仪', state: 'off', mode: 'standby' },
  speaker: { label: '音箱', state: 'off', playlist: 'none' },
  reminder: { label: '提醒', state: 'empty', message: '' },
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
        home: { room: '客厅', time: '19:35', weather: '小雨，18C', occupancy: '用户刚回到家' },
        user: { mood: '疲惫', preference: '暖色灯光、安静观影、简单餐食' },
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
    '用户看起来疲惫，流程应减少决策并保持房间安静。',
    '雨天和晚间更适合暖光、舒适温度和安静媒体。',
    '稍晚还有项目回顾，提醒应轻量且不打断休息。',
  ]

  if (useAgent) {
    reasoning.unshift('智能体已检查上下文和设备状态，并通过边缘守卫预校验动作。')
  }

  if (networkMode === 'weak') {
    reasoning.unshift('弱网模式使用本地缓存上下文和紧凑云端推理。')
  }

  const mode = networkMode === 'weak'
    ? 'weak_network_cached_context'
    : useAgent
      ? 'static_agent_reasoning'
      : 'static_mock_reasoning'

  return {
    mode,
    summary: '准备一个低负担的晚间流程，帮助用户在家放松下来。',
    privacy_summary: '规划只使用家庭状态、情绪标签、天气和日程摘要。',
    reasoning,
    actions: [
      { device: 'light', command: 'set_scene', value: 'warm' },
      { device: 'ac', command: 'set_temperature', value: 26 },
      { device: 'projector', command: 'set_mode', value: 'cinema' },
      { device: 'speaker', command: 'play', value: 'soft ambient' },
      { device: 'reminder', command: 'set', value: '21:10 回顾项目笔记' },
    ],
    suggestions: [
      { type: 'meal', title: '番茄鸡蛋面', detail: '快速、温热、低负担。' },
      { type: 'movie', title: '安静科幻夜', detail: '选择熟悉的电影，减少决策负担。' },
    ],
    source_prompt: prompt,
    provider: useAgent ? 'static_agent' : 'static_mock',
  }
}

function buildFallbackPlan(prompt: string): Routine {
  return {
    mode: 'offline_fallback',
    summary: '云端不可用，边缘侧运行本地舒适流程。',
    privacy_summary: '离线模式不会发起云端请求。',
    reasoning: ['离线模式使用安全的本地规则集。', '流程保持动作简单且可逆。'],
    actions: [
      { device: 'light', command: 'set_scene', value: 'warm' },
      { device: 'ac', command: 'set_temperature', value: 26 },
      { device: 'reminder', command: 'set', value: '云端规划不可用，已启用基础家庭流程。' },
    ],
    suggestions: [{ type: 'meal', title: '简单热晚餐', detail: '选择低负担的储备食材。' }],
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
