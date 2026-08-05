import {expect, test} from "@playwright/test"

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
        expect.soft(contract.backingColor.rgb, contractName).toEqual([3, 8, 6])
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
  const selectedSummary = await detail.textContent()
  const selectedPath = new URL(page.url()).pathname
  await expect(page.locator("#share-link")).toHaveValue(selectedPath)

  await page.getByRole("button", {name: "Share", exact: true}).click()
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
    selectedSummary.trim(),
  )
  await expect(page.locator("#gesture-dock")).toHaveAttribute(
    "aria-disabled",
    "true",
  )
  expect(browserFailures).toEqual([])
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

async function openWorldloom(page) {
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
      )
      const containerBounds = container.getBoundingClientRect()
      const worstWeather = [139, 132, 82]
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
