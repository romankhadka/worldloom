import {expect, test} from "@playwright/test"

import {
  balanced,
  delayedRecovery,
  memoryExpiry,
  totalOutage,
  wikimediaSurge,
} from "../assets/test/fixtures/balanced_snapshots.js"

const externalBaseURL = process.env.WORLDLOOM_BASE_URL
const deterministicHarnessAvailable =
  !externalBaseURL || process.env.WORLDLOOM_E2E_HARNESS === "true"
const deterministicHarnessTest = deterministicHarnessAvailable ? test : test.skip

test("two visitors converge on a persisted gesture and reconstruct it after reload", async ({
  browser,
}) => {
  const contextOptions = {
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
  }
  const firstContext = await browser.newContext(contextOptions)
  const secondContext = await browser.newContext(contextOptions)
  const firstPage = await firstContext.newPage()
  const secondPage = await secondContext.newPage()
  const browserFailures = []
  monitorPage(firstPage, "first", browserFailures)
  monitorPage(secondPage, "second", browserFailures)

  try {
    await Promise.all([firstPage.goto("/"), secondPage.goto("/")])
    expect(browserFailures).toEqual([])

    const firstCanvas = firstPage.locator("#loom-canvas")
    const secondCanvas = secondPage.locator("#loom-canvas")
    await expect
      .poll(async () => ({
        ready: await firstCanvas.getAttribute("data-ready"),
        failures: browserFailures,
      }))
      .toEqual({ready: "true", failures: []})
    await expect
      .poll(async () => ({
        ready: await secondCanvas.getAttribute("data-ready"),
        failures: browserFailures,
      }))
      .toEqual({ready: "true", failures: []})

    const startingSequence = Number(
      await firstCanvas.getAttribute("data-rendered-sequence"),
    )
    expect(startingSequence).toBeGreaterThan(0)
    await expect(secondCanvas).toHaveAttribute(
      "data-rendered-sequence",
      String(startingSequence),
    )

    await firstPage
      .getByRole("button", {name: "Illuminate", exact: true})
      .click()

    await expect
      .poll(async () =>
        Number(await firstCanvas.getAttribute("data-rendered-sequence")),
      )
      .toBeGreaterThan(startingSequence)

    const committedSequence = await firstCanvas.getAttribute(
      "data-rendered-sequence",
    )
    await expect(secondCanvas).toHaveAttribute(
      "data-rendered-sequence",
      committedSequence,
    )

    await secondPage.reload()
    await expect(secondCanvas).toHaveAttribute("data-ready", "true")
    await expect(secondCanvas).toHaveAttribute(
      "data-rendered-sequence",
      committedSequence,
    )
    expect(browserFailures).toEqual([])
  } finally {
    await firstContext.close()
    await secondContext.close()
  }
})

deterministicHarnessTest("a settled live snapshot reconstructs the complete painted scene after reload", async ({
  browser,
}) => {
  const context = await browser.newContext({
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
    reducedMotion: "reduce",
  })
  const page = await context.newPage()
  const browserFailures = monitorPage(page, "snapshot reconstruction")

  try {
    const canvas = await openWorldloom(page)
    const beforeReload = await liveSceneDiagnostics(canvas)
    expect(beforeReload.windowEnd).not.toBeNull()
    expect(beforeReload.commitWatermark).toBeGreaterThan(0)
    expect(beforeReload.scene.paintCommands.length).toBeGreaterThan(0)

    await page.reload()
    const afterReload = await liveSceneDiagnostics(canvas)

    expect(afterReload).toEqual(beforeReload)
    expect(browserFailures).toEqual([])
  } finally {
    await context.close()
  }
})

deterministicHarnessTest("contextual memory keeps its original occurrence time and permanent sequence link", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "contextual memory")
  const canvas = await openWorldloom(page)
  const memoryEvents = JSON.parse(
    (await canvas.getAttribute("data-memory-events")) ?? "[]",
  )
  const contextualMemory = memoryEvents.find(event => event.source === "visitor")
  expect(contextualMemory).toBeDefined()

  const memoryFormation = page.locator(`#formation-${contextualMemory.sequence}`)
  await memoryFormation.focus()
  await page.keyboard.press("Enter")

  const permanentPath = `/chapters/${contextualMemory.occurred_at.slice(0, 10)}/${contextualMemory.sequence}`
  await expect(page).toHaveURL(new RegExp(`${permanentPath}$`))
  await expect(page.locator("#signal-detail .detail-meta")).toHaveText(
    `${contextualMemory.source} · ${contextualMemory.occurred_at}`,
  )
  await expect(page.locator("#share-link")).toHaveValue(permanentPath)
  expect(browserFailures).toEqual([])
})

deterministicHarnessTest("a late commit advances the watermark without moving the event-time axis backward", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "late commit")
  const canvas = await openWorldloom(page)
  const beforeCommit = await liveSceneDiagnostics(canvas)

  const response = await page.request.post("/__e2e__/events/late")
  expect(response.ok()).toBe(true)
  const committedEvent = await response.json()
  await expect
    .poll(async () => Number(await canvas.getAttribute("data-commit-watermark")))
    .toBe(committedEvent.sequence)

  const afterCommit = await liveSceneDiagnostics(canvas)
  expect(afterCommit.commitWatermark).toBeGreaterThan(beforeCommit.commitWatermark)
  expect(Date.parse(afterCommit.windowEnd)).toBeGreaterThanOrEqual(
    Date.parse(beforeCommit.windowEnd),
  )
  expect(Date.parse(afterCommit.scene.axis.start)).toBeGreaterThanOrEqual(
    Date.parse(beforeCommit.scene.axis.start),
  )
  expect(afterCommit.scene.axis).toEqual(beforeCommit.scene.axis)
  expect(afterCommit.scene.paintCommands).toEqual(
    beforeCommit.scene.paintCommands,
  )
  expect(browserFailures).toEqual([])
})

deterministicHarnessTest("the frozen live axis ignores browser time after deterministic activity stops", async ({
  page,
}) => {
  await page.clock.install({time: new Date("2040-01-01T00:00:00Z")})
  const browserFailures = monitorPage(page, "activity outage")
  const canvas = await openWorldloom(page)
  const beforeActivityWatermark = Number(
    await canvas.getAttribute("data-commit-watermark"),
  )
  await page.getByRole("button", {name: "Illuminate", exact: true}).click()
  await expect
    .poll(async () => Number(await canvas.getAttribute("data-commit-watermark")))
    .toBeGreaterThan(beforeActivityWatermark)

  const stoppedActivity = await liveSceneDiagnostics(canvas)
  const originalViewport = page.viewportSize()

  await page.clock.setFixedTime(new Date("2050-01-01T00:00:00Z"))
  await page.setViewportSize({
    width: originalViewport.width - 1,
    height: originalViewport.height - 1,
  })
  await expect
    .poll(async () => (await readLiveSceneDiagnostics(canvas)).scene.viewport)
    .not.toEqual(stoppedActivity.scene.viewport)
  await page.setViewportSize(originalViewport)
  await expect
    .poll(async () => readLiveSceneDiagnostics(canvas))
    .toEqual(stoppedActivity)

  expect(browserFailures).toEqual([])
})

test("the opening composition prioritizes unobstructed artwork", async ({page}) => {
  await page.goto("/")
  const introduction = page.locator("#worldloom-introduction")
  await expect(introduction).toBeVisible()
  const introductionBounds = await introduction.boundingBox()
  expect(introductionBounds).not.toBeNull()

  const canvas = await waitForCanvas(page)
  await expect(page.locator("#signal-detail")).toHaveCount(0)
  await expect(page.locator("#gesture-dock")).toContainText("Touch the loom")

  const headerStyle = await page.locator(".worldloom-header").evaluate(element => {
    const style = getComputedStyle(element)
    return {position: style.position, border: style.borderBottomWidth}
  })
  expect(headerStyle.position).toBe("absolute")
  expect(headerStyle.border).toBe("0px")

  const canvasBounds = await canvas.boundingBox()
  const dockBounds = await page.locator("#gesture-dock").boundingBox()
  expect(canvasBounds).not.toBeNull()
  expect(dockBounds).not.toBeNull()
  expect(introductionBounds.y + introductionBounds.height).toBeLessThanOrEqual(
    dockBounds.y,
  )
  expect(dockBounds.width).toBeLessThanOrEqual(canvasBounds.width * 0.55)
  expect(dockBounds.height).toBeLessThanOrEqual(canvasBounds.height * 0.25)
  expect(dockBounds.y).toBeGreaterThanOrEqual(
    canvasBounds.y + canvasBounds.height * 0.65,
  )
  expect(dockBounds.y + dockBounds.height).toBeLessThanOrEqual(
    canvasBounds.y + canvasBounds.height,
  )
})

test("Lacquered Gallery reaches the rendered interface and interaction states", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "Lacquered Gallery")
  await openWorldloom(page)

  const palette = await page.evaluate(() => {
    const root = getComputedStyle(document.documentElement)
    const tokens = [
      "lacquer-deep",
      "lacquer",
      "wine",
      "wine-raised",
      "bone",
      "parchment",
      "saffron",
      "jade",
      "copper",
      "health-live",
      "health-disconnected",
    ]

    return Object.fromEntries(
      tokens.map(token => [
        token,
        root.getPropertyValue(`--loom-${token}`).trim().toLowerCase(),
      ]),
    )
  })
  expect(palette).toEqual({
    "lacquer-deep": "#120708",
    lacquer: "#241013",
    wine: "#35171a",
    "wine-raised": "#4b2020",
    bone: "#f6e2c5",
    parchment: "#cbb89f",
    saffron: "#e3a53a",
    jade: "#4db69a",
    copper: "#e07245",
    "health-live": "#86d29d",
    "health-disconnected": "#f08268",
  })

  const illuminate = page.getByRole("button", {
    name: "Illuminate",
    exact: true,
  })
  await illuminate.hover()
  const textContrasts = await compositedContrastContract(
    page,
    '.gesture-button[data-gesture="illuminate"]',
    [
      {label: "Illuminate title", selector: ".gesture-copy strong"},
      {label: "Illuminate description", selector: ".gesture-copy small"},
    ],
  )
  expect(textContrasts).toHaveLength(2)
  for (const textContrast of textContrasts) {
    expect(textContrast.text, textContrast.label).not.toBe("")
    expect(
      textContrast.contrastRatio,
      `${textContrast.label}: ${textContrast.text}`,
    ).toBeGreaterThanOrEqual(4.5)
  }

  await illuminate.focus()
  await expect(illuminate).toBeFocused()
  await expect(illuminate).toHaveCSS("outline-color", "rgb(227, 165, 58)")

  await page.evaluate(() => {
    window.dispatchEvent(new CustomEvent("phx:page-loading-start"))
  })
  const topbarCanvas = page.locator("body > canvas")
  await expect(topbarCanvas).toBeVisible({timeout: 2_000})
  expect(browserFailures).toEqual([])
  const topbarHasPaint = await topbarCanvas.evaluate(canvas => {
    const context = canvas.getContext("2d")
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data
    return pixels.some((_channel, index) => index % 4 === 3 && pixels[index] > 0)
  })
  expect(topbarHasPaint).toBe(true)
  await page.evaluate(() => {
    window.dispatchEvent(new CustomEvent("phx:page-loading-stop"))
  })

  expect(browserFailures).toEqual([])
})

test("quiet labels retain localized contrast over weather", async ({browser}) => {
  const baseURL = process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002"
  const contrastContracts = [
    {
      container: "#worldloom-introduction",
      minimumTextCount: 3,
      text: [
        "#worldloom-introduction > .eyebrow",
        "#worldloom-introduction > p:last-of-type",
        "#worldloom-introduction > span",
      ],
    },
    {
      container: "#signal-legend",
      minimumTextCount: 4,
      text: [
        "#signal-legend .legend-item",
        "#signal-legend .legend-item small",
      ],
    },
    {
      container: "#timeline > span:first-child",
      minimumTextCount: 1,
      text: ["#timeline > span:first-child"],
    },
    {
      container: "#timeline > span:last-child",
      minimumTextCount: 1,
      text: ["#timeline > span:last-child"],
    },
  ]
  const viewports = [
    {name: "desktop", size: {width: 1440, height: 900}},
    {name: "mobile", size: {width: 390, height: 844}},
  ]

  for (const viewport of viewports) {
    const context = await browser.newContext({
      baseURL,
      viewport: viewport.size,
      hasTouch: viewport.name === "mobile",
      isMobile: viewport.name === "mobile",
    })
    const page = await context.newPage()

    try {
      await page.goto("/")
      const activeContracts =
        viewport.name === "mobile" ? contrastContracts.slice(0, 1) : contrastContracts

      for (const selectors of activeContracts) {
        const contract = await localContrastContract(
          page,
          selectors.container,
          selectors.text,
        )
        const contractName = `${viewport.name} ${selectors.container}`

        expect.soft(contract.backgroundImage, contractName).toBe("none")
        expect.soft(contract.backingColor.rgb, contractName).toEqual([18, 7, 8])
        expect.soft(contract.backingColor.alpha, contractName).toBeGreaterThanOrEqual(0.72)
        expect.soft(contract.position, contractName).toBe("absolute")
        expect.soft(contract.pointerEvents, contractName).toBe("none")
        expect.soft(contract.coverageMargin, contractName).toBeGreaterThanOrEqual(0)
        expect(contract.protectedText.length, contractName).toBeGreaterThanOrEqual(
          selectors.minimumTextCount,
        )

        for (const protectedText of contract.protectedText) {
          expect.soft(
            protectedText.withinContainer,
            `${contractName} ${protectedText.text}`,
          ).toBe(true)
          expect.soft(
            protectedText.contrastRatio,
            `${contractName} ${protectedText.text}`,
          ).toBeGreaterThanOrEqual(4.5)
        }
      }
    } finally {
      await context.close()
    }
  }
})

test("the curatorial source link has an accessible target", async ({page}) => {
  await openWorldloom(page)
  await page.getByRole("link", {name: "About", exact: true}).click()

  const sourceLink = page.getByRole("link", {
    name: "Read the public source",
    exact: true,
  })
  await expect(sourceLink).toBeVisible()
  const sourceLinkBounds = await sourceLink.boundingBox()
  expect(sourceLinkBounds).not.toBeNull()
  expect(sourceLinkBounds.height).toBeGreaterThanOrEqual(44)
})

test("a keyboard-only visitor positions and directly weaves a gesture", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "keyboard")
  const canvas = await openWorldloom(page)
  const startingSequence = renderedSequence(canvas)

  const lane = page.getByRole("slider", {name: "Gesture vertical lane"})
  await lane.focus()
  await page.keyboard.press("ArrowUp")
  await expect(lane).toHaveValue("0.55")

  const knotButton = page.getByRole("button", {name: "Knot", exact: true})
  await knotButton.focus()
  await page.keyboard.press("Enter")

  await expect(page.locator("#gesture-status")).toContainText(
    "Gesture joined the living edge",
  )
  await expect
    .poll(async () => renderedSequence(canvas))
    .toBeGreaterThan(await startingSequence)
  expect(browserFailures).toEqual([])
})

test("pointer visitors place a seed on the live membrane before weaving", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "pointer placement")
  await page.emulateMedia({reducedMotion: "reduce"})
  await page.goto("/")
  const introduction = page.locator("#worldloom-introduction")
  await expect(introduction).toBeVisible()

  const canvas = await waitForCanvas(page)
  const bounds = await canvas.boundingBox()
  expect(bounds).not.toBeNull()
  await expect(introduction).toBeVisible()

  await canvas.dispatchEvent("pointerdown", {
    pointerId: 7,
    pointerType: "mouse",
    clientX: bounds.x + 100,
    clientY: bounds.y + 200,
  })
  await canvas.dispatchEvent("pointerup", {
    pointerId: 7,
    pointerType: "mouse",
    clientX: bounds.x + 100,
    clientY: bounds.y + 200,
  })
  await expect(introduction).toBeHidden()

  await canvas.click({
    position: {x: bounds.width - 12, y: bounds.height * 0.25},
  })
  await expect(
    page.getByRole("slider", {name: "Gesture vertical lane"}),
  ).toHaveValue("0.2")

  const startingSequence = await renderedSequence(canvas)
  await page.getByRole("button", {name: "Tug", exact: true}).click()
  await expect
    .poll(async () => renderedSequence(canvas))
    .toBeGreaterThan(startingSequence)
  const committedSequence = await renderedSequence(canvas)
  await expect(page.locator(`#formation-${committedSequence}`)).toContainText(
    /tugged the living edge/i,
  )
  await expect(canvas).toHaveAttribute("data-ready", "true")
  expect(browserFailures).toEqual([])
})

test("contextual detail supports keyboard, Escape, and outside dismissal", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "detail dismissal")
  const canvas = await openWorldloom(page)

  await canvas.focus()
  await page.keyboard.press("ArrowRight")
  await page.keyboard.press("Enter")
  await expect(page.locator("#signal-detail")).toBeVisible()

  await page.keyboard.press("Escape")
  await expect(page.locator("#signal-detail")).toHaveCount(0)

  await canvas.focus()
  await page.keyboard.press("ArrowRight")
  await page.keyboard.press("Enter")
  await expect(page.locator("#signal-detail")).toBeVisible()
  await page.locator("#utc-chapter").click()
  await expect(page.locator("#signal-detail")).toHaveCount(0)
  expect(browserFailures).toEqual([])
})

test("a second formation remains selected after LiveView navigates from the first", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "selection reconciliation")
  const canvas = await openWorldloom(page)
  const formations = page.locator("#accessible-formations button")
  expect(await formations.count()).toBeGreaterThanOrEqual(2)

  const firstFormation = formations.nth(0)
  const firstSummary = (await firstFormation.textContent()).trim()
  const firstSequence = Number((await firstFormation.getAttribute("id")).split("-").at(-1))
  await firstFormation.focus()
  await page.keyboard.press("Enter")
  await expect(page).toHaveURL(new RegExp(`/chapters/\\d{4}-\\d{2}-\\d{2}/${firstSequence}$`))
  await expect(page.locator("#signal-detail .detail-summary")).toHaveText(firstSummary)

  const secondFormation = formations.nth(1)
  const secondSummary = (await secondFormation.textContent()).trim()
  const secondSequence = Number((await secondFormation.getAttribute("id")).split("-").at(-1))
  expect(secondSequence).not.toBe(firstSequence)
  await secondFormation.focus()
  await page.keyboard.press("Enter")

  const secondPath = new RegExp(`/chapters/\\d{4}-\\d{2}-\\d{2}/${secondSequence}$`)
  await expect(page).toHaveURL(secondPath)
  await expect(page.locator("#signal-detail .detail-summary")).toHaveText(secondSummary)
  await expect(page.locator("#share-link")).toHaveValue(new RegExp(`/${secondSequence}$`))
  await expect(canvas).toHaveAttribute("data-ready", "true")
  expect(browserFailures).toEqual([])
})

test("Tug, Knot, and Illuminate commit distinct accessible formations", async ({
  browser,
}) => {
  const expectations = [
    ["Tug", /tugged the living edge/i],
    ["Knot", /tied a knot/i],
    ["Illuminate", /illuminated a thread/i],
  ]

  for (const [label, summary] of expectations) {
    const context = await browser.newContext({
      baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
    })
    const gesturePage = await context.newPage()
    const browserFailures = monitorPage(gesturePage, label)

    try {
      const canvas = await openWorldloom(gesturePage)
      const startingSequence = await renderedSequence(canvas)

      await gesturePage.getByRole("button", {name: label, exact: true}).click()
      await expect
        .poll(async () => renderedSequence(canvas))
        .toBeGreaterThan(startingSequence)
      const committedSequence = await renderedSequence(canvas)
      await expect(
        gesturePage.locator(`#formation-${committedSequence}`),
      ).toContainText(summary)
      await expect(canvas).toHaveAttribute("data-ready", "true")
      expect(browserFailures).toEqual([])
    } finally {
      await context.close()
    }
  }
})

test("formation detail and a shared permalink survive a full round trip", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "permalink")
  await page.context().grantPermissions(["clipboard-read", "clipboard-write"])
  const canvas = await openWorldloom(page)

  await canvas.focus()
  await page.keyboard.press("ArrowRight")
  await page.keyboard.press("Enter")

  await expect(page).toHaveURL(/\/chapters\/\d{4}-\d{2}-\d{2}\/\d+$/)
  const detail = page.locator("#signal-detail .detail-summary")
  await expect(detail).toBeVisible()
  const selectedPath = new URL(page.url()).pathname
  await expect(page.locator("#share-link")).toHaveValue(selectedPath)

  const pathBeforeShare = new URL(page.url()).pathname
  const summaryBeforeShare = (await detail.textContent()).trim()
  await page.getByRole("button", {name: "Share", exact: true}).click()
  await expect(page.locator("#share-status")).toHaveText("Link copied.")
  expect(new URL(page.url()).pathname).toBe(pathBeforeShare)
  await expect(detail).toHaveText(summaryBeforeShare)
  const sharedLink = await page.evaluate(() => navigator.clipboard.readText())
  const sharedURL = new URL(sharedLink)
  expect(sharedURL.pathname).toBe(selectedPath)

  const currentOrigin = new URL(page.url()).origin
  const roundTripURL =
    sharedURL.origin === currentOrigin
      ? sharedURL.toString()
      : new URL(sharedURL.pathname, currentOrigin).toString()
  await page.goto(roundTripURL)
  await waitForCanvas(page)
  await expect(page.locator("#signal-detail .detail-summary")).toHaveText(
    summaryBeforeShare,
  )
  await expect(page.locator("#gesture-dock")).toHaveAttribute(
    "aria-disabled",
    "true",
  )
  expect(browserFailures).toEqual([])
})

test("clipboard fallback is selectable and clears when its permalink becomes stale", async ({
  browser,
}) => {
  const context = await browser.newContext({
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
  })
  const page = await context.newPage()
  const browserFailures = monitorPage(page, "clipboard fallback")
  await page.addInitScript(() => {
    Object.defineProperty(navigator, "clipboard", {
      value: undefined,
      configurable: true,
    })
  })

  try {
    const canvas = await openWorldloom(page)
    await canvas.focus()
    await page.keyboard.press("ArrowRight")
    await page.keyboard.press("Enter")
    await expect(page.locator("#signal-detail")).toBeVisible()

    await page.getByRole("button", {name: "Share", exact: true}).click()
    const fallbackInput = page.locator("#share-fallback")
    await expect(fallbackInput).toBeFocused()
    await expect(page.locator("#share-status")).toHaveText(
      "Select and copy this permanent link.",
    )
    const fallbackSelection = await fallbackInput.evaluate(input => ({
      start: input.selectionStart,
      end: input.selectionEnd,
      length: input.value.length,
    }))
    expect(fallbackSelection).toEqual({
      start: 0,
      end: fallbackSelection.length,
      length: fallbackSelection.length,
    })

    const currentSequence = Number(new URL(page.url()).pathname.split("/").at(-1))
    const formations = page.locator("#accessible-formations button")
    const formationCount = await formations.count()
    let replacementFormation = null
    let replacementSequence = null
    for (let index = 0; index < formationCount; index += 1) {
      const candidate = formations.nth(index)
      const candidateSequence = Number(
        (await candidate.getAttribute("id")).split("-").at(-1),
      )
      if (candidateSequence !== currentSequence) {
        replacementFormation = candidate
        replacementSequence = candidateSequence
        break
      }
    }
    expect(replacementFormation).not.toBeNull()

    await replacementFormation.focus()
    await page.keyboard.press("Enter")
    await expect(page).toHaveURL(
      new RegExp(`/chapters/\\d{4}-\\d{2}-\\d{2}/${replacementSequence}$`),
    )
    await expect(fallbackInput).toBeHidden()
    await expect(fallbackInput).toHaveValue("")
    await expect(page.locator("#share-status")).toHaveText("")
    expect(browserFailures).toEqual([])
  } finally {
    await context.close()
  }
})

test("the archive opens a stable read-only historical chapter", async ({
  page,
}) => {
  const browserFailures = monitorPage(page, "archive")
  await openWorldloom(page)

  await page.getByRole("link", {name: "Archive", exact: true}).click()
  await expect(page).toHaveURL(/\/chapters$/)
  await expect(page.locator("#archive-panel")).toHaveAttribute(
    "data-active",
    "",
  )

  const firstChapter = page.locator("#archive-rows a").first()
  await expect(firstChapter).toBeVisible()
  await firstChapter.click()

  await expect(page).toHaveURL(/\/chapters\/\d{4}-\d{2}-\d{2}\/\d+$/)
  await expect(page.locator("#gesture-dock")).toHaveAttribute(
    "aria-disabled",
    "true",
  )
  for (const name of ["Tug", "Knot", "Illuminate"]) {
    await expect(page.getByRole("button", {name, exact: true})).toBeDisabled()
  }
  await expect(page.getByRole("link", {name: "Return live"})).toBeVisible()
  expect(browserFailures).toEqual([])
})

test("reduced-motion visitors get a static, fully operable loom", async ({
  browser,
}) => {
  const context = await browser.newContext({
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
    reducedMotion: "reduce",
  })
  const page = await context.newPage()
  const browserFailures = monitorPage(page, "reduced-motion")

  try {
    const canvas = await openWorldloom(page)
    await expect(canvas).toHaveAttribute("data-motion", "reduced")
    await canvas.dispatchEvent("wheel", {deltaY: -320})
    await expect(page.getByRole("link", {name: "Return live"})).toBeVisible()
    await page.getByRole("link", {name: "Return live"}).click()
    await expect(page.getByRole("link", {name: "Return live"})).toBeHidden()
    await expect(canvas).toHaveAttribute("data-ready", "true")

    const startingSequence = await renderedSequence(canvas)
    await page
      .getByRole("button", {name: "Illuminate", exact: true})
      .click()
    await expect
      .poll(async () => renderedSequence(canvas))
      .toBeGreaterThan(startingSequence)
    await expect(page.locator("#gesture-status")).toContainText(
      "Gesture joined the living edge",
    )
    expect(browserFailures).toEqual([])
  } finally {
    await context.close()
  }
})

test("touch visitors can inspect formations without clipped mobile controls", async ({
  browser,
}) => {
  const context = await browser.newContext({
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
    viewport: {width: 390, height: 844},
    hasTouch: true,
    isMobile: true,
  })
  const page = await context.newPage()
  const browserFailures = monitorPage(page, "mobile")

  try {
    const canvas = await openWorldloom(page)
    expect(
      await page.evaluate(
        () => document.documentElement.scrollWidth <= innerWidth,
      ),
    ).toBe(true)

    const gestureButtons = page.locator(".gesture-button")
    await expect(gestureButtons).toHaveCount(3)
    for (const gestureButton of await gestureButtons.all()) {
      const bounds = await gestureButton.boundingBox()
      expect(bounds?.height).toBeGreaterThanOrEqual(44)
    }

    await expect(
      page.getByRole("slider", {name: "Gesture vertical lane"}),
    ).toBeVisible()

    const startingSequence = await renderedSequence(canvas)
    await page.getByRole("button", {name: "Tug", exact: true}).tap()
    await expect
      .poll(async () => renderedSequence(canvas))
      .toBeGreaterThan(startingSequence)

    await tapVisibleFormation(
      page,
      canvas,
      page.locator("#gesture-dock"),
      page.locator("#mobile-detail-sheet"),
    )
    await expect(page).toHaveURL(/\/chapters\/\d{4}-\d{2}-\d{2}\/\d+$/)

    const detailSheet = page.locator("#mobile-detail-sheet")
    await expect(detailSheet.locator(".detail-summary")).toBeVisible()
    const detailBounds = await detailSheet.boundingBox()
    const dockBounds = await page.locator("#gesture-dock").boundingBox()
    expect(detailBounds.y + detailBounds.height).toBeLessThanOrEqual(
      dockBounds.y,
    )
    expect(browserFailures).toEqual([])
  } finally {
    await context.close()
  }
})

test("mobile gesture copy remains readable", async ({browser}) => {
  const context = await browser.newContext({
    baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
    viewport: {width: 390, height: 844},
    hasTouch: true,
    isMobile: true,
  })
  const page = await context.newPage()

  try {
    await openWorldloom(page)
    const descriptionSizes = await page.locator(".gesture-copy small").evaluateAll(
      elements => elements.map(element => parseFloat(getComputedStyle(element).fontSize)),
    )
    const statusSize = await page.locator("#gesture-status").evaluate(element =>
      parseFloat(getComputedStyle(element).fontSize),
    )
    const dockBounds = await page.locator("#gesture-dock").boundingBox()

    expect(descriptionSizes).toHaveLength(3)
    expect.soft(Math.min(...descriptionSizes)).toBeGreaterThanOrEqual(11)
    expect.soft(statusSize).toBeGreaterThanOrEqual(11)
    expect(dockBounds).not.toBeNull()
    expect(dockBounds.x).toBeGreaterThanOrEqual(0)
    expect(dockBounds.x + dockBounds.width).toBeLessThanOrEqual(390)
    expect(dockBounds.y + dockBounds.height).toBeLessThanOrEqual(844)
  } finally {
    await context.close()
  }
})

test.describe.serial("balanced-world visual release", () => {
  test.skip(
    !deterministicHarnessAvailable,
    "balanced-world visual release requires the deterministic E2E harness",
  )

  test("balanced desktop exposes every material and remains keyboard navigable", async ({
    page,
  }) => {
    const browserFailures = monitorPage(page, "balanced desktop")
    await installScene(page, "balanced", balanced)
    const canvas = await openWorldloom(page, {width: 1440, height: 1000})

    await expect(page.locator("#live-summary")).toContainText(
      "16 Wikimedia windows, 15 Bluesky activity windows, 15 RIPE route windows, " +
        "15 Solana slot windows, 21 drand rounds, 1 earthquake memory, and 3 visitor memories",
    )
    await expect(page.locator("#live-summary")).toContainText(
      "All enabled sources are live",
    )
    await expect(
      page.locator("#signal-legend [data-legend-layout='desktop']"),
    ).toBeVisible()
    await expect(
      page.locator("#signal-legend details[data-legend-layout='compact']"),
    ).toBeHidden()
    await expect(
      page.locator("#signal-legend [data-legend-layout='desktop'] .legend-item"),
    ).toHaveCount(8)
    expect(await backingAlpha(page, "#signal-legend")).toBe(1)

    const officialSources = [
      ["Wikimedia", "https://www.mediawiki.org/wiki/EventStreams"],
      ["Bluesky", "https://docs.bsky.app/blog/jetstream"],
      ["RIPE RIS Live", "https://ris-live.ripe.net/manual/"],
      ["Solana", "https://solana.com/docs/rpc/websocket/slotsubscribe"],
      ["drand Quicknet", "https://docs.drand.love/developer/API-v2/drand-http-api/"],
      ["USGS earthquakes", "https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php"],
      ["Open-Meteo weather", "https://open-meteo.com/en/docs"],
    ]
    for (const [name, href] of officialSources) {
      await expect(
        page.locator("#signal-legend [data-legend-layout='desktop']").getByRole("link", {
          name,
          exact: true,
        }),
      ).toHaveAttribute("href", href)
    }

    const scene = await liveSceneDiagnostics(canvas)
    assertSameTimeSourcesRemainDistinct(scene.scene.paintCommands)

    await expectStableScreenshot(page, "balanced-desktop.png")

    await canvas.focus()
    await page.keyboard.press("ArrowRight")
    await page.keyboard.press("Enter")
    await expect(page.locator("#signal-detail")).toBeVisible()
    await expect(page).toHaveURL(/\/chapters\/\d{4}-\d{2}-\d{2}\/\d+$/)

    expect(browserFailures).toEqual([])
  })

  test("balanced tablet offers the compact material disclosure", async ({page}) => {
    const browserFailures = monitorPage(page, "balanced tablet")
    await installScene(page, "balanced", balanced)
    await openWorldloom(page, {width: 900, height: 1100})

    const desktopLegend = page.locator(
      "#signal-legend [data-legend-layout='desktop']",
    )
    const compactLegend = page.locator(
      "#signal-legend details[data-legend-layout='compact']",
    )
    await expect(desktopLegend).toBeHidden()
    await expect(compactLegend).toBeVisible()
    await expect(compactLegend).not.toHaveAttribute("open", "")
    await compactLegend.locator("summary").click()
    await expect(compactLegend).toHaveAttribute("open", "")
    await expect(compactLegend.locator(".legend-item")).toHaveCount(8)

    await expectStableScreenshot(page, "balanced-tablet.png")
    expect(browserFailures).toEqual([])
  })

  test("balanced mobile keeps the canvas and touch path operable", async ({browser}) => {
    const context = await browser.newContext({
      baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
      viewport: {width: 390, height: 844},
      hasTouch: true,
      isMobile: true,
    })
    const page = await context.newPage()
    const browserFailures = monitorPage(page, "balanced mobile")

    try {
      await installScene(page, "balanced", balanced)
      const canvas = await openWorldloom(page)

      expect(
        await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
      ).toBe(true)
      await expectStableScreenshot(page, "balanced-mobile.png")

      const startingSequence = await renderedSequence(canvas)
      await page.getByRole("button", {name: "Tug", exact: true}).tap()
      await expect
        .poll(async () => renderedSequence(canvas))
        .toBeGreaterThan(startingSequence)
      await expect(page.locator("#gesture-status")).toContainText(
        "Gesture joined the living edge",
      )
      expect(browserFailures).toEqual([])
    } finally {
      await context.close()
    }
  })

  test("a Wikimedia surge preserves the other public materials", async ({page}) => {
    const browserFailures = monitorPage(page, "Wikimedia surge")
    await installScene(page, "wikimedia-surge", wikimediaSurge)
    const canvas = await openWorldloom(page, {width: 1440, height: 1000})
    const diagnostics = await liveSceneDiagnostics(canvas)
    const paintedSources = new Set(
      diagnostics.scene.paintCommands.map(command => command.source),
    )

    for (const source of ["wikimedia", "bluesky", "ripe_ris", "solana", "drand"]) {
      expect(paintedSources).toContain(source)
    }

    await expectStableScreenshot(page, "wikimedia-surge-desktop.png")
    expect(browserFailures).toEqual([])
  })

  test("a delayed source recovery changes health without hiding the weave", async ({page}) => {
    const browserFailures = monitorPage(page, "delayed recovery")
    await installScene(page, "balanced", balanced)
    await openWorldloom(page, {width: 1440, height: 1000})

    await expect(page.locator("#legend-ripe_ris")).toHaveAttribute(
      "data-health-state",
      "live",
    )
    await expect(page.locator("#live-summary")).toHaveAttribute("aria-live", "polite")

    await installScene(page, "delayed-recovery", delayedRecovery)

    await expect(page.locator("#legend-ripe_ris")).toHaveAttribute(
      "data-health-state",
      "quiet",
    )
    await expect(page.locator("#live-summary")).toContainText(
      "RIPE RIS Live is quiet",
    )
    await expectStableScreenshot(page, "delayed-recovery-desktop.png")
    expect(browserFailures).toEqual([])
  })

  test("a total provider outage remains legible on mobile", async ({page}) => {
    const browserFailures = monitorPage(page, "total outage")
    await installScene(page, "total-outage", totalOutage)
    await openWorldloom(page, {width: 390, height: 844})

    await page.locator("#signal-legend-toggle").click()
    const providerStates = await page
      .locator("#signal-legend [data-legend-layout='compact'] .legend-item:not([data-family='visitor'])")
      .evaluateAll(elements => elements.map(element => element.dataset.healthState))
    expect(new Set(providerStates)).toEqual(new Set(["disconnected"]))
    await expect(page.locator("#live-summary")).toContainText("is disconnected")
    expect(
      await elementsOverlap(
        page,
        "#signal-legend details[data-legend-layout='compact']",
        "#gesture-dock",
      ),
    ).toBe(false)

    await expectStableScreenshot(page, "total-outage-mobile.png")
    expect(browserFailures).toEqual([])
  })

  test("mobile memory selection reveals source-owned detail", async ({page}) => {
    const browserFailures = monitorPage(page, "memory selection")
    await installScene(page, "balanced", balanced)
    await openWorldloom(page, {width: 390, height: 844})
    const selectedMemory = balanced.memory_events.find(
      event => event.source === "visitor" && event.kind === "illuminate",
    )
    expect(selectedMemory).toBeDefined()

    const formation = page.locator(`#formation-${selectedMemory.sequence}`)
    await formation.focus()
    await page.keyboard.press("Enter")
    await expect(page.locator("#mobile-detail-sheet .detail-summary")).toHaveText(
      selectedMemory.summary,
    )
    const selectedMetadata = await page
      .locator("#mobile-detail-sheet .detail-meta")
      .textContent()
    const [selectedSource, selectedOccurredAt] = selectedMetadata
      .trim()
      .split(" · ")
    expect(selectedSource).toBe(selectedMemory.source)
    expect(Date.parse(selectedOccurredAt)).toBe(Date.parse(selectedMemory.occurred_at))
    expect(
      await elementsOverlap(page, "#signal-legend", "#return-live"),
    ).toBe(false)

    await expectStableScreenshot(page, "memory-selection-mobile.png")
    expect(browserFailures).toEqual([])
  })

  test("reduced motion paints the same settled balanced roles", async ({browser}) => {
    const context = await browser.newContext({
      baseURL: process.env.WORLDLOOM_BASE_URL ?? "http://localhost:4002",
      viewport: {width: 1440, height: 1000},
      reducedMotion: "reduce",
    })
    const page = await context.newPage()
    const browserFailures = monitorPage(page, "balanced reduced motion")

    try {
      await installScene(page, "balanced", balanced)
      const canvas = await openWorldloom(page)
      await expect(canvas).toHaveAttribute("data-motion", "reduced")
      const diagnostics = await liveSceneDiagnostics(canvas)
      const paintedSources = new Set(
        diagnostics.scene.paintCommands.map(command => command.source),
      )
      for (const source of [
        "wikimedia",
        "bluesky",
        "ripe_ris",
        "solana",
        "drand",
      ]) {
        expect(
          paintedSources.has(source),
        ).toBe(true)
      }

      await expectStableScreenshot(page, "balanced-reduced-motion.png")
      expect(browserFailures).toEqual([])
    } finally {
      await context.close()
    }
  })

  test("expired memories are absent from the deterministic acceptance scene", async ({
    page,
  }) => {
    const browserFailures = monitorPage(page, "memory expiry")
    await installScene(page, "memory-expiry", memoryExpiry)
    const canvas = await openWorldloom(page, {width: 1440, height: 1000})

    expect(JSON.parse(await canvas.getAttribute("data-memory-events"))).toEqual([])
    await expect(page.locator("#live-summary")).not.toContainText("memory")
    expect(browserFailures).toEqual([])
  })
})

const screenshotOptions = {
  animations: "disabled",
  caret: "hide",
  scale: "css",
}

async function expectStableScreenshot(page, name) {
  await page.evaluate(() => {
    const element = document.querySelector("#loom-canvas")
    const viewerCount = document.querySelector("#viewer-count")
    const view =
      globalThis.liveSocket?.getViewByEl?.(element) ?? globalThis.liveSocket?.main
    const hook = view?.getHook?.(element)
    const renderer = hook?.renderer

    if (!renderer || !viewerCount) throw new Error("Worldloom acceptance surface is unavailable")
    const countText = [...viewerCount.childNodes].find(
      node => node.nodeType === Node.TEXT_NODE && node.textContent.trim() !== "",
    )
    if (!countText) throw new Error("Worldloom viewer count is unavailable")

    countText.textContent = " 1 viewing"
    renderer.setViewerCount(1)
    if (renderer.frameHandle !== null) renderer.cancelFrame(renderer.frameHandle)
    renderer.frameHandle = null
    renderer.activeTransitions.clear()
    renderer.rebuild()
    renderer.step(6_000)
  })

  await expect(page).toHaveScreenshot(name, screenshotOptions)
}

async function installScene(page, sceneName, snapshot) {
  const response = await page.request.post(`/__e2e__/scenes/${sceneName}`, {
    data: {snapshot},
  })
  const responseBody = await response.text()

  expect(response.ok(), `${sceneName} scene response: ${responseBody}`).toBe(true)
}

async function backingAlpha(page, selector) {
  return page.locator(selector).evaluate(element => {
    const channels = getComputedStyle(element, "::before").backgroundColor.match(/[\d.]+/g)
    return Number(channels?.[3] ?? 1)
  })
}

async function elementsOverlap(page, firstSelector, secondSelector) {
  return page.evaluate(
    ({firstSelector, secondSelector}) => {
      const first = document.querySelector(firstSelector)?.getBoundingClientRect()
      const second = document.querySelector(secondSelector)?.getBoundingClientRect()

      if (!first || !second) throw new Error("overlap target is unavailable")

      return !(
        first.right <= second.left ||
        first.left >= second.right ||
        first.bottom <= second.top ||
        first.top >= second.bottom
      )
    },
    {firstSelector, secondSelector},
  )
}

function assertSameTimeSourcesRemainDistinct(paintCommands) {
  const structuralRoles = new Set([
    "backbone",
    "conversation-fan",
    "route-fork",
    "slot-braid",
    "public-pulse",
  ])
  const structuralCommands = paintCommands.filter(command =>
    structuralRoles.has(command.role),
  )
  const sameColumn = structuralCommands.reduce((columns, command) => {
    const commands = columns.get(command.x) ?? []
    commands.push(command)
    columns.set(command.x, commands)
    return columns
  }, new Map())
  const distinctColumn = [...sameColumn.values()].find(commands => {
    const roles = new Set(commands.map(command => command.role))
    const rows = new Set(commands.map(command => command.y))
    return roles.size > 1 && roles.size === rows.size
  })

  expect(distinctColumn).toBeDefined()
}

async function openWorldloom(page, viewport) {
  if (viewport) await page.setViewportSize(viewport)
  await page.goto("/")
  return waitForCanvas(page)
}

async function waitForCanvas(page) {
  const canvas = page.locator("#loom-canvas")
  await expect(canvas).toHaveAttribute("data-ready", "true")
  await expect.poll(async () => renderedSequence(canvas)).toBeGreaterThan(0)
  return canvas
}

async function renderedSequence(canvas) {
  return Number(await canvas.getAttribute("data-rendered-sequence"))
}

async function liveSceneDiagnostics(canvas) {
  await expect(canvas).toHaveAttribute("data-ready", "true")
  await expect(canvas).toHaveAttribute("data-scene-diagnostics", /"axis":/)

  return readLiveSceneDiagnostics(canvas)
}

async function readLiveSceneDiagnostics(canvas) {
  return {
    windowEnd: await canvas.getAttribute("data-window-end"),
    commitWatermark: Number(
      await canvas.getAttribute("data-commit-watermark"),
    ),
    scene: JSON.parse(await canvas.getAttribute("data-scene-diagnostics")),
  }
}

async function localContrastContract(page, containerSelector, textSelectors) {
  return page.evaluate(
    ({containerSelector, textSelectors}) => {
      const container = document.querySelector(containerSelector)
      const backing = getComputedStyle(container, "::before")
      const backingColor = parseColor(backing.backgroundColor)
      const blurRadius = Number(backing.filter.match(/blur\(([\d.]+)px\)/)?.[1] ?? 0)
      const insets = [backing.top, backing.right, backing.bottom, backing.left].map(
        inset => Number.parseFloat(inset),
      )
      const protectedElements = textSelectors.flatMap(selector =>
        [...document.querySelectorAll(selector)],
      ).filter(element =>
        element.getClientRects().length > 0 && getComputedStyle(element).visibility !== "hidden",
      )
      const containerBounds = container.getBoundingClientRect()
      const worstWeather = [141, 165, 110]
      const backedWeather = blend(
        backingColor.rgb,
        worstWeather,
        backingColor.alpha,
      )

      return {
        backgroundImage: backing.backgroundImage,
        backingColor,
        position: backing.position,
        pointerEvents: backing.pointerEvents,
        coverageMargin: Math.min(...insets.map(inset => -inset - blurRadius)),
        protectedText: protectedElements.map(element => {
          const textColor = parseColor(getComputedStyle(element).color)
          const effectiveText = blend(
            textColor.rgb,
            backedWeather,
            textColor.alpha,
          )
          const textBounds = element.getBoundingClientRect()

          return {
            text: element.textContent.trim(),
            contrastRatio: contrast(effectiveText, backedWeather),
            withinContainer:
              textBounds.top >= containerBounds.top &&
              textBounds.right <= containerBounds.right &&
              textBounds.bottom <= containerBounds.bottom &&
              textBounds.left >= containerBounds.left,
          }
        }),
      }

      function parseColor(color) {
        const channels = color.match(/[\d.]+/g).map(Number)
        return {rgb: channels.slice(0, 3), alpha: channels[3] ?? 1}
      }

      function blend(foreground, background, alpha) {
        return foreground.map((channel, index) =>
          channel * alpha + background[index] * (1 - alpha),
        )
      }

      function contrast(first, second) {
        const brighter = Math.max(luminance(first), luminance(second))
        const darker = Math.min(luminance(first), luminance(second))
        return (brighter + 0.05) / (darker + 0.05)
      }

      function luminance(color) {
        const [red, green, blue] = color.map(channel => {
          const normalized = channel / 255
          return normalized <= 0.04045
            ? normalized / 12.92
            : ((normalized + 0.055) / 1.055) ** 2.4
        })
        return red * 0.2126 + green * 0.7152 + blue * 0.0722
      }
    },
    {containerSelector, textSelectors},
  )
}

async function compositedContrastContract(page, targetSelector, textContracts) {
  return page.evaluate(({targetSelector, textContracts}) => {
    const target = document.querySelector(targetSelector)
    if (!target) throw new Error(`contrast target is unavailable: ${targetSelector}`)

    const gestureDock = target.closest("#gesture-dock")
    if (!gestureDock) {
      throw new Error(`contrast target has no #gesture-dock: ${targetSelector}`)
    }

    const rootStyle = getComputedStyle(document.documentElement)
    const targetStyle = getComputedStyle(target)
    const dockStyle = getComputedStyle(gestureDock)
    const worstFoundation = parseColor(
      rootStyle.getPropertyValue("--loom-wine-raised"),
    )
    if (worstFoundation.alpha !== 1) {
      throw new Error("--loom-wine-raised must be an opaque contrast foundation")
    }
    const dockSurface = composite(
      parseColor(dockStyle.backgroundColor),
      worstFoundation,
    )
    const targetSurface = composite(
      parseColor(targetStyle.backgroundColor),
      dockSurface,
    )

    return textContracts.map(({label, selector}) => {
      const textElement = target.querySelector(selector)
      if (!textElement) {
        throw new Error(`contrast text is unavailable: ${label} (${selector})`)
      }

      const textStyle = getComputedStyle(textElement)
      const text = textElement.textContent.trim()
      const hasTextNode = [...textElement.childNodes].some(node =>
        node.nodeType === Node.TEXT_NODE && node.textContent.trim() !== "",
      )
      const rendered =
        textElement.getClientRects().length > 0 &&
        textStyle.display !== "none" &&
        textStyle.visibility !== "hidden"
      if (!hasTextNode || text === "") {
        throw new Error(`contrast text is empty: ${label} (${selector})`)
      }
      if (!rendered) {
        throw new Error(`contrast text is not rendered: ${label} (${selector})`)
      }

      const renderedText = composite(
        parseColor(textStyle.color),
        targetSurface,
      )

      return {
        label,
        selector,
        text,
        contrastRatio: contrast(renderedText.rgb, targetSurface.rgb),
      }
    })

    function parseColor(color) {
      const normalized = color.trim().toLowerCase()
      const hex = normalized.match(/^#([0-9a-f]{6})([0-9a-f]{2})?$/)
      if (hex) {
        return {
          rgb: [0, 2, 4].map(offset =>
            Number.parseInt(hex[1].slice(offset, offset + 2), 16),
          ),
          alpha: hex[2] ? Number.parseInt(hex[2], 16) / 255 : 1,
        }
      }

      const functional = normalized.match(/^rgba?\((.+)\)$/)
      if (functional) {
        const channels = functional[1]
          .replace("/", " ")
          .split(/[\s,]+/)
          .filter(Boolean)
          .map(Number)
        if (
          (channels.length === 3 || channels.length === 4) &&
          channels.every(Number.isFinite)
        ) {
          return {rgb: channels.slice(0, 3), alpha: channels[3] ?? 1}
        }
      }

      throw new Error(`unsupported contrast color: ${color}`)
    }

    function composite(foreground, background) {
      const alpha =
        foreground.alpha + background.alpha * (1 - foreground.alpha)
      if (alpha === 0) throw new Error("cannot composite two transparent colors")

      return {
        rgb: foreground.rgb.map((channel, index) =>
          (channel * foreground.alpha +
            background.rgb[index] * background.alpha *
              (1 - foreground.alpha)) /
          alpha,
        ),
        alpha,
      }
    }

    function contrast(first, second) {
      const brighter = Math.max(luminance(first), luminance(second))
      const darker = Math.min(luminance(first), luminance(second))
      return (brighter + 0.05) / (darker + 0.05)
    }

    function luminance(color) {
      const [red, green, blue] = color.map(channel => {
        const normalized = channel / 255
        return normalized <= 0.04045
          ? normalized / 12.92
          : ((normalized + 0.055) / 1.055) ** 2.4
      })
      return red * 0.2126 + green * 0.7152 + blue * 0.0722
    }
  }, {targetSelector, textContracts})
}

async function tapVisibleFormation(page, canvas, gestureDock, detailSheet) {
  const instructions = JSON.parse(
    (await canvas.getAttribute("data-instructions")) ?? "[]",
  )
  const canvasBounds = await canvas.boundingBox()
  const dockBounds = await gestureDock.boundingBox()
  const detailBounds =
    (await detailSheet.count()) > 0 ? await detailSheet.boundingBox() : null
  expect(canvasBounds).not.toBeNull()
  expect(dockBounds).not.toBeNull()
  const maximumSequence = await renderedSequence(canvas)
  const formations = [...instructions].reverse().filter((instruction) => {
    const x =
      canvasBounds.width - 40 - (maximumSequence - instruction.sequence) * 28
    const y = 40 + Number(instruction.lane) * (canvasBounds.height - 80)
    const behindDetail =
      detailBounds !== null &&
      x >= detailBounds.x - canvasBounds.x &&
      x <= detailBounds.x - canvasBounds.x + detailBounds.width &&
      y >= detailBounds.y - canvasBounds.y &&
      y <= detailBounds.y - canvasBounds.y + detailBounds.height
    return (
      x >= 32 &&
      x <= canvasBounds.width - 32 &&
      y >= 76 &&
      y <= dockBounds.y - 24 &&
      !behindDetail
    )
  })

  expect(formations.length).toBeGreaterThan(0)
  for (const formation of formations.slice(0, 8)) {
    const x =
      canvasBounds.width - 40 - (maximumSequence - formation.sequence) * 28
    const y = 40 + Number(formation.lane) * (canvasBounds.height - 80)

    try {
      await canvas.tap({position: {x, y}})
      await page.waitForURL(/\/chapters\/\d{4}-\d{2}-\d{2}\/\d+$/, {
        timeout: 750,
      })
      return
    } catch (_notSelected) {
      // Another painted formation may overlap this hit region; try the next visible one.
    }
  }

  throw new Error("no unobstructed painted formation responded to touch")
}

function monitorPage(page, label, failures = []) {
  page.on("console", (message) => {
    if (message.type() === "error")
      failures.push(`${label} console: ${message.text()}`)
  })
  page.on("pageerror", (error) =>
    failures.push(`${label} page: ${error.message}`),
  )
  page.on("websocket", (socket) =>
    socket.on("socketerror", (error) =>
      failures.push(`${label} websocket: ${error}`),
    ),
  )
  page.on("requestfailed", (request) =>
    failures.push(
      `${label} request: ${request.method()} ${request.url()} ${request.failure()?.errorText}`,
    ),
  )
  page.on("response", (response) => {
    if (response.status() >= 400) {
      failures.push(`${label} response: ${response.status()} ${response.url()}`)
    }
  })
  return failures
}
