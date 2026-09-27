export function registerRelusterTools(actions) {
  const context = document.modelContext;
  if (!context?.registerTool) return () => {};
  const lifecycle = new AbortController();
  const register = (tool) => {
    try {
      void Promise.resolve(context.registerTool(tool, { signal: lifecycle.signal })).catch(() => {});
    } catch {
      // WebMCP is optional and unavailable in most browsers.
    }
  };

  register({
    name: "refresh_reluster_status",
    title: "Refresh Reluster status",
    description: "Refresh the visible Redis Cluster or Sentinel status and return its health summary.",
    inputSchema: {
      type: "object",
      properties: { mode: { type: "string", enum: ["cluster", "sentinel"] } },
      required: ["mode"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, untrustedContentHint: false },
    execute: ({ mode }) => actions.refresh(mode),
  });

  register({
    name: "seed_reluster_demo_data",
    title: "Seed Reluster demo data",
    description: "Create the bounded sample keys under the configured demo namespace in the selected Redis mode.",
    inputSchema: {
      type: "object",
      properties: { mode: { type: "string", enum: ["cluster", "sentinel"] } },
      required: ["mode"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false, untrustedContentHint: false },
    execute: ({ mode }) => actions.seed(mode),
  });

  return () => lifecycle.abort();
}
