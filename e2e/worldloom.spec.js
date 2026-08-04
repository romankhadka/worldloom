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

async function tapVisibleFormation(page, canvas, gestureDock, detailSheet) {
  const instructions = JSON.parse(
    (await canvas.getAttribute("data-instructions")) ?? "[]",
  )
  const canvasBounds = await canvas.boundingBox()
  const dockBounds = await gestureDock.boundingBox()
  const detailBounds = await detailSheet.boundingBox()
  const maximumSequence = Math.max(
    ...instructions.map((instruction) => instruction.sequence),
  )
  const formations = [...instructions].reverse().filter((instruction) => {
    const x =
      canvasBounds.width - 40 - (maximumSequence - instruction.sequence) * 28
    const y = 40 + Number(instruction.lane) * (canvasBounds.height - 80)
    const behindDetail =
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
