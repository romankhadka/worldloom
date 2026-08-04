import {defineConfig} from "@playwright/test"

const externalBaseURL = process.env.WORLDLOOM_BASE_URL
const localBaseURL = "http://localhost:4002"

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 2 : 0,
  reporter: process.env.CI ? [["line"], ["html", {open: "never"}]] : "line",
  outputDir: "test-results",
  use: {
    baseURL: externalBaseURL ?? localBaseURL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: {browserName: "chromium"},
    },
  ],
  webServer: externalBaseURL
    ? undefined
    : {
        command:
          "env MIX_ENV=test WORLDLOOM_E2E=true WORLDLOOM_FEEDS_ENABLED=false mix ecto.reset && " +
          "env MIX_ENV=test WORLDLOOM_E2E=true WORLDLOOM_FEEDS_ENABLED=false mix worldloom.seed_demo && " +
          "env MIX_ENV=test WORLDLOOM_E2E=true WORLDLOOM_FEEDS_ENABLED=false mix assets.build && " +
          "env MIX_ENV=test WORLDLOOM_E2E=true WORLDLOOM_FEEDS_ENABLED=false mix phx.server",
        url: `${localBaseURL}/healthz`,
        reuseExistingServer: !process.env.CI,
        timeout: 120_000,
      },
})
