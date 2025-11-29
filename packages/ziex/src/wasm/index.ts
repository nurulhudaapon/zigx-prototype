import { ZigJS } from "jsz/js/src";

const DEFAULT_URL = "/assets/main.wasm";
const MAX_EVENTS = 1000;

const jsz = new ZigJS();
const importObject = {
    module: {},
    env: {},
    ...jsz.importObject(),
};

class ZXInstance {

    exports: Record<string, (...args: any[]) => void>;
    events: Event[];

    constructor({ exports, events = [] }: ZXInstanceOptions) {
        this.exports = exports;
        this.events = events;
    }

    addEvent(event: Event) {
        if (this.events.length >= MAX_EVENTS) 
            this.events.length = 0;

        const idx = this.events.push(event);
        
        return idx - 1;
    }   
}

export async function init(options: InitOptions = {}) {
    const response = await (await fetch(options?.url ?? DEFAULT_URL)).arrayBuffer();
    const { instance } = await WebAssembly.instantiate(response, importObject);

    jsz.memory = instance.exports.memory as WebAssembly.Memory;
    window._zx = new ZXInstance({ exports: instance.exports as Record<string, (...args: any[]) => void> });

    const main = instance.exports.main as () => void;
    main();

}

export type InitOptions = {
    url?: string;
};

type ZXInstanceOptions = {
    exports: Record<string, (...args: any[]) => void>;
    events?: Event[];
}

declare global {
    interface Window {
        _zx: ZXInstance;
    }
}