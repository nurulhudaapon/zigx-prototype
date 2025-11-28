import { ZigJS } from "jsz/js/src";
import type { InitOptions } from "./types";
export type { InitOptions } from "./types";

const DEFAULT_URL = "/assets/main.wasm";

const jsz = new ZigJS();
const importObject = {
    module: {},
    env: {},
    ...jsz.importObject(),
};

export async function init(options: InitOptions = {}) {
    const response = await (await fetch(options?.url ?? DEFAULT_URL)).arrayBuffer();
    const { instance } = await WebAssembly.instantiate(response, importObject);

    jsz.memory = instance.exports.memory as WebAssembly.Memory;
    window._zx = instance.exports as Record<string, (...args: any[]) => void>;

    const main = instance.exports.main as () => void;
    main();

}
