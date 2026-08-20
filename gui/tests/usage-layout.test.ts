import { expect, test } from "bun:test";
import { Window } from "happy-dom";
import { act, createElement } from "react";
import { clearClientResourceStoresForTests } from "../src/client-resource";
import { LanguageProvider } from "../src/i18n/provider";
import { DICTS, I18nContext, interpolate, type TFn } from "../src/i18n/shared";
import Usage from "../src/pages/Usage";

type UsageCacheSummary = {
  inputTokens: number;
  cachedInputTokens: number;
  cacheReadInputTokens?: number;
  cacheCreationInputTokens?: number;
};

let usageCacheTestCase = 0;

type UsageProviderFixture = {
  provider: string;
  requests?: number;
  measuredRequests?: number;
  totalTokens?: number;
  shareRatio?: number;
};

type UsageModelFixture = {
  provider: string;
  model: string;
  inputTokens?: unknown;
  cacheReadInputTokens?: unknown;
  outputTokensPerSecond?: unknown;
  outputTokensPerSecondEstimated?: boolean;
  totalTokens?: number;
  shareRatio?: number;
};

type ProviderQuotaFixture = {
  provider?: unknown;
  updatedAt?: unknown;
  quota?: unknown;
};

function usageFixture(providers: UsageProviderFixture[], models: UsageModelFixture[] = []) {
  return {
    range: "30d",
    surface: "all",
    since: null,
    generatedAt: Date.now(),
    summary: {
      requests: providers.length,
      measuredRequests: providers.length,
      reportedRequests: providers.length,
      unreportedRequests: 0,
      unsupportedRequests: 0,
      estimatedRequests: 0,
      inputTokens: 100,
      outputTokens: 10,
      cachedInputTokens: 0,
      reasoningOutputTokens: 0,
      totalTokens: 110,
      coverageRatio: 1,
    },
    days: [],
    providers: providers.map(provider => ({
      provider: provider.provider,
      requests: provider.requests ?? 1,
      measuredRequests: provider.measuredRequests ?? 1,
      reportedRequests: 1,
      estimatedRequests: 0,
      totalTokens: provider.totalTokens ?? 10,
      shareRatio: provider.shareRatio ?? 1,
    })),
    models: models.map(model => ({
      provider: model.provider,
      model: model.model,
      requests: 1,
      measuredRequests: 1,
      reportedRequests: 1,
      estimatedRequests: 0,
      totalTokens: model.totalTokens ?? 10,
      ...(model.inputTokens !== undefined ? { inputTokens: model.inputTokens } : {}),
      outputTokens: 1,
      ...(model.cacheReadInputTokens !== undefined ? { cacheReadInputTokens: model.cacheReadInputTokens } : {}),
      ...(model.outputTokensPerSecond !== undefined ? { outputTokensPerSecond: model.outputTokensPerSecond } : {}),
      ...(model.outputTokensPerSecondEstimated !== undefined ? { outputTokensPerSecondEstimated: model.outputTokensPerSecondEstimated } : {}),
      shareRatio: model.shareRatio ?? 1,
    })),
    historyTruncated: false,
    truncatedPrefixBytes: 0,
    entriesTruncated: false,
    entriesDropped: 0,
  };
}

async function withRenderedUsage({
  providers,
  quotas,
  models = [],
  quotaOk = true,
  assertRendered,
}: {
  providers: UsageProviderFixture[];
  quotas: ProviderQuotaFixture[];
  models?: UsageModelFixture[];
  quotaOk?: boolean;
  assertRendered: (container: HTMLElement) => void;
}) {
  const globalKeys = ["document", "window", "navigator", "localStorage", "ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const previous = Object.fromEntries(globalKeys.map(key => [key, Reflect.get(globalThis, key)]));
  const originalFetch = globalThis.fetch;
  const testWindow = new Window({ url: "http://localhost/" });
  const apiBase = `http://usage-layout-test-${++usageCacheTestCase}`;
  const windowResizeObserver = Reflect.get(testWindow, "ResizeObserver");
  const resizeObserver = typeof windowResizeObserver === "function"
    ? windowResizeObserver
    : class ResizeObserver {
        observe() {}
        unobserve() {}
        disconnect() {}
      };
  Object.defineProperties(globalThis, {
    document: { configurable: true, value: testWindow.document },
    window: { configurable: true, value: testWindow },
    navigator: { configurable: true, value: testWindow.navigator },
    localStorage: { configurable: true, value: testWindow.localStorage },
    ResizeObserver: { configurable: true, value: resizeObserver },
  });
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  clearClientResourceStoresForTests();
  let quotaSettled = false;
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    if (url.endsWith("/api/provider-quotas")) {
      quotaSettled = true;
      if (!quotaOk) return { ok: false, status: 503, statusText: "Unavailable", json: async () => ({}) };
      return { ok: true, json: async () => ({ generatedAt: Date.now(), reports: quotas }) };
    }
    if (url.includes("/api/usage?")) return { ok: true, json: async () => usageFixture(providers, models) };
    throw new Error(`Unexpected request: ${url}`);
  }) as typeof fetch;

  const container = document.createElement("div");
  document.body.append(container);
  const { createRoot } = await import("react-dom/client");
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(createElement(LanguageProvider, null, createElement(Usage, { apiBase })));
    });
    const deadline = Date.now() + 1_000;
    while (!container.querySelector("#usage-providers-title") || !quotaSettled) {
      if (Date.now() >= deadline) throw new Error("Usage providers table did not render");
      await act(async () => {
        await new Promise<void>(resolve => testWindow.setTimeout(resolve, 10));
      });
    }
    assertRendered(container);
  } finally {
    await act(async () => { root.unmount(); });
    container.remove();
    globalThis.fetch = originalFetch;
    clearClientResourceStoresForTests();
    testWindow.close();
    for (const key of globalKeys) {
      Object.defineProperty(globalThis, key, { configurable: true, value: previous[key] });
    }
  }
}

async function withUsageCacheCard(summary: UsageCacheSummary, assertCard: (card: Element) => void) {
  const globalKeys = ["document", "window", "navigator", "localStorage", "ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const previous = Object.fromEntries(globalKeys.map(key => [key, Reflect.get(globalThis, key)]));
  const originalFetch = globalThis.fetch;
  const testWindow = new Window({ url: "http://localhost/" });
  const apiBase = `http://usage-cache-test-${++usageCacheTestCase}`;
  const windowResizeObserver = Reflect.get(testWindow, "ResizeObserver");
  const resizeObserver = typeof windowResizeObserver === "function"
    ? windowResizeObserver
    : class ResizeObserver {
        observe() {}
        unobserve() {}
        disconnect() {}
      };
  Object.defineProperties(globalThis, {
    document: { configurable: true, value: testWindow.document },
    window: { configurable: true, value: testWindow },
    navigator: { configurable: true, value: testWindow.navigator },
    localStorage: { configurable: true, value: testWindow.localStorage },
    ResizeObserver: { configurable: true, value: resizeObserver },
  });
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  clearClientResourceStoresForTests();
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    if (String(input).endsWith("/api/provider-quotas")) {
      return { ok: true, json: async () => ({ generatedAt: Date.now(), reports: [] }) };
    }
    return {
      ok: true,
      json: async () => ({
      range: "30d",
      surface: "all",
      since: null,
      generatedAt: Date.now(),
      summary: {
        requests: 1,
        measuredRequests: 1,
        reportedRequests: 1,
        unreportedRequests: 0,
        unsupportedRequests: 0,
        estimatedRequests: 0,
        ...summary,
        outputTokens: 10,
        reasoningOutputTokens: 0,
        totalTokens: Number.isFinite(summary.inputTokens) ? Math.max(0, summary.inputTokens) + 10 : 10,
        coverageRatio: 1,
      },
      days: [],
      models: [],
      providers: [],
      historyTruncated: false,
      truncatedPrefixBytes: 0,
      entriesTruncated: false,
        entriesDropped: 0,
      }),
    };
  }) as typeof fetch;

  const container = document.createElement("div");
  document.body.append(container);
  const { createRoot } = await import("react-dom/client");
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(createElement(LanguageProvider, null, createElement(Usage, { apiBase })));
    });
    const deadline = Date.now() + 1_000;
    let card: Element | undefined;
    while (!card) {
      card = [...container.querySelectorAll(".stat")].find(element =>
        element.querySelector(".muted")?.textContent === "Cache reads",
      );
      if (card) break;
      if (Date.now() >= deadline) throw new Error("Cache reads card did not render");
      await act(async () => {
        await new Promise<void>(resolve => testWindow.setTimeout(resolve, 10));
      });
    }
    assertCard(card!);
  } finally {
    await act(async () => { root.unmount(); });
    container.remove();
    globalThis.fetch = originalFetch;
    clearClientResourceStoresForTests();
    testWindow.close();
    for (const key of globalKeys) {
      Object.defineProperty(globalThis, key, { configurable: true, value: previous[key] });
    }
  }
}

test("Usage shows an em dash for a non-positive total input token count", async () => {
  await withUsageCacheCard({ inputTokens: -1, cachedInputTokens: 1 }, card => {
    expect(card.querySelector(".stat-value")?.textContent).toBe("1 (—)");
  });
});

test("Usage shows an em dash for a non-finite total input token count", async () => {
  await withUsageCacheCard({ inputTokens: Number.POSITIVE_INFINITY, cachedInputTokens: 1 }, card => {
    expect(card.querySelector(".stat-value")?.textContent).toContain("(—)");
  });
});

test("Usage shows an em dash for non-finite cache-read data", async () => {
  await withUsageCacheCard({ inputTokens: 1_000, cachedInputTokens: 900, cacheReadInputTokens: Number.NaN }, card => {
    expect(card.querySelector(".stat-value")?.textContent).toContain("(—)");
  });
});

test("Usage renders the explicit cache-read count and hit percentage together", async () => {
  await withUsageCacheCard(
    { inputTokens: 1_000, cachedInputTokens: 900, cacheReadInputTokens: 250, cacheCreationInputTokens: 12 },
    card => {
      expect(card.querySelector(".stat-value")?.textContent).toBe("250 (25%)");
      expect(card.textContent).toContain("cache writes: 12");
    },
  );
});

test("Usage falls back to legacy cachedInputTokens for the cache-hit percentage", async () => {
  await withUsageCacheCard({ inputTokens: 1_000, cachedInputTokens: 990 }, card => {
    expect(card.querySelector(".stat-value")?.textContent).toBe("990 (99%)");
  });
});

test("Usage shows an em dash when total input tokens are zero", async () => {
  await withUsageCacheCard({ inputTokens: 0, cachedInputTokens: 100, cacheReadInputTokens: 50 }, card => {
    expect(card.querySelector(".stat-value")?.textContent).toBe("50 (—)");
  });
});

test("Usage clamps cache-hit percentages to the 0–100% range", async () => {
  await withUsageCacheCard({ inputTokens: 1_000, cachedInputTokens: -100, cacheReadInputTokens: 2_000 }, card => {
    expect(card.querySelector(".stat-value")?.textContent).toBe("2000 (100%)");
  });
});

test("Usage clamps negative cache-read percentages to 0%", async () => {
  await withUsageCacheCard({ inputTokens: 1_000, cachedInputTokens: 900, cacheReadInputTokens: -1 }, card => {
    expect(card.querySelector(".stat-value")?.textContent).toBe("-1 (0%)");
  });
});

test("Usage defaults to Today and requests that range", async () => {
  const globalKeys = ["document", "window", "navigator", "localStorage", "ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const previous = Object.fromEntries(globalKeys.map(key => [key, Reflect.get(globalThis, key)]));
  const originalFetch = globalThis.fetch;
  const testWindow = new Window({ url: "http://localhost/" });
  const apiBase = `http://usage-range-test-${++usageCacheTestCase}`;
  const windowResizeObserver = Reflect.get(testWindow, "ResizeObserver");
  const resizeObserver = typeof windowResizeObserver === "function"
    ? windowResizeObserver
    : class ResizeObserver {
        observe() {}
        unobserve() {}
        disconnect() {}
      };
  Object.defineProperties(globalThis, {
    document: { configurable: true, value: testWindow.document },
    window: { configurable: true, value: testWindow },
    navigator: { configurable: true, value: testWindow.navigator },
    localStorage: { configurable: true, value: testWindow.localStorage },
    ResizeObserver: { configurable: true, value: resizeObserver },
  });
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  clearClientResourceStoresForTests();
  const requestedUrls: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    const url = String(input);
    requestedUrls.push(url);
    if (url.endsWith("/api/provider-quotas")) {
      return { ok: true, json: async () => ({ generatedAt: Date.now(), reports: [] }) };
    }
    return { ok: true, json: async () => usageFixture([]) };
  }) as typeof fetch;

  const container = document.createElement("div");
  document.body.append(container);
  const { createRoot } = await import("react-dom/client");
  const root = createRoot(container);
  try {
    const t: TFn = (key, vars) => key === "usage.range.today"
      ? "Today"
      : interpolate(DICTS.en[key] ?? key, vars);
    await act(async () => {
      root.render(createElement(
        I18nContext.Provider,
        { value: { locale: "en", setLocale: () => {}, t } },
        createElement(Usage, { apiBase }),
      ));
    });
    const deadline = Date.now() + 1_000;
    while (!requestedUrls.some(url => url.includes("/api/usage?range=today"))) {
      if (Date.now() >= deadline) throw new Error("Usage did not request the default today range");
      await act(async () => {
        await new Promise<void>(resolve => testWindow.setTimeout(resolve, 10));
      });
    }

    const rangeButtons = [...(container.querySelectorAll(".usage-head .usage-segmented")[1]?.querySelectorAll("button") ?? [])];
    expect(rangeButtons.map(button => button.textContent)).toEqual(["Today", "7d", "30d", "Available history"]);
    expect(rangeButtons.map(button => button.getAttribute("aria-pressed"))).toEqual(["true", "false", "false", "false"]);
    expect(requestedUrls.some(url => url.endsWith("/api/provider-quotas"))).toBe(true);
  } finally {
    await act(async () => { root.unmount(); });
    container.remove();
    globalThis.fetch = originalFetch;
    clearClientResourceStoresForTests();
    testWindow.close();
    for (const key of globalKeys) {
      Object.defineProperty(globalThis, key, { configurable: true, value: previous[key] });
    }
  }
});

test("Usage renders Today as hourly bars and keeps the seven-day chart", async () => {
  const src = await Bun.file(new URL("../src/pages/Usage.tsx", import.meta.url)).text();
  expect(src).toContain("const USAGE_REFRESH_MS = 5_000");
  expect(src).toContain("pollMs: USAGE_REFRESH_MS");
  expect(src).toContain("const todayHours = useMemo");
  expect(src).toContain('{range === "today" ? (');
  expect(src).toContain("<UsageActivityBars bars={todayHours}");
  expect(src).toContain('hourly />');
  expect(src).toContain(') : range === "7d" ? (');
  expect(src).toContain("<WeekDayBars weekBars={weekBars}");
  expect(src).toContain("activityBarCacheHitPercentage");
  expect(src).toContain('className="daybar-cache"');
});

test("Usage model table renders speed and cache-hit columns while quota loading stays independent", async () => {
  await withRenderedUsage({
    providers: [{ provider: "openai" }],
    quotas: [],
    models: [{
      provider: "openai",
      model: "gpt-5.5",
      inputTokens: 100,
      cacheReadInputTokens: 25,
      outputTokensPerSecond: 42.5,
    }],
    assertRendered: container => {
      const table = container.querySelector("#usage-models-title")?.parentElement?.querySelector("table");
      const headers = [...(table?.querySelectorAll("thead th") ?? [])].map(th => th.textContent);
      expect(headers).toEqual(["Model", "Provider", "Requests", "Measured", "Tokens", "tok/s", "Cache hit", "Share"]);
      const cells = table?.querySelector("tbody tr")?.querySelectorAll("td");
      expect(cells?.[5]?.textContent).toBe("42.5");
      expect(cells?.[5]?.getAttribute("title")).toBeNull();
      expect(cells?.[6]?.textContent).toBe("25%");
      expect(cells?.[7]?.querySelector(".usage-bar")).not.toBeNull();
      expect(table?.querySelector("thead th:nth-child(6)")?.getAttribute("title")).toBe("Output tokens per second over the full request duration");
      expect(container.querySelector("#usage-providers-title")).not.toBeNull();
    },
  });
});

test("Usage formats estimated and invalid model speeds without disturbing cache-hit or Share cells", async () => {
  await withRenderedUsage({
    providers: [{ provider: "openai" }],
    quotas: [],
    models: [
      { provider: "a", model: "estimated", inputTokens: 100, cacheReadInputTokens: 25, outputTokensPerSecond: 100, outputTokensPerSecondEstimated: true },
      { provider: "b", model: "missing", inputTokens: 100, cacheReadInputTokens: 50 },
      { provider: "c", model: "nonfinite", inputTokens: 100, cacheReadInputTokens: 75, outputTokensPerSecond: Number.NaN },
      { provider: "d", model: "zero", inputTokens: 100, cacheReadInputTokens: 25, outputTokensPerSecond: 0 },
      { provider: "e", model: "negative", inputTokens: 100, cacheReadInputTokens: 10, outputTokensPerSecond: -1 },
    ],
    assertRendered: container => {
      const table = container.querySelector("#usage-models-title")?.parentElement?.querySelector("table");
      const rows = [...(table?.querySelectorAll("tbody tr") ?? [])];
      const rowFor = (model: string) => rows.find(row => row.querySelector("td")?.textContent === model)!;
      const speedFor = (model: string) => rowFor(model).querySelectorAll("td")[5]?.textContent;

      expect(speedFor("estimated")).toBe("~100");
      expect(speedFor("missing")).toBe("—");
      expect(speedFor("nonfinite")).toBe("—");
      expect(speedFor("zero")).toBe("—");
      expect(speedFor("negative")).toBe("—");
      for (const row of rows) {
        const cells = row.querySelectorAll("td");
        expect(cells[6]?.textContent).toMatch(/^\d+%$/);
        expect(cells[7]?.querySelector(".usage-bar")).not.toBeNull();
      }
    },
  });
});

test("Usage model cache-hit percentages fail closed and clamp to 0–100%", async () => {
  await withRenderedUsage({
    providers: [{ provider: "openai" }],
    quotas: [],
    models: [
      { provider: "a", model: "missing-input", cacheReadInputTokens: 10 },
      { provider: "b", model: "zero-input", inputTokens: 0, cacheReadInputTokens: 10 },
      { provider: "c", model: "nonfinite-read", inputTokens: 100, cacheReadInputTokens: Number.NaN },
      { provider: "d", model: "nonfinite-input", inputTokens: Number.NaN, cacheReadInputTokens: 10 },
      { provider: "e", model: "negative-read", inputTokens: 100, cacheReadInputTokens: -1 },
      { provider: "f", model: "over-read", inputTokens: 100, cacheReadInputTokens: 200 },
    ],
    assertRendered: container => {
      const table = container.querySelector("#usage-models-title")?.parentElement?.querySelector("table");
      const values = [...(table?.querySelectorAll("tbody tr") ?? [])].map(row => row.querySelectorAll("td")[6]?.textContent);
      expect(values).toEqual(["—", "—", "—", "—", "0%", "100%"]);
    },
  });
});

test("Usage places Weekly limit immediately before Share and renders provider quota percent", async () => {
  await withRenderedUsage({
    providers: [{ provider: "anthropic" }],
    quotas: [{ provider: "anthropic", quota: { weeklyPercent: 24.6 } }],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      const headers = [...(table?.querySelectorAll("thead th") ?? [])].map(th => th.textContent);
      expect(headers).toEqual(["Provider", "Requests", "Measured", "Tokens", "Weekly limit", "Share"]);
      expect(table?.textContent).toContain("25% used");
    },
  });
});

test("Usage renders valid provider quota reset copy", async () => {
  await withRenderedUsage({
    providers: [{ provider: "anthropic" }],
    quotas: [{ provider: "anthropic", quota: { weeklyPercent: 25, weeklyResetAt: Date.now() + 3_600_000 } }],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("Resets");
    },
  });
});

test("Usage omits reset copy for zero or negative provider reset timestamps", async () => {
  await withRenderedUsage({
    providers: [{ provider: "anthropic" }],
    quotas: [{ provider: "anthropic", quota: { weeklyPercent: 25, weeklyResetAt: 0 } }],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("25% used");
      expect(table?.textContent).not.toContain("Resets");
    },
  });

  await withRenderedUsage({
    providers: [{ provider: "anthropic" }],
    quotas: [{ provider: "anthropic", quota: { weeklyPercent: 25, weeklyResetAt: -1 } }],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("25% used");
      expect(table?.textContent).not.toContain("Resets");
    },
  });
});

test("Usage fails closed for missing or malformed weekly provider quota data", async () => {
  await withRenderedUsage({
    providers: [{ provider: "anthropic" }, { provider: "deepseek" }],
    quotas: [
      { provider: "anthropic", quota: {} },
      { provider: "deepseek", quota: { weeklyPercent: Number.NaN } },
    ],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      const rows = [...(table?.querySelectorAll("tbody tr") ?? [])];
      const weeklyCellFor = (providerName: string) => rows
        .find(row => row.querySelector("td")?.textContent === providerName)
        ?.querySelectorAll("td")[4]?.textContent;
      expect(weeklyCellFor("Anthropic Claude")).toBe("—");
      expect(weeklyCellFor("DeepSeek")).toBe("—");
      expect(table?.textContent).not.toContain("NaN% used");
    },
  });
});

test("Usage fails closed for a non-finite provider weekly percentage", async () => {
  await withRenderedUsage({
    providers: [{ provider: "low" }],
    quotas: [{ provider: "low", quota: { weeklyPercent: Number.POSITIVE_INFINITY } }],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.querySelector("tbody tr")?.querySelectorAll("td")[4]?.textContent).toBe("—");
    },
  });
});

test("Usage clamps provider weekly quota percentages to 0% and 100%", async () => {
  await withRenderedUsage({
    providers: [{ provider: "low" }, { provider: "high" }],
    quotas: [
      { provider: "low", quota: { weeklyPercent: -10 } },
      { provider: "high", quota: { weeklyPercent: 120 } },
    ],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("0% used");
      expect(table?.textContent).toContain("100% used");
    },
  });
});

test("Usage keeps the provider usage table when the quota request fails", async () => {
  await withRenderedUsage({
    providers: [{ provider: "anthropic" }],
    quotas: [],
    quotaOk: false,
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("Anthropic Claude");
      expect(table?.textContent).toContain("—");
    },
  });
});

test("Usage maps ChatGPT quota identities onto the OpenAI usage row", async () => {
  await withRenderedUsage({
    providers: [{ provider: "openai" }],
    quotas: [{ provider: "chatgpt", quota: { weeklyPercent: 61 } }],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("61% used");
    },
  });
});

test("Usage matches mixed-case quota provider identities case-insensitively", async () => {
  await withRenderedUsage({
    providers: [{ provider: "anthropic" }],
    quotas: [{ provider: "AnThRoPiC", quota: { weeklyPercent: 37 } }],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("37% used");
    },
  });
});

test("Usage chooses the newest duplicate canonical provider quota report", async () => {
  await withRenderedUsage({
    providers: [{ provider: "openai" }],
    quotas: [
      { provider: "openai-multi", updatedAt: -1, quota: { weeklyPercent: 12 } },
      { provider: "chatgpt", updatedAt: 200, quota: { weeklyPercent: 88 } },
      { provider: "OPENAI-MULTI", updatedAt: Number.POSITIVE_INFINITY, quota: { weeklyPercent: 99 } },
      { provider: "CHATGPT", updatedAt: Number.NaN, quota: { weeklyPercent: 77 } },
    ],
    assertRendered: container => {
      const table = container.querySelector("#usage-providers-title")?.parentElement?.querySelector("table");
      expect(table?.textContent).toContain("88% used");
      expect(table?.textContent).not.toContain("12% used");
      expect(table?.textContent).not.toContain("99% used");
      expect(table?.textContent).not.toContain("77% used");
    },
  });
});

test("Usage renders every section in one scrollable column with a sticky strip", async () => {
  const page = await Bun.file(new URL("../src/pages/Usage.tsx", import.meta.url)).text();
  const app = await Bun.file(new URL("../src/App.tsx", import.meta.url)).text();
  const css = await Bun.file(new URL("../src/styles.css", import.meta.url)).text();

  expect(page).not.toContain("viewMode");
  expect(page).not.toContain("readViewMode");
  expect(page).not.toContain("ocx-usage-view");
  expect(page).toContain("UsageWorkspaceBody");
  expect(page).toContain("UsageWorkspaceSection");
  expect(page).toContain("usage-workspace-");
  expect(page).toContain("usw-");
  // Sections are anchors in one document, not a swapped panel: the old `selectedSection`
  // state rendered exactly one section, which is why the page could not be read by scrolling.
  expect(page).not.toContain("selectedSection");
  expect(page).toContain("<SectionTabs");
  expect(page).toContain("sectionAnchorId");

  expect(app).toContain("<Usage apiBase={API_BASE} />");
  expect(css).toContain("styles-usage-workspace.css");
  // The strip has to stay reachable while reading down the page.
  expect(css).toContain(".section-tabs");
  expect(css).toContain("position: sticky");
});

test("Usage workspace sections mount report panels in order", async () => {
  const src = await Bun.file(new URL("../src/pages/Usage.tsx", import.meta.url)).text();

  const order = [
    "<UsageSummaryCards",
    "<UsageHeatmapPanel",
    "<UsageModelsTable",
    "<UsageProvidersTable",
    "<UsageCoveragePanel",
  ];
  let cursor = -1;
  for (const marker of order) {
    const at = src.indexOf(marker);
    expect(at).toBeGreaterThan(cursor);
    cursor = at;
  }

  expect(src).toContain("UsageWorkspaceBody");
  expect(src).toContain("usw-section");
});

test("Usage loading and empty states guard the workspace body", async () => {
  const src = await Bun.file(new URL("../src/pages/Usage.tsx", import.meta.url)).text();
  expect(src).toContain("state.showSkeleton && !data");
  expect(src).toContain("DataSurfaceSkeleton");
  expect(src).toContain('t("usage.loading")');
  expect(src).toContain('t("usage.empty")');
  expect(src).toContain("data.summary.requests === 0");
});

test("usage workspace i18n keys exist in every locale", async () => {
  const locales = ["en", "de", "fr", "ja", "ko", "ru", "zh", "zh-TW"] as const;
  for (const locale of locales) {
    const dict = await Bun.file(new URL(`../src/i18n/${locale}.ts`, import.meta.url)).text();
    expect(dict).toContain('"usage.workspace.sections":');
    expect(dict).toContain('"usage.workspace.report":');
    expect(dict).toContain('"usage.range.available":');
    expect(dict).toContain('"usage.historyTruncated":');
    expect(dict).toContain('"usage.historyTruncatedWindow":');
    expect(dict).toContain('"api.attribution.totalRequestsAvailable":');
  }
});

test("Usage renders Available history and a persistent qualification when history is capped", async () => {
  const globalKeys = ["document", "window", "navigator", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const previous = Object.fromEntries(globalKeys.map(key => [key, Reflect.get(globalThis, key)]));
  const originalFetch = globalThis.fetch;
  const testWindow = new Window({ url: "http://localhost/" });
  Object.defineProperties(globalThis, {
    document: { configurable: true, value: testWindow.document },
    window: { configurable: true, value: testWindow },
    navigator: { configurable: true, value: testWindow.navigator },
    localStorage: { configurable: true, value: testWindow.localStorage },
  });
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  clearClientResourceStoresForTests();
  globalThis.fetch = (async () => Response.json({
    range: "30d",
    surface: "all",
    since: null,
    generatedAt: Date.now(),
    summary: {
      requests: 0,
      measuredRequests: 0,
      reportedRequests: 0,
      unreportedRequests: 0,
      unsupportedRequests: 0,
      estimatedRequests: 0,
      inputTokens: 0,
      outputTokens: 0,
      cachedInputTokens: 0,
      reasoningOutputTokens: 0,
      totalTokens: 0,
      coverageRatio: 1,
    },
    days: [],
    models: [],
    providers: [],
    historyTruncated: true,
    truncatedPrefixBytes: 1,
    entriesTruncated: false,
    entriesDropped: 0,
  })) as typeof fetch;

  const container = document.createElement("div");
  document.body.append(container);
  const { createRoot } = await import("react-dom/client");
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(createElement(LanguageProvider, null, createElement(Usage, { apiBase: "http://usage-qualification-test" })));
    });
    const deadline = Date.now() + 1_000;
    while (!(container.textContent ?? "").includes("Totals cover available history only")) {
      if (Date.now() >= deadline) throw new Error("Usage qualification did not render");
      await act(async () => {
        await new Promise<void>(resolve => testWindow.setTimeout(resolve, 10));
      });
    }

    expect(container.querySelector('button[aria-label="Available history"]')).not.toBeNull();
    expect(container.textContent).toContain("Totals cover available history only because older usage was not loaded.");
  } finally {
    await act(async () => { root.unmount(); });
    container.remove();
    globalThis.fetch = originalFetch;
    clearClientResourceStoresForTests();
    testWindow.close();
    for (const key of globalKeys) {
      Object.defineProperty(globalThis, key, { configurable: true, value: previous[key] });
    }
  }
});

test("Usage names the loaded window when history is truncated", async () => {
  const page = await Bun.file(new URL("../src/pages/Usage.tsx", import.meta.url)).text();

  // #1497: when the proxy reports the window it actually loaded, the notice must name that
  // window instead of the generic wording — otherwise `30d` and "Available history" stay
  // indistinguishable on a busy installation. `!= null` keeps an older proxy that omits the
  // fields on the generic string rather than rendering "Invalid Date".
  expect(page).toContain("usage.historyTruncatedWindow");
  // Presence alone is not enough: a hand-edited row can carry a timestamp outside Date's
  // range, so both bounds must round-trip through Date before the detailed wording is used.
  expect(page).toContain("function renderableInstant");
  expect(page).toContain("Number.isFinite(at.getTime())");
  // A total that silently omits in-range rows is a caveat, not a status update.
  expect(page).toContain('<Notice tone="warn">');
});

test("Usage falls back to the generic caveat when a reported bound is unrenderable", async () => {
  const globalKeys = ["document", "window", "navigator", "localStorage", "IS_REACT_ACT_ENVIRONMENT"] as const;
  const previous = Object.fromEntries(globalKeys.map(key => [key, Reflect.get(globalThis, key)]));
  const originalFetch = globalThis.fetch;
  const testWindow = new Window({ url: "http://localhost/" });
  Object.defineProperties(globalThis, {
    document: { configurable: true, value: testWindow.document },
    window: { configurable: true, value: testWindow },
    navigator: { configurable: true, value: testWindow.navigator },
    localStorage: { configurable: true, value: testWindow.localStorage },
  });
  (globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
  clearClientResourceStoresForTests();
  // A timestamp beyond Date's supported range. Rendering it would put the literal string
  // "Invalid Date" inside a notice whose entire purpose is to be trustworthy.
  globalThis.fetch = (async () => Response.json({
    range: "30d",
    surface: "all",
    since: null,
    generatedAt: Date.now(),
    summary: {
      requests: 0,
      measuredRequests: 0,
      reportedRequests: 0,
      unreportedRequests: 0,
      unsupportedRequests: 0,
      estimatedRequests: 0,
      inputTokens: 0,
      outputTokens: 0,
      cachedInputTokens: 0,
      reasoningOutputTokens: 0,
      totalTokens: 0,
      coverageRatio: 1,
    },
    days: [],
    models: [],
    providers: [],
    historyTruncated: true,
    truncatedPrefixBytes: 1,
    entriesTruncated: false,
    entriesDropped: 0,
    snapshotWindowStart: 1e18,
    snapshotWindowEnd: 1e18,
  })) as typeof fetch;

  const container = document.createElement("div");
  document.body.append(container);
  const { createRoot } = await import("react-dom/client");
  const root = createRoot(container);
  try {
    await act(async () => {
      root.render(createElement(LanguageProvider, null, createElement(Usage, { apiBase: "http://usage-invalid-window-test" })));
    });
    const deadline = Date.now() + 1_000;
    while (!(container.textContent ?? "").includes("Totals cover available history only")) {
      if (Date.now() >= deadline) throw new Error("Usage fallback qualification did not render");
      await act(async () => {
        await new Promise<void>(resolve => testWindow.setTimeout(resolve, 10));
      });
    }
    expect(container.textContent).not.toContain("Invalid Date");
    expect(container.textContent).not.toContain("request start times ranging");
  } finally {
    await act(async () => { root.unmount(); });
    container.remove();
    globalThis.fetch = originalFetch;
    clearClientResourceStoresForTests();
    testWindow.close();
    for (const key of globalKeys) {
      Object.defineProperty(globalThis, key, { configurable: true, value: previous[key] });
    }
  }
});

test("Usage source marks keep brand colors and invert only the monochrome Grok mark", async () => {
  const page = await Bun.file(new URL("../src/pages/Usage.tsx", import.meta.url)).text();
  const css = await Bun.file(new URL("../src/styles.css", import.meta.url)).text();

  // Claude and Codex ship brand-colored SVGs and must not carry the mono modifier.
  expect(page).toContain('src="/provider-icons/claude-color.svg"');
  expect(page).not.toContain('usage-source-mark usage-source-mark--mono" src="/provider-icons/claude-color.svg"');
  expect(page).toContain('src="/provider-icons/openai.svg"');
  expect(page).not.toContain('usage-source-mark usage-source-mark--mono" src="/provider-icons/openai.svg"');

  // Grok ships a black monochrome mark: it is the only one that needs dark-theme inversion.
  expect(page).toContain('usage-source-mark usage-source-mark--mono" src="/provider-icons/grok.svg"');

  // Dark-theme inversion must be scoped to the mono modifier so brand hues survive.
  expect(css).toContain(':root[data-theme="dark"] .usage-source-mark--mono { filter: invert(1); }');
  expect(css).not.toContain(':root[data-theme="dark"] .usage-source-mark { filter: invert(1); }');
  // The OS dark-mode (prefers-color-scheme) path must keep the same scoping.
  expect(css).toContain(':root:not([data-theme="light"]) .usage-source-mark--mono { filter: invert(1); }');
  expect(css).not.toContain(':root:not([data-theme="light"]) .usage-source-mark { filter: invert(1); }');
});
