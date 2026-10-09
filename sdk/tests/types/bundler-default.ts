// "libfx" under bundler resolution without the "node" condition: the
// "default" export condition, which is the browser entry.
import { createFxAgent } from "libfx";
// @ts-expect-error without the "node" condition, "libfx" is the browser entry, which has no getBackendInfo()
import { getBackendInfo } from "libfx";

createFxAgent({ apiKey: "<short-lived credential>", wasm: "/fx-core.wasm" });
// @ts-expect-error backend selection belongs to the Node.js entry
createFxAgent({ backend: "native" });

void getBackendInfo;
