export const SUMMARY_ROOT_KEYS = [
  'generatedAt',
  'success',
  'runId',
  'appUrl',
  'apiBase',
  'environment',
  'loops',
  'browserParity',
  'evidence',
]
export const SUMMARY_ENVIRONMENT_KEYS = ['preflight', 'webReadiness']
export const SUMMARY_PREFLIGHT_KEYS = [
  'run',
  'success',
  'generatedAt',
  'required',
  'requirePhone',
  'okCount',
  'warnCount',
  'failCount',
  'checks',
]
export const SUMMARY_PREFLIGHT_CHECK_KEYS = ['name', 'category', 'ok', 'required', 'status', 'detail']
export const SUMMARY_WEB_READINESS_KEYS = [
  'run',
  'success',
  'generatedAt',
  'runId',
  'appUrl',
  'webPort',
  'strategy',
  'portListeningBefore',
  'httpReadyBefore',
  'httpReadyAfter',
  'duplicateStartAvoided',
  'gates',
]
export const SUMMARY_WEB_READINESS_GATE_KEYS = ['httpProbeBeforePortReuse', 'stalePortBlocksDuplicateStart']
export const SUMMARY_LOOPS_KEYS = ['desktop', 'windowsChrome', 'phone']
export const SUMMARY_DESKTOP_LOOP_KEYS = [
  'run',
  'success',
  'runId',
  'startedAt',
  'finishedAt',
  'browserName',
  'pageUrl',
  'title',
  'textIntegrity',
  'localizedUi',
  'firstViewportVisibility',
  'hostEnvironment',
  'browserEnvironment',
  'responsiveLayout',
  'runtimeHealth',
  'screenshotEvidence',
  'scenePromptHandoff',
  'proposeOnly',
  'webConfirmExecute',
  'offlineFallback',
  'externalExecutionSync',
]
export const SUMMARY_PHONE_LOOP_KEYS = [
  'run',
  'success',
  'runId',
  'startedAt',
  'finishedAt',
  'pageUrl',
  'title',
  'textIntegrity',
  'frontCamera',
  'speechInput',
  'scene',
  'scenePromptHandoff',
  'externalExecution',
  'runtimeHealth',
]
export const SUMMARY_SKIPPED_LOOP_KEYS = ['run', 'success']
export const SUMMARY_TEXT_INTEGRITY_KEYS = ['requiredPhraseCount', 'missingPhraseCount', 'mojibakeCount']
export const SUMMARY_LOCALIZED_UI_KEYS = ['title', 'runButton', 'resetButtonCount', 'textIntegrity']
export const SUMMARY_FIRST_VIEWPORT_KEYS = ['minVisibleRatio', 'panelCount', 'hiddenPanelCount']
export const SUMMARY_HOST_ENVIRONMENT_KEYS = ['platform', 'arch', 'nodeVersion', 'nodeMajorVersion', 'ci']
export const SUMMARY_BROWSER_ENVIRONMENT_KEYS = [
  'browserName',
  'userAgent',
  'language',
  'viewport',
  'getUserMedia',
  'speechRecognition',
  'headed',
  'executablePath',
  'executableFileName',
  'executableSource',
  'executableProductName',
  'executableCompanyName',
  'executableProductVersion',
  'runtimeMajorVersion',
  'executableMajorVersion',
  'channel',
]
export const SUMMARY_BROWSER_VIEWPORT_KEYS = ['innerWidth', 'innerHeight', 'devicePixelRatio']
export const SUMMARY_RESPONSIVE_LAYOUT_KEYS = [
  'label',
  'width',
  'height',
  'overflowX',
  'overflowingButtonCount',
  'overlappingPanelPairCount',
  'panelCount',
  'minPanelWidth',
  'minPanelHeight',
]
export const SUMMARY_RUNTIME_HEALTH_KEYS = ['success', 'issueCount', 'counts']
export const SUMMARY_SCREENSHOT_EVIDENCE_KEYS = [
  'success',
  'count',
  'expectedFiles',
  'uniqueDigestCount',
  'minWidth',
  'minHeight',
  'minBytes',
  'minImageDataBytes',
]
export const SUMMARY_PROMPT_HANDOFF_KEYS = [
  'ready',
  'proposeOnly',
  'promptPresent',
  'scene',
  'rawImageRetained',
  'rawImageEchoed',
]
export const SUMMARY_PROPOSE_ONLY_KEYS = ['status', 'latestSource', 'latestExecuted']
export const SUMMARY_WEB_CONFIRM_KEYS = ['latestSource', 'latestSequence', 'acceptedRows']
export const SUMMARY_OFFLINE_FALLBACK_KEYS = ['latestSource', 'latestSequence', 'executionCount']
export const SUMMARY_EXTERNAL_EXECUTION_KEYS = ['latestSource', 'sourceMode', 'latestSequence', 'acceptedActionCount']
export const SUMMARY_FRONT_CAMERA_KEYS = ['ready', 'facingMode', 'width', 'height', 'status', 'mirrored', 'objectFit']
export const SUMMARY_SPEECH_INPUT_KEYS = ['available', 'skipped', 'status']
export const SUMMARY_SCENE_KEYS = ['frameSize', 'rawImageRetained', 'rawImageNotRetained']
export const SUMMARY_BROWSER_PARITY_KEYS = ['checked', 'success', 'errors']
export const SUMMARY_EVIDENCE_KEYS = ['validationErrors', 'files']
export const SUMMARY_EVIDENCE_FILE_KEYS = ['label', 'file', 'present', 'bytes', 'sha256']
export const RAW_DEV_ENV_KEYS = ['generatedAt', 'success', 'required', 'requirePhone', 'checks']
export const RAW_WEB_READINESS_KEYS = [
  'generatedAt',
  'runId',
  'appUrl',
  'webPort',
  'strategy',
  'portListeningBefore',
  'httpReadyBefore',
  'httpReadyAfter',
  'duplicateStartAvoided',
  'gates',
]

export function validateSummaryManifest(errors, value, { labelPrefix = '' } = {}) {
  const prefix = labelPrefix ? `${labelPrefix}.` : ''
  validateAllowedKeys(errors, value, SUMMARY_ROOT_KEYS, `${labelPrefix || 'summary'} root`)
  validateAllowedKeys(errors, value?.environment, SUMMARY_ENVIRONMENT_KEYS, `${prefix}environment`)
  validateAllowedKeys(errors, value?.environment?.preflight, SUMMARY_PREFLIGHT_KEYS, `${prefix}environment.preflight`)
  if (Array.isArray(value?.environment?.preflight?.checks)) {
    for (const check of value.environment.preflight.checks) {
      validateAllowedKeys(errors, check, SUMMARY_PREFLIGHT_CHECK_KEYS, `${prefix}environment.preflight.checks entry`)
    }
  }
  validateAllowedKeys(errors, value?.environment?.webReadiness, SUMMARY_WEB_READINESS_KEYS, `${prefix}environment.webReadiness`)
  validateAllowedKeys(
    errors,
    value?.environment?.webReadiness?.gates,
    SUMMARY_WEB_READINESS_GATE_KEYS,
    `${prefix}environment.webReadiness.gates`,
  )
  validateAllowedKeys(errors, value?.loops, SUMMARY_LOOPS_KEYS, `${prefix}loops`)
  validateDesktopLoopManifest(errors, value?.loops?.desktop, `${prefix}loops.desktop`)
  validateDesktopLoopManifest(errors, value?.loops?.windowsChrome, `${prefix}loops.windowsChrome`)
  validatePhoneLoopManifest(errors, value?.loops?.phone, `${prefix}loops.phone`)
  validateAllowedKeys(errors, value?.browserParity, SUMMARY_BROWSER_PARITY_KEYS, `${prefix}browserParity`)
  validateAllowedKeys(errors, value?.evidence, SUMMARY_EVIDENCE_KEYS, `${prefix}evidence`)
  if (Array.isArray(value?.evidence?.files)) {
    for (const entry of value.evidence.files) {
      validateAllowedKeys(errors, entry, SUMMARY_EVIDENCE_FILE_KEYS, `${prefix}evidence.files ${entry?.label ?? 'entry'}`)
    }
  }
}

export function validateRawDevEnvManifest(errors, raw, label) {
  validateAllowedKeys(errors, raw, RAW_DEV_ENV_KEYS, `${label} raw evidence`)
  if (Array.isArray(raw?.checks)) {
    for (const check of raw.checks) {
      validateAllowedKeys(errors, check, SUMMARY_PREFLIGHT_CHECK_KEYS, `${label} raw evidence checks entry`)
    }
  }
}

export function validateRawDevEnvMatchesSummary(errors, raw, preflight, label, compareValue) {
  compareValue(errors, raw.success === true, preflight.success, `${label}.success raw evidence`, `${label}.success`)
  compareValue(errors, raw.generatedAt ?? null, preflight.generatedAt ?? null, `${label}.generatedAt raw evidence`, `${label}.generatedAt`)
  compareValue(errors, raw.required ?? null, preflight.required ?? null, `${label}.required raw evidence`, `${label}.required`)
  compareValue(errors, raw.requirePhone ?? null, preflight.requirePhone ?? null, `${label}.requirePhone raw evidence`, `${label}.requirePhone`)
  compareValue(
    errors,
    devEnvChecksSignature(raw.checks),
    devEnvChecksSignature(preflight.checks),
    `${label}.checks raw evidence`,
    `${label}.checks`,
  )
}

export function validateRawWebReadinessManifest(errors, raw, label) {
  validateAllowedKeys(errors, raw, RAW_WEB_READINESS_KEYS, `${label} raw evidence`)
  validateAllowedKeys(errors, raw?.gates, SUMMARY_WEB_READINESS_GATE_KEYS, `${label} raw evidence gates`)
}

export function validateRawWebReadinessMatchesSummary(errors, raw, webReadiness, label, compareValue) {
  compareValue(errors, raw.generatedAt ?? null, webReadiness.generatedAt ?? null, `${label}.generatedAt raw evidence`, `${label}.generatedAt`)
  compareValue(errors, raw.runId ?? null, webReadiness.runId ?? null, `${label}.runId raw evidence`, `${label}.runId`)
  compareValue(errors, raw.appUrl ?? null, webReadiness.appUrl ?? null, `${label}.appUrl raw evidence`, `${label}.appUrl`)
  compareValue(errors, raw.webPort ?? null, webReadiness.webPort ?? null, `${label}.webPort raw evidence`, `${label}.webPort`)
  compareValue(errors, raw.strategy ?? null, webReadiness.strategy ?? null, `${label}.strategy raw evidence`, `${label}.strategy`)
  compareValue(
    errors,
    raw.portListeningBefore ?? null,
    webReadiness.portListeningBefore ?? null,
    `${label}.portListeningBefore raw evidence`,
    `${label}.portListeningBefore`,
  )
  compareValue(
    errors,
    raw.httpReadyBefore ?? null,
    webReadiness.httpReadyBefore ?? null,
    `${label}.httpReadyBefore raw evidence`,
    `${label}.httpReadyBefore`,
  )
  compareValue(
    errors,
    raw.httpReadyAfter ?? null,
    webReadiness.httpReadyAfter ?? null,
    `${label}.httpReadyAfter raw evidence`,
    `${label}.httpReadyAfter`,
  )
  compareValue(
    errors,
    raw.duplicateStartAvoided ?? null,
    webReadiness.duplicateStartAvoided ?? null,
    `${label}.duplicateStartAvoided raw evidence`,
    `${label}.duplicateStartAvoided`,
  )
  compareValue(
    errors,
    raw.gates?.httpProbeBeforePortReuse ?? null,
    webReadiness.gates?.httpProbeBeforePortReuse ?? null,
    `${label}.gates.httpProbeBeforePortReuse raw evidence`,
    `${label}.gates.httpProbeBeforePortReuse`,
  )
  compareValue(
    errors,
    raw.gates?.stalePortBlocksDuplicateStart ?? null,
    webReadiness.gates?.stalePortBlocksDuplicateStart ?? null,
    `${label}.gates.stalePortBlocksDuplicateStart raw evidence`,
    `${label}.gates.stalePortBlocksDuplicateStart`,
  )
}

export function validateAllowedKeys(errors, value, allowedKeys, label) {
  if (!value || typeof value !== 'object') return

  const allowed = new Set(allowedKeys)
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      errors.push(`${label} must not include unexpected field: ${key}.`)
    }
  }
}

function devEnvChecksSignature(value) {
  if (!Array.isArray(value)) return null
  return value
    .map((check) =>
      [
        check?.name ?? null,
        check?.category ?? null,
        check?.ok ?? null,
        check?.required ?? null,
        check?.status ?? null,
        check?.detail ?? null,
      ].join(':'),
    )
    .join('|')
}

function validateDesktopLoopManifest(errors, loop, label) {
  if (!loop || typeof loop !== 'object') return
  validateAllowedKeys(errors, loop, loop.run === true ? SUMMARY_DESKTOP_LOOP_KEYS : SUMMARY_SKIPPED_LOOP_KEYS, label)
  if (loop.run !== true) return

  validateAllowedKeys(errors, loop.textIntegrity, SUMMARY_TEXT_INTEGRITY_KEYS, `${label}.textIntegrity`)
  validateAllowedKeys(errors, loop.localizedUi, SUMMARY_LOCALIZED_UI_KEYS, `${label}.localizedUi`)
  validateAllowedKeys(errors, loop.localizedUi?.textIntegrity, SUMMARY_TEXT_INTEGRITY_KEYS, `${label}.localizedUi.textIntegrity`)
  validateAllowedKeys(errors, loop.firstViewportVisibility, SUMMARY_FIRST_VIEWPORT_KEYS, `${label}.firstViewportVisibility`)
  validateAllowedKeys(errors, loop.hostEnvironment, SUMMARY_HOST_ENVIRONMENT_KEYS, `${label}.hostEnvironment`)
  validateAllowedKeys(errors, loop.browserEnvironment, SUMMARY_BROWSER_ENVIRONMENT_KEYS, `${label}.browserEnvironment`)
  validateAllowedKeys(errors, loop.browserEnvironment?.viewport, SUMMARY_BROWSER_VIEWPORT_KEYS, `${label}.browserEnvironment.viewport`)
  if (Array.isArray(loop.responsiveLayout)) {
    for (const item of loop.responsiveLayout) {
      validateAllowedKeys(errors, item, SUMMARY_RESPONSIVE_LAYOUT_KEYS, `${label}.responsiveLayout entry`)
    }
  }
  validateAllowedKeys(errors, loop.runtimeHealth, SUMMARY_RUNTIME_HEALTH_KEYS, `${label}.runtimeHealth`)
  validateAllowedKeys(errors, loop.screenshotEvidence, SUMMARY_SCREENSHOT_EVIDENCE_KEYS, `${label}.screenshotEvidence`)
  validateAllowedKeys(errors, loop.scenePromptHandoff, SUMMARY_PROMPT_HANDOFF_KEYS, `${label}.scenePromptHandoff`)
  validateAllowedKeys(errors, loop.proposeOnly, SUMMARY_PROPOSE_ONLY_KEYS, `${label}.proposeOnly`)
  validateAllowedKeys(errors, loop.webConfirmExecute, SUMMARY_WEB_CONFIRM_KEYS, `${label}.webConfirmExecute`)
  validateAllowedKeys(errors, loop.offlineFallback, SUMMARY_OFFLINE_FALLBACK_KEYS, `${label}.offlineFallback`)
  validateAllowedKeys(errors, loop.externalExecutionSync, SUMMARY_EXTERNAL_EXECUTION_KEYS, `${label}.externalExecutionSync`)
}

function validatePhoneLoopManifest(errors, loop, label) {
  if (!loop || typeof loop !== 'object') return
  validateAllowedKeys(errors, loop, loop.run === true ? SUMMARY_PHONE_LOOP_KEYS : SUMMARY_SKIPPED_LOOP_KEYS, label)
  if (loop.run !== true) return

  validateAllowedKeys(errors, loop.textIntegrity, SUMMARY_TEXT_INTEGRITY_KEYS, `${label}.textIntegrity`)
  validateAllowedKeys(errors, loop.frontCamera, SUMMARY_FRONT_CAMERA_KEYS, `${label}.frontCamera`)
  validateAllowedKeys(errors, loop.speechInput, SUMMARY_SPEECH_INPUT_KEYS, `${label}.speechInput`)
  validateAllowedKeys(errors, loop.scene, SUMMARY_SCENE_KEYS, `${label}.scene`)
  validateAllowedKeys(errors, loop.scenePromptHandoff, SUMMARY_PROMPT_HANDOFF_KEYS, `${label}.scenePromptHandoff`)
  validateAllowedKeys(errors, loop.externalExecution, SUMMARY_EXTERNAL_EXECUTION_KEYS, `${label}.externalExecution`)
  validateAllowedKeys(errors, loop.runtimeHealth, SUMMARY_RUNTIME_HEALTH_KEYS, `${label}.runtimeHealth`)
}
