export function recomputeBrowserParity(desktop, chrome) {
  const errors = []
  compareParityValue(errors, 'title', desktop?.title, chrome?.title)
  compareParityValue(errors, 'run button', desktop?.localizedUi?.runButton, chrome?.localizedUi?.runButton)
  compareParityValue(
    errors,
    'reset button count',
    desktop?.localizedUi?.resetButtonCount,
    chrome?.localizedUi?.resetButtonCount,
  )
  compareParityValue(
    errors,
    'text integrity mojibake count',
    desktop?.textIntegrity?.mojibakeCount,
    chrome?.textIntegrity?.mojibakeCount,
  )
  compareParityValue(
    errors,
    'text integrity missing phrase count',
    desktop?.textIntegrity?.missingPhraseCount,
    chrome?.textIntegrity?.missingPhraseCount,
  )
  compareParityValue(
    errors,
    'first viewport panel count',
    desktop?.firstViewportVisibility?.panelCount,
    chrome?.firstViewportVisibility?.panelCount,
  )
  compareParityValue(
    errors,
    'first viewport min visible ratio',
    desktop?.firstViewportVisibility?.minVisibleRatio,
    chrome?.firstViewportVisibility?.minVisibleRatio,
  )
  compareParityValue(errors, 'scene', desktop?.scenePromptHandoff?.scene, chrome?.scenePromptHandoff?.scene)
  compareParityValue(
    errors,
    'scene raw image retained',
    desktop?.scenePromptHandoff?.rawImageRetained,
    chrome?.scenePromptHandoff?.rawImageRetained,
  )
  compareParityValue(
    errors,
    'scene raw image echoed',
    desktop?.scenePromptHandoff?.rawImageEchoed,
    chrome?.scenePromptHandoff?.rawImageEchoed,
  )
  compareParityValue(errors, 'web confirmation source', desktop?.webConfirmExecute?.latestSource, chrome?.webConfirmExecute?.latestSource)
  compareParityValue(errors, 'offline fallback source', desktop?.offlineFallback?.latestSource, chrome?.offlineFallback?.latestSource)
  compareParityValue(
    errors,
    'external accepted action count',
    desktop?.externalExecutionSync?.acceptedActionCount,
    chrome?.externalExecutionSync?.acceptedActionCount,
  )
  compareParityValue(errors, 'external sync source', desktop?.externalExecutionSync?.latestSource, chrome?.externalExecutionSync?.latestSource)
  compareParityValue(errors, 'external sync mode', desktop?.externalExecutionSync?.sourceMode, chrome?.externalExecutionSync?.sourceMode)
  compareParityValue(errors, 'runtime issue count', desktop?.runtimeHealth?.issueCount, chrome?.runtimeHealth?.issueCount)
  compareParityValue(errors, 'screenshot count', desktop?.screenshotEvidence?.count, chrome?.screenshotEvidence?.count)
  compareParityValue(
    errors,
    'screenshot unique digest count',
    desktop?.screenshotEvidence?.uniqueDigestCount,
    chrome?.screenshotEvidence?.uniqueDigestCount,
  )
  compareParityValue(errors, 'responsive layout', summaryLayoutSignature(desktop?.responsiveLayout), summaryLayoutSignature(chrome?.responsiveLayout))

  return {
    checked: true,
    success: errors.length === 0,
    errors,
  }
}

export function parityErrorsSignature(value) {
  if (!Array.isArray(value)) return null
  return value.join('|')
}

export function validateBrowserParityInputs(loop, label) {
  const errors = []
  if (!loop?.run) return errors

  const requiredFields = [
    ['firstViewportVisibility.panelCount', loop.firstViewportVisibility?.panelCount],
    ['firstViewportVisibility.minVisibleRatio', loop.firstViewportVisibility?.minVisibleRatio],
    ['scenePromptHandoff.scene', loop.scenePromptHandoff?.scene],
    ['scenePromptHandoff.rawImageRetained', loop.scenePromptHandoff?.rawImageRetained],
    ['scenePromptHandoff.rawImageEchoed', loop.scenePromptHandoff?.rawImageEchoed],
    ['webConfirmExecute.latestSource', loop.webConfirmExecute?.latestSource],
    ['offlineFallback.latestSource', loop.offlineFallback?.latestSource],
    ['externalExecutionSync.acceptedActionCount', loop.externalExecutionSync?.acceptedActionCount],
    ['externalExecutionSync.latestSource', loop.externalExecutionSync?.latestSource],
    ['externalExecutionSync.sourceMode', loop.externalExecutionSync?.sourceMode],
    ['runtimeHealth.issueCount', loop.runtimeHealth?.issueCount],
    ['screenshotEvidence.count', loop.screenshotEvidence?.count],
    ['screenshotEvidence.uniqueDigestCount', loop.screenshotEvidence?.uniqueDigestCount],
  ]

  for (const [field, value] of requiredFields) {
    if (value === null || value === undefined) errors.push(`${label}.${field} is required for browser parity.`)
  }
  if (!Array.isArray(loop.responsiveLayout) || !loop.responsiveLayout.length) {
    errors.push(`${label}.responsiveLayout is required for browser parity.`)
  }

  return errors
}

function compareParityValue(errors, label, left, right) {
  if (left !== right) {
    errors.push(`${label} mismatch (${left ?? 'missing'} != ${right ?? 'missing'})`)
  }
}

function summaryLayoutSignature(value) {
  if (!Array.isArray(value)) return null
  return value
    .map(
      (item) =>
        `${item.label}:${item.overflowX}:${item.overflowingButtonCount ?? 0}:${
          item.overlappingPanelPairCount ?? 0
        }:${item.panelCount ?? 'missing'}`,
    )
    .join('|')
}
