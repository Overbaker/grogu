import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const GATEWAY_URL = (process.env.GROGU_LOCAL_GATEWAY_URL || "http://127.0.0.1:18830").replace(/\/$/, "");

async function callGateway(path: string, method: "GET" | "POST" = "POST", body?: unknown) {
  const resp = await fetch(`${GATEWAY_URL}${path}`, {
    method,
    headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await resp.text();
  let parsed: unknown = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // keep raw text
  }
  return {
    content: [{ type: "text" as const, text: typeof parsed === "string" ? parsed : JSON.stringify(parsed) }],
    details: { status: resp.status, data: parsed },
  };
}

function execSteps(steps: Array<Record<string, unknown>>) {
  return callGateway("/api/decision/execute", "POST", { steps });
}

export default function groguIosTools(pi: ExtensionAPI) {
  pi.registerTool({
    name: "ios_tap",
    label: "Tap Coordinates",
    description: "Tap exact screen point (x, y) on the iOS/iPadOS device.",
    parameters: Type.Object({
      x: Type.Number({ description: "Horizontal X point coordinate" }),
      y: Type.Number({ description: "Vertical Y point coordinate" }),
    }),
    async execute(_toolCallId, params) {
      return execSteps([{ op: "tap", x: Math.round(params.x), y: Math.round(params.y) }]);
    },
  });

  pi.registerTool({
    name: "ios_tap_selector",
    label: "Tap Selector",
    description: "Find a visible UI element by label/name/value substring and tap its center.",
    parameters: Type.Object({
      text: Type.String({ description: "Label, identifier, or text substring to tap" }),
      exact: Type.Optional(Type.Boolean({ description: "Require exact match" })),
    }),
    async execute(_toolCallId, params) {
      return execSteps([{ op: "tap_selector", text: params.text, exact: Boolean(params.exact) }]);
    },
  });

  pi.registerTool({
    name: "ios_swipe",
    label: "Swipe Screen",
    description: "Scroll or swipe across the screen (direction: up|down|left|right; use 'up' to scroll down).",
    parameters: Type.Object({
      direction: Type.String({ description: "Swipe direction: up, down, left, or right" }),
    }),
    async execute(_toolCallId, params) {
      return execSteps([{ op: "swipe", direction: params.direction }]);
    },
  });

  pi.registerTool({
    name: "ios_type",
    label: "Type Text",
    description: "Type text into the currently focused field and optionally submit.",
    parameters: Type.Object({
      text: Type.String({ description: "Text to type" }),
      submit: Type.Optional(Type.Boolean({ description: "Press return/enter after typing" })),
    }),
    async execute(_toolCallId, params) {
      return execSteps([{ op: "type", text: params.text, submit: Boolean(params.submit) }]);
    },
  });

  pi.registerTool({
    name: "ios_launch",
    label: "Launch App or URL",
    description: "Launch an app by alias/bundle ID or open a URL/scheme on the device.",
    parameters: Type.Object({
      app: Type.String({ description: "App name, bundle ID, or URL scheme (e.g. settings, safari, https://...)" }),
    }),
    async execute(_toolCallId, params) {
      return execSteps([{ op: "launch", app: params.app }]);
    },
  });

  pi.registerTool({
    name: "ios_button",
    label: "Press Hardware Button",
    description: "Press hardware button such as home, volumeUp, or volumeDown.",
    parameters: Type.Object({
      name: Type.String({ description: "Button name: home, volumeUp, or volumeDown" }),
    }),
    async execute(_toolCallId, params) {
      return execSteps([{ op: "button", name: params.name }]);
    },
  });

  pi.registerTool({
    name: "ios_ui_dump",
    label: "Dump UI Tree",
    description: "Read current indexed UI elements when screen content changed and a follow-up step is needed.",
    parameters: Type.Object({}),
    async execute() {
      return callGateway("/api/ui/dump?compact=true&max_elements=160", "GET");
    },
  });
}
