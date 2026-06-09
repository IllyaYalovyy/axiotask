import { describe, it, expect, afterEach, vi } from "vitest";

// storage.js reads window.__AXIOTASK_PREFIX__ at module load, so each scenario
// sets the global and imports a fresh copy of the module.
async function freshStorage(prefix) {
  vi.resetModules();
  if (prefix === undefined) delete window.__AXIOTASK_PREFIX__;
  else window.__AXIOTASK_PREFIX__ = prefix;
  return await import("../storage.js");
}

describe("per-instance storage namespacing", () => {
  afterEach(() => {
    delete window.__AXIOTASK_PREFIX__;
  });

  it("uses bare axiotask: keys for the default instance", async () => {
    const { storageKey } = await freshStorage(undefined);
    expect(storageKey("view")).toBe("axiotask:view");
    expect(storageKey("sort:focus")).toBe("axiotask:sort:focus");
  });

  it("treats an empty/null prefix as the default instance", async () => {
    const { storageKey } = await freshStorage(null);
    expect(storageKey("view")).toBe("axiotask:view");
  });

  it("namespaces keys under the active instance prefix", async () => {
    const { storageKey } = await freshStorage("dev");
    expect(storageKey("view")).toBe("axiotask:dev:view");
    expect(storageKey("windowGeometry")).toBe("axiotask:dev:windowGeometry");
  });

  it("keeps two instances' keys disjoint", async () => {
    const dev = (await freshStorage("dev")).storageKey("showCompleted");
    const qa = (await freshStorage("qa")).storageKey("showCompleted");
    const prod = (await freshStorage(undefined)).storageKey("showCompleted");
    expect(new Set([dev, qa, prod]).size).toBe(3);
  });
});
